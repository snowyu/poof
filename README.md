<pre>
 ▗▄▄▖  ▗▄▖  ▗▄▖ ▗▄▄▄▖
 ▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌
 ▐▛▀▘ ▐▌ ▐▌▐▌ ▐▌▐▛▀▀▘
 ▐▌   ▝▚▄▞▘▝▚▄▞▘▐▌
  Ephemeral filesystem isolation
</pre>

**Run any command in an isolated environment where filesystem changes never touch your host until you say so.** When the command exits, its changes are discarded — or kept in a directory you choose, ready to review and apply. Linux only.

> **Warning**: This is an **experimental** package. It was written by Claude in a couple of hours and has minimal testing. Use at your own risk.

```bash
# Run Claude Code with full permissions in a sandbox
poof exec claude --dangerously-skip-permissions

# Filesystem changes vanish when done
poof exec rm -rf ~

# Run a command, review its changes, apply or discard
poof run bun install

# Interactive editing with review before applying
poof enter
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
| **Container-aware** | `exec` works inside Docker/Podman; `run`/`enter` need an upper dir that is not itself on an overlay |
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

---

## Modes

### `exec` — Ephemeral (changes vanish)

All filesystem modifications disappear when the command exits. Perfect for testing, experimentation, or running untrusted code.

```bash
# Run Claude with full permissions in a sandbox
poof exec claude --dangerously-skip-permissions

# Filesystem changes vanish when done
poof exec rm -rf ~

# Run untrusted scripts from the internet
curl -s https://example.com/setup.sh | poof exec bash
```

### `run` — Interactive by default

When run interactively (tty), shows the change list and prompts to apply them — just like `enter` but with any command. When run non-interactively (scripts/pipes), the changes are kept in a stash named after the command, which you replay later with `poof apply`.

```bash
# Let Claude edit your code, review changes before applying
poof run claude --dangerously-skip-permissions
# → Claude makes changes → exit → shows diff → y/n/d prompt

# Review what bun install does before committing
poof run bun install

# Explicit directory with --upper
poof run --upper=./my-changes bash
```

### `enter` — Interactive (review & apply)

Opens your `$SHELL` in an isolated environment. When you exit, poof shows a diff of all changes and prompts you to apply them.

```bash
poof enter
# Make changes, edit files, install things...
# When you type 'exit':
#   → See a diff of all modifications
#   → Press 'y' to apply, 'n' to discard, 'd' for full diff
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
poof run --apply=/tmp/poof-4f2a9c1b7d3e8a55 --yes
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
| `--upper=<dir>` | Where a session's changes are kept instead of a temp dir (`run` mode); the host is untouched until you `poof apply` it |
| `--apply=<stash>` | Replay a saved stash onto the host (no sandbox started) |
| `--yes` | Confirm `--apply` without prompting |
| `--timeout=<secs>` | Kill process after N seconds (exit code 124) |
| `--memory=<size>` | Memory limit, e.g. `100M`, `1G` |
| `--pids=<max>` | Max processes (fork bomb protection, minimum 2) |

`--pids` must be at least 2: the sandbox always runs a tiny init plus the command, and
one more process for `fuse-overlayfs` when running unprivileged. A limit that cannot
boot the sandbox is rejected up front instead of failing inside it.

### Resource Limits

```bash
# Limit memory to 512MB
poof exec --memory=512M bun install

# Protect against fork bombs
poof exec --pids=50 ./untrusted-script.sh

# Kill after 30 seconds
poof exec --timeout=30 make test

# Combine limits
poof exec --memory=1G --pids=100 --timeout=60 cargo build
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

- `exec` mode: the upper layer is a tmpfs that is destroyed on exit
- `run` mode: the upper layer is a directory you chose, so the changes outlive the session as a stash — the host tree is still untouched
- `enter` mode: the upper layer is a temp directory, replayed onto the host if you confirm

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

poof says so up front rather than letting you find out from a lost write. Before an
`exec`/`run`/`enter` session starts it looks up the working directory (for `enter`, the
target directory) in `/proc/mounts`, and warns if the mount covering it is not the root
mount:

```console
$ cd /dev/shm/some-workdir && poof exec -- make
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
poof exec echo "No root required!"
```

| Mode | Root | Non-root (with fuse-overlayfs) |
|------|------|--------------------------------|
| Kernel overlayfs | Yes | No |
| User namespaces | No | Yes |
| `/proc` mount | Yes | No (limited) |

---

## Docker / Container Support

### Quick Start (easiest)

```bash
docker run -it --privileged ubuntu bash
poof exec echo "Works!"
```

### Minimal Permissions (recommended)

```bash
# With fuse-overlayfs - no CAP_SYS_ADMIN needed!
docker run -it \
  --device /dev/fuse \
  --security-opt seccomp=unconfined \
  my-image-with-fuse-overlayfs bash
poof exec echo "Works without CAP_SYS_ADMIN!"
```

poof auto-detects when CAP_SYS_ADMIN is missing and falls back to user namespaces + fuse-overlayfs.

### With CAP_SYS_ADMIN (kernel overlayfs)

```bash
# Uses faster kernel overlayfs, no fuse-overlayfs needed
docker run -it --cap-add=SYS_ADMIN --security-opt seccomp=unconfined ubuntu bash
poof exec echo "Works with kernel overlay!"
```

### Persisting changes inside a container (`run` / `enter`)

`exec` works anywhere. `run` and `enter` additionally need somewhere to keep the
changes, and the kernel refuses an upper dir that is itself on an overlay - which
a container root normally is. Put the upper dir on a filesystem that is not an
overlay:

```bash
docker run -it --privileged --tmpfs /var/tmp ubuntu bash
poof run --upper=/var/tmp/changes -- make   # review and apply afterwards
poof apply /var/tmp/changes
```

poof says so rather than failing obscurely:

```
✗ error: 'run' mode needs --upper on a filesystem that is not an overlay
✗ error: /var/tmp/up is on overlayfs - put it on a tmpfs or a volume (in Docker: --tmpfs /var/tmp)
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
| `SHELL` | Shell used by `enter` mode (default: `/bin/sh`) |
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
- **`run` mode in containers** — the kernel refuses an upper dir that sits on an
  overlay mount, and a container root usually is one; point `--upper` at a tmpfs
  or a volume, or use `exec` (see [Docker / Container Support](#docker--container-support))
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

When you run `poof exec <command>`:

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

In `exec` mode, upperdir is on a tmpfs — when the namespace exits, the tmpfs is destroyed and all changes vanish.

In `run`/`enter` mode upperdir is the user's own directory and workdir sits beside it (`<upper>.work`, required to be on the same filesystem as upperdir), but the merged mount point is placed inside a private tmpfs under `/tmp` instead. The sandbox never sees the path the overlay is mounted at — that keeps fuse-overlayfs from resolving its own mount point when a sandboxed process walks the tree around it.

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

### Enter Mode Change Detection

When you exit an `enter` session, poof scans the upperdir:

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

### `poof exec`

```
poof exec — Run command in ephemeral sandbox (changes vanish)

USAGE
  poof exec [options] [--] <program> [args...]

EXAMPLES
  $ poof exec claude --dangerously-skip-permissions
  $ poof exec rm -rf ~                 # Safe! Nothing happens
  $ poof exec bash                    # Disposable shell
  $ poof exec --timeout=60 ./build.sh  # Kill if > 60s

OPTIONS
  --timeout=<secs>    Kill after N seconds (exit code 124)
  --memory=<size>     Memory limit (e.g. 100M, 1G)
  --pids=<max>        Max processes (fork bomb protection)
  -v, --verbose       Show detailed progress
```

### `poof run`

```
poof run — Run command, review changes, apply or discard

USAGE
  poof run [options] [--] <program> [args...]

EXAMPLES
  $ poof run claude --dangerously-skip-permissions
  $ poof run bun install              # Review changes first
  $ poof run --upper=./changes bash   # keep the changes there

When the command exits, you'll see:
  ● 3 changed files /tmp/poof-xxx
    + src/new-file.txt
    ~ src/modified.txt
    - src/deleted.txt

  Apply changes? [y/N/d]
    y — Apply all changes to host
    n — Discard (keep in temp dir)
    d — Show full diff first

If the session ends abnormally (`--timeout`, or SIGINT/SIGTERM/SIGHUP to poof), the
changes are never destroyed silently: they are kept in the temp dir and poof prints
`Stashed changes in <dir>`. That stash is applied later with `poof apply <dir>`
(see below); `poof stash list` finds them.

OPTIONS
  --upper=<dir>       Keep changes in <dir>, skip the prompt
  --timeout=<secs>    Kill after N seconds
  --memory=<size>     Memory limit (e.g. 100M, 1G)
  --pids=<max>        Max processes
  -v, --verbose       Show detailed progress
```

### `poof enter`

```
poof enter — Interactive shell with review on exit

USAGE
  poof enter [options] [directory]

Opens your $SHELL in an isolated environment. When you exit:
  1. See a summary of all changes
  2. Press 'y' to apply, 'n' to discard, 'd' for full diff

EXAMPLES
  $ poof enter                        # Start isolated shell
  $ poof enter -v                     # With verbose output
  $ poof enter /etc                   # Sandbox /etc, shell starts there

OPTIONS
  -v, --verbose       Show detailed progress
  --timeout=<secs>    Kill after N seconds
  --memory=<size>     Memory limit (e.g. 100M, 1G)
  --pids=<max>        Max processes
```

### `poof apply`

```
poof apply — Replay a saved upper dir (stash) onto the host

USAGE
  poof apply [options] <stash>
  poof run --apply=<stash>     the same, script-friendly

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
A stash you chose with `--upper=<dir>` is applied by path — only poof's own
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
  poof <command> [options] [--] <program> [args...]

COMMANDS
  exec  <program>             Run in ephemeral mode (changes vanish)
  run   <program>             Review & apply on exit (--upper=<dir> keeps a stash)
  enter                       Interactive $SHELL (review & apply on exit)
  apply <stash>               Replay a saved upper dir onto the host
  stash list                  List stashes left in /tmp

OPTIONS
  -v, --verbose               Show detailed progress
  -h, --help                  Show this help
  -V, --version               Show version
  --upper=<dir>               Directory for changes (run mode)
  --apply=<stash>             Replay a saved stash (no sandbox)
  --yes                       Confirm --apply without prompting
  --timeout=<secs>            Kill after N seconds
  --memory=<bytes>            Memory limit (e.g. 100M, 1G)
  --pids=<max>                Max processes (fork bomb protection)

ISOLATION
  • Mount namespace with overlay filesystem
  • PID namespace (isolated process tree)
  • UTS namespace (isolated hostname)
  • IPC namespace (isolated System V IPC)

EXAMPLES
  $ poof exec claude --dangerously-skip-permissions
  $ poof exec rm -rf ~                # Safe! Nothing happens
  $ poof run bun install              # Review changes first
```

---

## See Also

- [bubblewrap](https://github.com/containers/bubblewrap) — Unprivileged sandboxing tool
- [firejail](https://github.com/netblue30/firejail) — SUID sandbox program
- [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html) — Lightweight container
