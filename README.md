<pre>
 ▗▄▄▖  ▗▄▖  ▗▄▖ ▗▄▄▄▖
 ▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌
 ▐▛▀▘ ▐▌ ▐▌▐▌ ▐▌▐▛▀▀▘
 ▐▌   ▝▚▄▞▘▝▚▄▞▘▐▌
  Ephemeral filesystem isolation
</pre>

**Run any command in an isolated environment where filesystem changes never touch your host until you say so.** When the command exits, its changes are kept in a stash you can review and replay — or destroyed with `--no-keep`, or applied as it exits with `--yes`. Linux only.

> **Warning**: This is an **experimental** package. It was written by Claude in a couple of hours and has minimal testing. Use at your own risk.

```bash
# Run Claude Code with full permissions in a sandbox
poof claude --dangerously-skip-permissions

# Its changes are kept: review them, then poof apply
poof bun install

# Nothing survives the command
poof --no-keep rm -rf ~

# Applied as soon as the command exits
poof --yes make

# A shell, reviewed when you leave it
poof
```

---

## Features

| Feature | Description |
|---------|-------------|
| **Zero-trace execution** | Run commands without leaving any trace on the host filesystem |
| **Stash & replay** | A session's changes land in one directory (an overlay upper dir); inspect it, or replay it with `poof apply` |
| **Interactive mode** | Edit files in a sandbox, then review a diff and apply changes |
| **Namespace isolation** | Mount, PID, UTS and IPC namespaces (network is *not* isolated — see below) |
| **Resource limits** | Memory limits, process limits, timeouts via cgroups v2 |
| **Container-aware** | works inside Docker/Podman; keeping the changes needs a stash dir that is not itself on an overlay |
| **Single binary** | ~350KB static executable with no dependencies |

---

## Installation

### Debian / Ubuntu

```bash
curl -LO https://github.com/jarred-sumner/poof/releases/latest/download/poof_amd64.deb
sudo dpkg -i poof_amd64.deb
```

For ARM64:
```bash
curl -LO https://github.com/jarred-sumner/poof/releases/latest/download/poof_arm64.deb
sudo dpkg -i poof_arm64.deb
```

### Arch Linux

```bash
curl -LO https://github.com/jarred-sumner/poof/releases/latest/download/poof-x86_64.pkg.tar.xz
sudo pacman -U poof-x86_64.pkg.tar.xz
```

### Static Binary (any distro)

```bash
# x86_64 (static musl build, no dependencies)
curl -L https://github.com/jarred-sumner/poof/releases/latest/download/poof-linux-x86_64-musl -o poof
chmod +x poof
sudo mv poof /usr/local/bin/

# ARM64
curl -L https://github.com/jarred-sumner/poof/releases/latest/download/poof-linux-aarch64-musl -o poof
chmod +x poof
sudo mv poof /usr/local/bin/
```

### From Source

Requires [Zig](https://ziglang.org/) 0.17+ and Linux:

```bash
git clone https://github.com/jarred-sumner/poof
cd poof
zig build -Doptimize=ReleaseFast -Dgit-commit=$(git rev-parse --short HEAD)
sudo cp zig-out/bin/poof /usr/local/bin/
```

`-Dgit-commit` is worth passing: Zig caches the configure step, so the commit poof
looks up by itself is pinned to the last configure of `build.zig` and can lag behind
`HEAD`. Without the flag, `poof --version` labels that value "from last configure".

---## What happens to the changes

poof never writes to the real directory unless you tell it to. What the changes do
when the command exits is a flag, not a mode:

| Flag | What happens to the changes |
|------|-----------------------------|
| *(default)* | kept in a stash under `/tmp/poof-<hex>`; `poof stash list` finds it, `poof apply` replays it |
| `--no-keep` | destroyed with the sandbox; nothing survives |
| `--keep=<dir>` | kept in `<dir>` instead of a `/tmp` stash, and applied by you, by path |
| `--yes` | applied to the real directory as the command exits |

### Keeping them (the default)

```bash
# Let Claude edit your code, review the changes before applying them
poof claude --dangerously-skip-permissions

# See what bun install does before committing to it
poof bun install
#   poof: 3 changed files /tmp/poof-4f2a9c1b7d3e8a55
#     + src/new-file.txt
#     ~ src/modified.txt
#     - src/deleted.txt
#   Changes will be kept in /tmp/poof-4f2a9c1b7d3e8a55
#   replay them with: poof apply /tmp/poof-4f2a9c1b7d3e8a55
```

From a terminal the same session shows the list and asks rather than leaving the
stash: `y` applies, `n` keeps it, `d` shows the full diff first. A command that
exits non-zero keeps its changes too — a failed build's edits are usually the
ones worth looking at.

### `--no-keep` — nothing survives

All filesystem modifications disappear when the command exits. Perfect for
testing, experimentation, or running untrusted code.

```bash
# Filesystem changes vanish when done
poof --no-keep rm -rf ~

# Run untrusted scripts from the internet
curl -s https://example.com/setup.sh | poof --no-keep bash
```

### `--keep=<dir>` — your own stash directory

```bash
poof --keep=./my-changes -- make
poof apply ./my-changes
```

The changes go to `<dir>` (relative to the working directory) and nothing is
applied on its own. This is also how changes are kept inside a container, where
the root is often an overlay the kernel refuses as an upper dir
([Persisting changes inside a container](#persisting-changes-inside-a-container)).

### `--yes` — apply as the command exits

```bash
poof --yes make
```

The change list is printed, then applied, with no prompt. In a script this is the
difference between “leave it for me to review” and “just do it”.

### A shell, not a command

`poof` with no command opens your `$SHELL` in the sandbox. When you exit it, poof
shows the change list and asks: `y` to apply, `n` to keep the stash, `d` for the
full diff. `--no-keep` makes it a disposable shell; `--yes` applies what you did
when you leave it.

```bash
poof                  # review the changes on exit
poof --no-keep        # nothing survives
poof --yes            # apply what you did, on exit
```

This is ideal for:
- Making experimental changes you might want to keep
- Editing config files with a safety net
- Testing installations before committing

### `apply` — Replay a saved stash

A session that ends without applying its changes keeps them in an upper dir (a
*stash*). Nothing is merged back into the original directory automatically — the
changes sit there, mirroring absolute paths, until you replay them:

```bash
poof stash list
#   12 change(s)  3h ago  /tmp/poof-4f2a9c1b7d3e8a55

poof apply /tmp/poof-4f2a9c1b7d3e8a55
#   poof: 12 changed files /tmp/poof-4f2a9c1b7d3e8a55
#     + home/me/proj/new-file.txt
#     ~ home/me/proj/modified.txt
#     - home/me/proj/deleted.txt
#   Apply these 12 change(s) to /? [y/N]:

poof apply /tmp/poof-4f2a9c1b7d3e8a55 --yes   # no prompt, for scripts
poof --apply=/tmp/poof-4f2a9c1b7d3e8a55 --yes
# a stash that applies in full is removed; a partial failure keeps it for a retry
```

Because a stash mirrors absolute paths, `<stash>/home/me/proj/x.c` applies to
`/home/me/proj/x.c`: the target is encoded in the paths, so a stash made in one
session can be applied in another. Deletions are replayed as deletions, and file
modes and symlinks are preserved. The change list is always shown first; applying
without a terminal requires `--yes`.

Apply is a replay, not a merge: the stash's copy of a file wins and its deletions
delete, whatever the host did in the meantime. Measured — a session stashed a new
version of `mod.txt` and a deletion of `del.txt`; the host then rewrote `mod.txt` and
recreated `del.txt`; after `poof apply` the file holds the session's version and
`del.txt` is gone again. Review the list (or `poof apply` without `--yes`) before
applying a stash onto a tree that has moved on.

---

## Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show detailed progress and debug info |
| `-h, --help` | Show help message |
| `-V, --version` | Show version information |
| `--keep=<dir>` | Keep the changes in `<dir>` instead of a `/tmp` stash; nothing is applied on its own |
| `--no-keep` | Destroy the changes when the command exits |
| `--yes` | Apply the changes as the command exits; also confirms `poof apply` without prompting |
| `--upper=<dir>` | Deprecated name for `--keep=<dir>` |
| `--apply=<stash>` | Replay a saved stash onto the host (no sandbox started) |
| `--timeout=<secs>` | Kill process after N seconds (exit code 124) |
| `--memory=<size>` | Memory limit, e.g. `100M`, `1G` |
| `--pids=<max>` | Max processes (fork bomb protection, minimum 2) |

`--pids` must be at least 2: the sandbox always runs a tiny init plus the command, and
one more process for `fuse-overlayfs` when running unprivileged. A limit that cannot
boot the sandbox is rejected up front instead of failing inside it.

### Resource Limits

```bash
# Limit memory to 512MB
poof --memory=512M bun install

# Protect against fork bombs
poof --pids=50 ./untrusted-script.sh

# Kill after 30 seconds
poof --timeout=30 make test

# Combine limits
poof --memory=1G --pids=100 --timeout=60 cargo build
```

---

## How It Works

poof leans on four Linux kernel features:

```
┌─────────────────────────────────────────┐
│              Your Command               │
├─────────────────────────────────────────┤
│         Overlay Filesystem              │
│  ┌─────────────┐    ┌────────────────┐  │
│  │ Upper Layer │ +  │  Lower Layer   │  │
│  │  (changes)  │    │ (host root /)  │  │
│  └─────────────┘    └────────────────┘  │
├─────────────────────────────────────────┤
│   PID / UTS / IPC / Mount Namespaces    │
├─────────────────────────────────────────┤
│              Host System                │
└─────────────────────────────────────────┘
```

| Namespace | Isolation |
|-----------|-----------|
| **Mount** | Private mount tree with overlayfs |
| **PID** | Isolated process tree (nothing outside the sandbox is visible) |
| **UTS** | Isolated hostname |
| **IPC** | Isolated System V IPC |

- `--no-keep`: the upper layer is a tmpfs, destroyed together with the namespace
- *(default)*: the upper layer is a stash under `/tmp`, so the changes outlive the session as a stash — the host tree is still untouched
- `--keep=<dir>`: the upper layer is a directory you chose, replayed by path with `poof apply`

### The lower layer is the live root

poof never copies or snapshots the tree it sandboxes. The overlay it mounts is always:

```
lowerdir=/   upperdir=<your dir, or a temp dir>   workdir=<upperdir>.work
```

The lower layer *is* the live root mount, and the upper layer holds only what the
command changed. That is why a stash is just the upper dir — no saved lower layer, no
snapshot to keep in sync. It mirrors absolute paths from `/`
(`<stash>/home/me/proj/x.c` → `/home/me/proj/x.c`), and `poof apply` replays those
deltas onto the filesystem **as it is now** - apply is a replay, not a merge against a
snapshot ([`poof apply`](#apply--replay-a-saved-stash)).

The `workdir` is overlayfs bookkeeping and must sit on the same filesystem as the
upper dir; poof puts it beside it as `<upperdir>.work` and removes it when the session
ends. A stash is only the upper dir.

### Filesystems mounted under the root

The lower layer is one mount — the root — so a filesystem mounted *below* it is not
part of the overlay:

| | as root (kernel overlayfs) | unprivileged (fuse-overlayfs) |
|---|---|---|
| contents of a fs mounted at e.g. `/data` | **not visible**: the sandbox sees `/data` as it exists on the root mount, with the mounted tree hidden behind it | visible and readable (the lower is reached by ordinary path lookups) |
| writing there during a session | goes into the upper dir | goes into the upper dir |
| after `poof apply` | the stashed path is written to whatever is mounted there at apply time | same |

Measured with a tmpfs on `/data` holding `on-mount.txt`, over a root mount that has
`under.txt` in that directory: a root session lists `under.txt` and reports
`on-mount.txt` as missing; an unprivileged session lists both. Either way a write to
`/data/new.txt` lands in the stash as `data/new.txt` and reaches the tmpfs only when
applied.

So the overlay's domain is the root mount's tree: a nested mount is at best readable
(fuse-overlayfs), never written, and with the kernel driver not even readable. If the
tree you care about lives on its own mount — a separate `/home` partition, a container
volume, a `--tmpfs` — poof is not overlaying it: run poof where that filesystem *is*
the root (inside a container, that is what `./scripts/test-docker.sh` arranges by
moving the container onto a plain tmpfs root).

poof says so up front rather than letting you find out from a lost write. Before a
session starts it looks up the working directory in `/proc/mounts` and warns if the
mount covering it is not the root mount:

```console
$ cd /dev/shm/some-workdir && poof -- make
⚠ /dev/shm/some-workdir sits on the tmpfs mount at /dev/shm, not the root filesystem
● poof overlays the root mount only: as root the mounted tree is not visible inside the sandbox, and writes there land in the upper dir instead
```

It is a warning, not a refusal: the session still runs, and a command that only reads
the nested mount (or writes to the root mount) is unaffected. Nothing is printed when
the working directory is on the root mount, which is the normal case.

---

## Running Unprivileged

poof can run without root using user namespaces and fuse-overlayfs:

```bash
# Install fuse-overlayfs
sudo apt install fuse-overlayfs    # Debian/Ubuntu
sudo pacman -S fuse-overlayfs      # Arch

# Enable user namespaces (if not already enabled)
sudo sysctl kernel.unprivileged_userns_clone=1

# Run poof as a regular user
poof --no-keep echo "No root required!"
```

| Mechanism | Root | Non-root (with fuse-overlayfs) |
|-----------|------|--------------------------------|
| Kernel overlayfs | Yes | No |
| User namespaces | No | Yes |
| `/proc` mount | Yes | No (limited) |

---

## Docker / Container Support

### Quick Start (easiest)

```bash
docker run -it --privileged ubuntu bash
poof --no-keep echo "Works!"
```

### Minimal Permissions (recommended)

```bash
# With fuse-overlayfs - no CAP_SYS_ADMIN needed!
docker run -it \
  --device /dev/fuse \
  --security-opt seccomp=unconfined \
  my-image-with-fuse-overlayfs bash
poof --no-keep echo "Works without CAP_SYS_ADMIN!"
```

poof auto-detects when CAP_SYS_ADMIN is missing and falls back to user namespaces + fuse-overlayfs.

### With CAP_SYS_ADMIN (kernel overlayfs)

```bash
# Uses faster kernel overlayfs, no fuse-overlayfs needed
docker run -it --cap-add=SYS_ADMIN --security-opt seccomp=unconfined ubuntu bash
poof --no-keep echo "Works with kernel overlay!"
```

### Persisting changes inside a container

`--no-keep` works anywhere. Keeping changes needs somewhere to put them, and the
kernel refuses an upper dir that is itself on an overlay - which a container root
normally is. Put the stash on a filesystem that is not an overlay:

```bash
docker run -it --privileged --tmpfs /var/tmp ubuntu bash
poof --keep=/var/tmp/changes -- make   # review and apply afterwards
poof apply /var/tmp/changes
```

poof says so rather than failing obscurely:

```
✗ error: the stash cannot live on overlayfs: /var/tmp/changes is on an overlay mount
✗ error: move it with --keep=<dir> onto a tmpfs or a volume (in Docker: --tmpfs /var/tmp)
✗ error: or drop the changes entirely: poof --no-keep <program>
```

Note that a `--tmpfs` mount is only good for the upper dir: a *target* directory on a
nested mount is not part of the overlay at all, because the lower layer is the
container's own root ([Filesystems mounted under the root](#filesystems-mounted-under-the-root)).
Run the test suite in a container with `./scripts/test-docker.sh`, which moves the
container onto a plain tmpfs root so the whole tree can be overlaid.

### Docker Permission Reference

| Flag | Why needed |
|------|-----------|
| `--privileged` | Full access (overkill but simple) |
| `--cap-add=SYS_ADMIN` | For kernel overlayfs (optional if fuse-overlayfs available) |
| `--security-opt seccomp=unconfined` | Allow `mount` and `unshare` syscalls |
| `--device /dev/fuse` | For fuse-overlayfs |

### Minimum Requirements

| Setup | Flags needed |
|-------|--------------|
| With fuse-overlayfs | `--device /dev/fuse --security-opt seccomp=unconfined` |
| Without fuse-overlayfs | `--cap-add=SYS_ADMIN --security-opt seccomp=unconfined` |

> **Note:** Kernel overlayfs limits stacking to 2 levels. Inside a Docker container (1 level), you get one poof level. Use fuse-overlayfs for unlimited nesting.

---

## Environment Variables

| Variable | Effect |
|----------|--------|
| `NO_COLOR` | Disable colored output |
| `SHELL` | Shell opened when poof is given no command (default: `/bin/sh`) |
| `IS_SANDBOX` | Set to `1` inside the sandbox (useful for scripts to detect sandbox) |

---

## Requirements

**As root:**
- Linux kernel 4.0+

**As regular user (unprivileged):**
- Linux kernel 4.0+
- `fuse-overlayfs` installed
- User namespaces enabled: `sysctl kernel.unprivileged_userns_clone=1`

**For resource limits (optional):**
- cgroups v2 with memory/pids controllers

---

## Testing

```bash
zig build      # produces zig-out/bin/poof, which the suite drives
bun test       # as a regular user: root-only cases skip
```

Some behaviour only exists as root, so a normal host run cannot cover it: the
kernel overlay driver (a deleted file becomes a `0:0` character device, a
recreated directory is marked opaque with the `trusted.overlay.opaque` xattr)
where an unprivileged run uses fuse-overlayfs (`.wh.` files instead), real device
nodes (CAP_MKNOD), and cgroup delegation. Run those in a container:

```bash
./scripts/test-docker.sh                        # docker
POOF_CONTAINER_RUNTIME=podman ./scripts/test-docker.sh
POOF_TEST_APT=git ./scripts/test-docker.sh      # also cover the `d` diff view
```

The script starts a privileged container, moves it onto a plain tmpfs root (poof
cannot overlay a container's overlayfs root), turns on cgroup delegation, then
builds with the host's zig and bun bind mounted and runs the whole suite as root.
Cases whose prerequisites are missing - no root, no CAP_MKNOD, no cgroup
delegation, no git for the diff view - skip instead of failing.

---

## What poof does and doesn't isolate

| Isolated | Not isolated |
|----------|--------------|
| Filesystem writes | Network access |
| Filesystem deletes | Environment variables |
| Process tree (PID namespace) | GPU/hardware access |
| Hostname (UTS namespace) | System time |
| System V IPC | User credentials (outside namespace) |

poof is designed to make **filesystem changes reversible**, not to provide full security sandboxing. Commands can still make network requests, read environment variables, and access hardware.

---

## Limitations

- **Linux only** — Uses Linux-specific kernel features (namespaces, overlayfs)
- **Overlay depth** — Maximum 2 levels of overlay stacking (kernel limit)
- **Keeping changes in containers** — the kernel refuses an upper dir that sits on
  an overlay mount, and a container root usually is one; point `--keep` at a tmpfs
  or a volume, or use `--no-keep` (see [Docker / Container Support](#docker--container-support))
- **Special filesystems** — `/proc`, `/sys`, `/dev` are remounted fresh
- **Nested mounts** — the lower layer is the root mount, so filesystems mounted
  under it sit outside the overlay; poof warns when the working directory is on one
  ([Filesystems mounted under the root](#filesystems-mounted-under-the-root))

---

## License

MIT

---

## Technical Deep Dive

### Process Lifecycle

When you run `poof --no-keep <command>`:

```
1. Parent process
   ├── Create temp directory /tmp/poof-<random>/
   ├── Set up cgroup (if resource limits specified)
   └── fork()
       │
       2. First child
          ├── unshare(CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWIPC)
          │   └── If non-root: also CLONE_NEWUSER
          ├── Set up uid/gid mappings (user namespace)
          └── fork()  ← Required to enter new PID namespace
              │
              3. Second child (PID 1 in new namespace — the "tiny init")
                 ├── Join the limit cgroup (if resource limits specified)
                 ├── Mount tmpfs on /tmp/poof-<random>/
                 ├── Create upper/, work/, merged/ directories
                 ├── Mount overlay:
                 │     lowerdir=/
                 │     upperdir=/tmp/poof-<random>/upper
                 │     workdir=/tmp/poof-<random>/work
                 │     merged=/tmp/poof-<random>/merged
                 ├── Set up minimal /dev (bind mount null, zero, urandom, etc.)
                 ├── pivot_root(merged, merged/.oldroot)
                 ├── umount(/.oldroot, MNT_DETACH)
                 ├── Mount fresh /proc and /tmp
                 ├── fork() + execve(<command>)
                 │     └── The command is a child of PID 1, not PID 1 itself: the
                 │         kernel discards unhandled SIGTERM/SIGINT for a pid
                 │         namespace's init and swallows crash signals, so running
                 │         the command directly would lose signal-driven exit codes.
                 │         PID 1 forwards INT/TERM/HUP/QUIT and reports 128+signum.
                 └── [command runs with full filesystem illusion]
```

### Overlay Filesystem

The overlay filesystem is the core mechanism that makes changes invisible:

```
Reading a file:
  1. Check upperdir — if file exists, use it
  2. Otherwise, read from lowerdir (host filesystem)

Writing a file:
  1. Copy file from lowerdir to upperdir (copy-up)
  2. Write to upperdir copy
  3. Lowerdir remains untouched

Deleting a file:
  1. Record a whiteout in upperdir — a 0:0 character device with kernel
     overlayfs, a `.wh.<name>` entry with fuse-overlayfs
  2. Overlay hides the lowerdir file
  3. Lowerdir file remains untouched
```

`lowerdir` is always the live root mount, never a copy of it (see [The lower layer is
the live root](#the-lower-layer-is-the-live-root)). A stash is therefore only the
upper dir: the deltas, mirroring absolute paths from `/`.

With `--no-keep`, upperdir is on a tmpfs — when the namespace exits, the tmpfs is destroyed and all changes vanish.

When the changes are kept, upperdir is poof's own `/tmp/poof-<hex>` stash or the `--keep` directory, and workdir sits beside it (`<upper>.work`, required to be on the same filesystem as upperdir), but the merged mount point is placed inside a private tmpfs under `/tmp` instead. The sandbox never sees the path the overlay is mounted at — that keeps fuse-overlayfs from resolving its own mount point when a sandboxed process walks the tree around it.

### Namespace Isolation

| Namespace | What it isolates | Effect in poof |
|-----------|------------------|----------------|
| **Mount (CLONE_NEWNS)** | Mount table | Overlay mounts are private; host sees nothing |
| **PID (CLONE_NEWPID)** | Process IDs | Sandbox has its own tree under a tiny init at PID 1; can't see/signal host processes |
| **UTS (CLONE_NEWUTS)** | Hostname | Container gets isolated hostname |
| **IPC (CLONE_NEWIPC)** | System V IPC | Shared memory, semaphores, message queues isolated |
| **User (CLONE_NEWUSER)** | UID/GID mappings | Non-root users get "fake root" inside namespace |

### Device Access

poof creates a minimal `/dev` with only safe devices:

| Device | Purpose |
|--------|---------|
| `/dev/null` | Data sink |
| `/dev/zero` | Zero bytes source |
| `/dev/full` | Always-full device |
| `/dev/random` | Random number generator (blocking) |
| `/dev/urandom` | Random number generator (non-blocking) |
| `/dev/tty` | Controlling terminal |
| `/dev/pts/*` | Pseudoterminal devices |

Dangerous devices like `/dev/sda`, `/dev/mem` are **not** exposed — the sandbox cannot access raw disks or memory.

### Cgroups v2 Resource Limits

`--memory` and `--pids` are enforced with a cgroup v2 leaf created next to poof's
own cgroup — the closest ancestor of the current cgroup that allows creating a
limited child (a cgroup with processes attached cannot enable controllers for its
children, so under systemd this usually lands in `app.slice` rather than the top of
the hierarchy, which is why it also works for unprivileged users):

```
<nearest workable cgroup>/poof-<random>/
├── cgroup.procs          ← Sandbox PID written here by the sandbox child itself
├── memory.max            ← --memory limit (e.g. "104857600" for 100M)
├── memory.swap.max       ← 0 (memory.max is only a real cap if swap is pinned off)
├── memory.oom.group      ← 1 (kill the whole sandbox on OOM)
└── pids.max              ← --pids limit (e.g. "50")
```

poof's own process stays outside the cgroup, so an OOM kill takes the sandbox down
while the parent survives to clean up (exit code 137). If no place in the hierarchy
allows this, poof fails with a clear error instead of running unlimited.

`--timeout` is not a cgroup feature: the parent watches the clock and sends SIGKILL
(exit code 124).

### Root vs Non-Root Execution

**As root (or with CAP_SYS_ADMIN):**
- Uses kernel overlayfs (fast, native)
- Uses `pivot_root` for strong isolation
- Direct mount syscalls

**As regular user:**
- Uses user namespace to get "fake root"
- Uses fuse-overlayfs (userspace, slightly slower)
- Uses `chroot` (pivot_root requires real root)
- UID 0 inside maps to your real UID outside

### Change Detection

When a session ends with its changes still unapplied, poof scans the upperdir:

```
For each file in upperdir:
  - Regular file that exists in target → "edited" (yellow ~)
  - Regular file that doesn't exist in target → "added" (green +)
  - Whiteout (0:0 character device, or a `.wh.` entry) → "deleted" (red -)
  - Empty directory → "added directory" (green +)
```

If you confirm with 'y', poof replays the upperdir onto the target instead of copying it:
whiteouts become real deletions, missing directories are created, symlinks are
recreated as symlinks, and regular files are copied with their mode. Overlay
bookkeeping (`.wh..wh..opq`, `.wh..opq`) is never copied, and a directory the sandbox
created replaces the target directory's contents: the opaque marker is read from the
`trusted.overlay.opaque` / `user.overlay.opaque` xattr the kernel driver leaves, and
otherwise from the `.wh..wh..opq` file fuse-overlayfs writes.

---

## Command Reference

### `poof`

```
poof — Run a command; its filesystem changes stay out of the host

USAGE
  poof [options] [--] <program> [args...]
  poof [options]                     interactive shell

CHANGES
  (default)      keep them in a /tmp stash, replay with poof apply
  --no-keep      destroy them when the command exits
  --keep=<dir>   keep them in <dir> instead of a /tmp stash
  --yes          apply them to the real directory as the command exits

EXAMPLES
  $ poof bun install              # kept; replay with poof apply
  $ poof --yes make               # applied as soon as it exits
  $ poof --no-keep rm -rf ~       # Safe! Nothing happens
  $ poof                          # a shell, reviewed on exit

OPTIONS
  -v, --verbose               Show detailed progress
  -h, --help                  Show this help
  -V, --version               Show version
  --timeout=<secs>            Kill after N seconds (exit code 124)
  --memory=<bytes>            Memory limit (e.g. 100M, 1G)
  --pids=<max>                Max processes (fork bomb protection)
  --upper=<dir>               Deprecated: use --keep=<dir>
```

From a terminal, the exit looks like this:

```
  poof: 3 changed files /tmp/poof-4f2a9c1b7d3e8a55
    + src/new-file.txt
    ~ src/modified.txt
    - src/deleted.txt

  Apply these changes to /home/me/proj? [y/N/d(iff)]:
    y — apply them to the real directory
    n — leave them in the stash; poof apply <stash> replays them later
    d — show the full diff first
```

If the session ends abnormally (`--timeout`, or SIGINT/SIGTERM/SIGHUP to poof), the
changes are never destroyed silently: they are kept in the stash and poof prints
`Stashed changes in <dir>`. That stash is applied later with `poof apply <dir>`
(see below); `poof stash list` finds them.

### Deprecated: `exec`, `run`, `enter`

The three mode words still work, and each prints a one-line warning; they are kept
so existing scripts keep running.

| Then | Now |
|------|-----|
| `poof exec <program>` | `poof --no-keep <program>` |
| `poof run <program>` | `poof <program>` |
| `poof run --upper=<dir> <program>` | `poof --keep=<dir> <program>` |
| `poof enter` | `poof` |
| `poof enter /etc` | `cd /etc && poof` |

`poof enter <dir>` has no flag equivalent: the plain form reads its first
positional as the program to run, so to sandbox a different directory, change
into it first.

### `poof apply`

```
poof apply — Replay a saved upper dir (stash) onto the host

USAGE
  poof apply [options] <stash>
  poof --apply=<stash>         the same, script-friendly

EXAMPLES
  $ poof stash list                  # find stashes
  $ poof apply /tmp/poof-3f9a2b      # preview, then confirm
  $ poof apply /tmp/poof-3f9a2b --yes

NOTES
  A stash mirrors absolute paths, so <stash>/home/me/proj/x.c applies
  to /home/me/proj/x.c. Deletions are replayed as deletions (overlay
  whiteouts), file modes and symlinks are preserved.
  Applying writes straight to the filesystem: the change list is shown
  first and confirmation is required unless --yes is given.

OPTIONS
  --yes                      Apply without prompting
  -h, --help                 Show this help
```

A stash that applies in full is removed; one that hits any failure is kept so the
failures can be fixed and the same stash applied again. A stash that is the current
directory is applied but left in place rather than deleted under you.
A stash you chose with `--keep=<dir>` is applied by path — only poof's own
`/tmp/poof-<hex>` upper dirs are listed by `poof stash list`.

### `poof stash list`

```
poof stash list — List stashes left in /tmp

  12 change(s)  3h ago  /tmp/poof-4f2a9c1b7d3e8a55

Stashes with no changes are skipped. poof never deletes a stash on its own.
```

### `poof` (no args)

```
 ▗▄▄▖  ▗▄▖  ▗▄▖ ▗▄▄▄▖
 ▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌
 ▐▛▀▘ ▐▌ ▐▌▐▌ ▐▌▐▛▀▀▘
 ▐▌   ▝▚▄▞▘▝▚▄▞▘▐▌
  Ephemeral filesystem isolation

USAGE
  poof [options] [--] <program> [args...]
  poof [options]                     interactive shell

CHANGES
  poof never writes to the real directory unless you say so. These flags
  decide what happens to the changes a command makes:
    (default)      keep them in a /tmp stash, replay with poof apply
    --no-keep      destroy them when the command exits
    --keep=<dir>   keep them in <dir> instead of a /tmp stash
    --yes          apply them to the real directory as the command exits

COMMANDS
  apply <stash>               Replay a saved stash onto the host
  stash list                  List stashes left in /tmp
  exec / run / enter          Deprecated mode words, still accepted

OPTIONS
  -v, --verbose               Show detailed progress
  -h, --help                  Show this help
  -V, --version               Show version
  --timeout=<secs>            Kill after N seconds (exit code 124)
  --memory=<bytes>            Memory limit (e.g. 100M, 1G)
  --pids=<max>                Max processes (fork bomb protection)
  --upper=<dir>               Deprecated: use --keep=<dir>

ISOLATION
  • Mount namespace with overlay filesystem
  • PID namespace (isolated process tree)
  • UTS namespace (isolated hostname)
  • IPC namespace (isolated System V IPC)

EXAMPLES
  $ poof bun install              # kept; replay with poof apply
  $ poof --yes make               # applied as soon as it exits
  $ poof --no-keep rm -rf ~       # Safe! Nothing happens
  $ poof                          # a shell, reviewed on exit

NOTE  Works inside Docker/Podman (1 nesting level, kernel limit)
ENV   IS_SANDBOX=1 is set inside the sandbox
```

---

## See Also

- [bubblewrap](https://github.com/containers/bubblewrap) — Unprivileged sandboxing tool
- [firejail](https://github.com/netblue30/firejail) — SUID sandbox program
- [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html) — Lightweight container
