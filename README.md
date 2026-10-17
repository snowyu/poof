<pre>
 ▗▄▄▖  ▗▄▖  ▗▄▖ ▗▄▄▄▖
 ▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌
 ▐▛▀▘ ▐▌ ▐▌▐▌ ▐▌▐▛▀▀▘
 ▐▌   ▝▚▄▞▘▝▚▄▞▘▐▌
  Ephemeral filesystem isolation
</pre>

**Run any command in an isolated environment where filesystem changes never affect your host.** When the command exits, changes vanish — or persist to a directory of your choice — or get reviewed and selectively applied. Linux only.

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
| **Persistent mode** | Capture all changes to a directory for inspection or replay |
| **Interactive mode** | Edit files in a sandbox, then review a diff and apply changes |
| **Full isolation** | Mount, PID, UTS, and IPC namespace isolation |
| **Resource limits** | Memory limits, process limits, timeouts via cgroups v2 |
| **Container-aware** | Works inside Docker/Podman (one nesting level) |
| **Single binary** | ~450KB static executable with no dependencies |

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
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/poof /usr/local/bin/
```

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

When run interactively (tty), shows a diff and prompts to apply changes — just like `enter` but with any command. When run non-interactively (scripts/pipes), auto-saves to a directory named after the command.

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
```

Because a stash mirrors absolute paths, `<stash>/home/me/proj/x.c` applies to
`/home/me/proj/x.c`: the target is encoded in the paths, so a stash made in one
session can be applied in another. Deletions are replayed as deletions, and file
modes and symlinks are preserved. The change list is always shown first; applying
without a terminal requires `--yes`.

---

## Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show detailed progress and debug info |
| `-h, --help` | Show help message |
| `-V, --version` | Show version information |
| `--upper=<dir>` | Directory for persistent changes (`run` mode) |
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

poof uses Linux kernel features to create complete isolation:

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

- `exec` mode: Upper layer is a tmpfs that vanishes on exit
- `run` mode: Upper layer is a real directory that persists
- `enter` mode: Upper layer is a temp directory, contents applied on confirmation

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
- **`run` mode in containers** — Doesn't work inside overlay environments; use `exec`
- **Special filesystems** — `/proc`, `/sys`, `/dev` are remounted fresh

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
  1. Create a "whiteout" character device in upperdir
  2. Overlay hides the lowerdir file
  3. Lowerdir file remains untouched
```

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
  - Character device (whiteout) → "deleted" (red -)
  - Empty directory → "added directory" (green +)
```

If you confirm with 'y', poof replays the upperdir onto the target instead of copying it:
whiteouts become real deletions, missing directories are created, symlinks are
recreated as symlinks, and regular files are copied with their mode. Overlay
bookkeeping (`.wh..wh..opq`, `.wh..opq`) is never copied, and a directory the
sandbox created replaces the target directory's contents (opaque marker).

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
  $ poof run --upper=./changes bash   # Persist to ./changes/

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
  --upper=<dir>       Save changes to directory (skip prompt)
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

The stash is kept after applying: remove it yourself once you are done.
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
  run   <program>             Review & apply on exit (or --upper to persist)
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
