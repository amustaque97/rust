#!/usr/bin/env bash

set -e

if [ -n "$CI_JOB_NAME" ]; then
  echo "[CI_JOB_NAME=$CI_JOB_NAME]"
fi

if [ "$NO_CHANGE_USER" = "" ]; then
  if [ "$LOCAL_USER_ID" != "" ]; then
    useradd --shell /bin/bash -u $LOCAL_USER_ID -o -c "" -m user
    export HOME=/home/user
    unset LOCAL_USER_ID

    # Ensure that runners are able to execute git commands in the worktree,
    # overriding the typical git protections. In our docker container we're running
    # as root, while the user owning the checkout is not root.
    # This is only necessary when we change the user, otherwise we should
    # already be running with the right user.
    #
    # For NO_CHANGE_USER done in the small number of Dockerfiles affected.
    echo -e '[safe]\n\tdirectory = *' > /home/user/gitconfig

    exec su --preserve-environment -c "env PATH=$PATH \"$0\"" user
  fi
fi

# only enable core dump on Linux
if [ -f /proc/sys/kernel/core_pattern ]; then
  ulimit -c unlimited
fi

# There was a bad interaction between "old" 32-bit binaries on current 64-bit
# kernels with selinux enabled, where ASLR mmap would sometimes choose a low
# address and then block it for being below `vm.mmap_min_addr` -> `EACCES`.
# This is probably a kernel bug, but setting `ulimit -Hs` works around it.
# See also `dist-i686-linux` where this setting is enabled.
if [ "$SET_HARD_RLIMIT_STACK" = "1" ]; then
  rlimit_stack=$(ulimit -Ss)
  if [ "$rlimit_stack" != "" ]; then
    ulimit -Hs "$rlimit_stack"
  fi
fi

ci_dir=`cd $(dirname $0) && pwd`
source "$ci_dir/shared.sh"

if command -v python > /dev/null; then
    PYTHON="python"
elif command -v python3 > /dev/null; then
    PYTHON="python3"
else
    PYTHON="python2"
fi

if ! isCI || isCiBranch auto || isCiBranch beta || isCiBranch try || isCiBranch try-perf; then
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --set build.print-step-timings --enable-verbose-tests"
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --set build.metrics"
fi

RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-sccache"
RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --disable-manage-submodules"
RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-locked-deps"
RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-cargo-native-static"
RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --set rust.codegen-units-std=1"

# Only produce xz tarballs on CI. gz tarballs will be generated by the release
# process by recompressing the existing xz ones. This decreases the storage
# space required for CI artifacts.
RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --dist-compression-formats=xz"

if [ "$DIST_SRC" = "" ]; then
  RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --disable-dist-src"
fi

# Always set the release channel for bootstrap; this is normally not important (i.e., only dist
# builds would seem to matter) but in practice bootstrap wants to know whether we're targeting
# master, beta, or stable with a build to determine whether to run some checks (notably toolstate).
export RUST_RELEASE_CHANNEL=$(releaseChannel)
RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --release-channel=$RUST_RELEASE_CHANNEL"

if [ "$DEPLOY$DEPLOY_ALT" = "1" ]; then
  RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-llvm-static-stdcpp"
  RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --set rust.remap-debuginfo"
  RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --debuginfo-level-std=1"

  if [ "$NO_LLVM_ASSERTIONS" = "1" ]; then
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --disable-llvm-assertions"
  elif [ "$DEPLOY_ALT" != "" ]; then
    if [ "$NO_PARALLEL_COMPILER" = "" ]; then
      RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --set rust.parallel-compiler"
    fi
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-llvm-assertions"
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --set rust.verify-llvm-ir"
  fi
else
  # We almost always want debug assertions enabled, but sometimes this takes too
  # long for too little benefit, so we just turn them off.
  if [ "$NO_DEBUG_ASSERTIONS" = "" ]; then
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-debug-assertions"
  fi

  # Same for overflow checks
  if [ "$NO_OVERFLOW_CHECKS" = "" ]; then
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-overflow-checks"
  fi

  # In general we always want to run tests with LLVM assertions enabled, but not
  # all platforms currently support that, so we have an option to disable.
  if [ "$NO_LLVM_ASSERTIONS" = "" ]; then
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-llvm-assertions"
  fi

  RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --set rust.verify-llvm-ir"

  # We enable this for non-dist builders, since those aren't trying to produce
  # fresh binaries. We currently don't entirely support distributing a fresh
  # copy of the compiler (including llvm tools, etc.) if we haven't actually
  # built LLVM, since not everything necessary is copied into the
  # local-usage-only LLVM artifacts. If that changes, this could maybe be made
  # true for all builds. In practice it's probably a good idea to keep building
  # LLVM continuously on at least some builders to ensure it works, though.
  # (And PGO is its own can of worms).
  if [ "$NO_DOWNLOAD_CI_LLVM" = "" ]; then
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --set llvm.download-ci-llvm=if-available"
  fi
fi

if [ "$RUST_RELEASE_CHANNEL" = "nightly" ] || [ "$DIST_REQUIRE_ALL_TOOLS" = "" ]; then
    RUST_CONFIGURE_ARGS="$RUST_CONFIGURE_ARGS --enable-missing-tools"
fi

export COMPILETEST_NEEDS_ALL_LLVM_COMPONENTS=1

# Print the date from the local machine and the date from an external source to
# check for clock drifts. An HTTP URL is used instead of HTTPS since on Azure
# Pipelines it happened that the certificates were marked as expired.
datecheck() {
  echo "== clock drift check =="
  echo -n "  local time: "
  date
  echo -n "  network time: "
  curl -fs --head http://ci-caches.rust-lang.org | grep ^Date: \
      | sed 's/Date: //g' || true
  echo "== end clock drift check =="
}
datecheck
trap datecheck EXIT

# We've had problems in the past of shell scripts leaking fds into the sccache
# server (#48192) which causes Cargo to erroneously think that a build script
# hasn't finished yet. Try to solve that problem by starting a very long-lived
# sccache server at the start of the build, but no need to worry if this fails.
SCCACHE_IDLE_TIMEOUT=10800 sccache --start-server || true

if [ "$RUN_CHECK_WITH_PARALLEL_QUERIES" != "" ]; then
  $SRC/configure --set rust.parallel-compiler
  CARGO_INCREMENTAL=0 $PYTHON ../x.py check
  rm -f config.toml
  rm -rf build
fi

$SRC/configure $RUST_CONFIGURE_ARGS

retry make prepare

# Display the CPU and memory information. This helps us know why the CI timing
# is fluctuating.
if isMacOS; then
    system_profiler SPHardwareDataType || true
    sysctl hw || true
    ncpus=$(sysctl -n hw.ncpu)
else
    cat /proc/cpuinfo || true
    cat /proc/meminfo || true
    ncpus=$(grep processor /proc/cpuinfo | wc -l)
fi

if [ ! -z "$SCRIPT" ]; then
  sh -x -c "$SCRIPT"
else
  do_make() {
    echo "make -j $ncpus $1"
    make -j $ncpus $1
    local retval=$?
    return $retval
  }

  do_make "$RUST_CHECK_TARGET"
fi

sccache --show-stats || true
