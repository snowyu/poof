#!/bin/bash
set -euo pipefail

# Run the test suite as root inside a container.
#
# What needs root, and is therefore only covered here and in CI:
#   * the kernel overlay driver - an unprivileged session uses fuse-overlayfs
#     instead, and the two record the same change with different markers (0:0
#     character devices and the trusted.overlay.opaque xattr vs .wh. files);
#   * CAP_MKNOD, which is how a real device node is told apart from a whiteout;
#   * cgroup v2 delegation, for --memory and --pids.
#
# A container's root is an overlayfs mount, and poof cannot work on one: the
# kernel refuses an overlay upperdir sitting on another overlay, and the sandbox
# could not show it to a command anyway (overlayfs lowerdir=/ covers the root's
# own tree, so anything on a nested mount is simply not there inside the
# sandbox). So the container first moves itself onto a plain tmpfs root; from
# then on the whole tree is one filesystem the sandbox can overlay.
#
# bun and zig are bind mounted from the host, so the image only needs a shell
# and coreutils. Tests that want another tool skip when it is missing (the diff
# view needs git); POOF_TEST_APT installs extra packages first, at the cost of
# needing network. Everything is overridable if the defaults miss:
#
#   ./scripts/test-docker.sh
#   POOF_TEST_IMAGE=debian:trixie-slim ./scripts/test-docker.sh
#   POOF_CONTAINER_RUNTIME=podman ./scripts/test-docker.sh
#   POOF_TEST_APT="git vim" ./scripts/test-docker.sh

IMAGE="${POOF_TEST_IMAGE:-ubuntu:24.04}"
RUNTIME="${POOF_CONTAINER_RUNTIME:-docker}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUN_BIN="${BUN_BIN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}"
ZIG_HOME="${ZIG_HOME:-$(dirname "$(readlink -f "$(command -v zig || echo "$HOME/.zig/zig")")")}"
GIT_COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)"

for f in "$BUN_BIN" "$ZIG_HOME/zig"; do
    if [[ ! -x "$f" ]]; then
        echo "not found: $f (set BUN_BIN / ZIG_HOME)" >&2
        exit 1
    fi
done

# --privileged: the sandbox needs CAP_SYS_ADMIN (namespaces, mounts) and the
#   suite needs CAP_MKNOD (the real-device-node test).
# The zig cache volume keeps repeat runs from recompiling the standard library.
# Extra arguments go through to `bun test`.
"$RUNTIME" run --rm -i --privileged --user root \
    -v "$REPO:/src:ro" \
    -v "$BUN_BIN:/usr/local/bin/bun:ro" \
    -v "$ZIG_HOME:/opt/zig:ro" \
    -v poof-zig-cache:/zig-cache \
    -e "GIT_COMMIT=$GIT_COMMIT" \
    -e "POOF_TEST_APT=${POOF_TEST_APT:-}" \
    "$IMAGE" \
    unshare -m --fork --propagation private bash -euo pipefail -s -- "$@" <<'INNER'

# --- optional tools ---------------------------------------------------------
# Installed before the root is moved, so the packages land in the copied tree.
# Only the diff-view tests need anything beyond coreutils (they want git).
if [[ -n "${POOF_TEST_APT:-}" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends $POOF_TEST_APT
fi

# --- cgroup delegation ------------------------------------------------------
# A cgroup that has processes attached cannot enable controllers for its
# children, and the container's root cgroup holds every process - so poof finds
# nowhere to put a limited child and --memory/--pids are refused. Empty the root
# into a holder first, then turn the controllers on there.
mkdir -p /sys/fs/cgroup/poof-holder
for p in $(cat /sys/fs/cgroup/cgroup.procs); do
    echo "$p" > /sys/fs/cgroup/poof-holder/cgroup.procs 2>/dev/null || true
done
echo "+memory +pids" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

# --- move onto a plain tmpfs root -------------------------------------------
# --one-file-system skips the bind mounts (/src, /opt/zig, /zig-cache), so the
# checkout and bun are copied in and zig's cache is re-attached afterwards.
mkdir -p /newroot
mount -t tmpfs -o size=2G tmpfs /newroot
tar -C / --one-file-system \
    --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./newroot \
    -cf - . | tar -C /newroot -xf -
mkdir -p /newroot/work /newroot/proc /newroot/sys /newroot/dev /newroot/oldroot
tar -C /src --exclude=./.zig-cache --exclude=./zig-out -cf - . | tar -C /newroot/work -xf -
cp /usr/local/bin/bun /newroot/usr/local/bin/bun
mount --bind /newroot /newroot
cd /newroot
pivot_root . oldroot
mount -t proc proc /proc
mount --rbind /oldroot/dev /dev        # bun drives a pty; poof fills in its own /dev
mount --rbind /oldroot/sys /sys        # cgroup v2, for --memory/--pids
mount --rbind /oldroot/opt/zig /opt/zig
mount --rbind /oldroot/zig-cache /zig-cache
umount -l /oldroot

# --- build and test ----------------------------------------------------------
export ZIG_GLOBAL_CACHE_DIR=/zig-cache
cd /work
/opt/zig/zig build -Dgit-commit="$GIT_COMMIT"
bun test "$@"
INNER
