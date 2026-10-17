import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { existsSync, mkdtempSync, rmSync, writeFileSync, readFileSync, mkdirSync, readdirSync, statSync, lstatSync, readlinkSync, symlinkSync, chmodSync } from "fs";
import { join } from "path";
import { StringDecoder } from "node:string_decoder";

const POOF_BIN = join(import.meta.dir, "../zig-out/bin/poof");
// Use ephemeral tmpdir - must be outside /tmp since poof mounts fresh /tmp
let TEST_DIR: string;
// Shell prompt: # for root, $ for non-root
const SHELL_PROMPT = process.getuid?.() === 0 ? "# " : "$ ";

// poof prints "Stashed changes in <dir>" when changes are kept; pull the path
// out of the (possibly colorized) output so tests can assert on it and clean up.
function stashPath(output: string): string | null {
  const m = output.match(/Stashed changes in(?:\u001b\[[0-9;]*m)?\s+(\S+)/);
  return m ? m[1] : null;
}

// A stash is the upper dir plus its work dir beside it; remove both.
function cleanupStash(output: string) {
  const stash = stashPath(output);
  if (!stash) return;
  rmSync(stash, { recursive: true, force: true });
  rmSync(stash + ".work", { recursive: true, force: true });
}

// Helper class for terminal (PTY) interaction with poof
let activeSession: TerminalSession | null = null;

class TerminalSession {
  output = "";
  private decoder = new StringDecoder("utf8");
  private proc: ReturnType<typeof spawn>;
  private cursor = 0; // Track position for waitForNew

  constructor(cwd: string, env?: Record<string, string>, args: string[] = [], mode = "enter") {
    this.proc = spawn([POOF_BIN, mode, ...args], {
      cwd,
      env: { ...process.env, ...env },
      terminal: {
        cols: 80,
        rows: 24,
        data: (_terminal, data) => {
          this.output += this.decoder.write(Buffer.from(data));
        },
      },
    });
    activeSession = this;
  }

  write(text: string) {
    this.proc.terminal!.write(text);
  }

  // Wait for text anywhere in output
  async waitFor(text: string, timeout = 5000) {
    const start = Date.now();
    while (!this.output.includes(text)) {
      if (Date.now() - start > timeout) {
        throw new Error(`Timeout waiting for "${text}". Output so far:\n${this.output}`);
      }
      await Bun.sleep(10);
    }
  }

  // Wait for NEW text after current cursor position, then advance cursor
  async waitForNew(text: string, timeout = 5000) {
    const start = Date.now();
    while (true) {
      const idx = this.output.indexOf(text, this.cursor);
      if (idx !== -1) {
        this.cursor = idx + text.length;
        return;
      }
      if (Date.now() - start > timeout) {
        throw new Error(`Timeout waiting for "${text}". Output after cursor:\n${this.output.slice(this.cursor)}`);
      }
      await Bun.sleep(10);
    }
  }

  kill() {
    this.proc.kill();
  }

  async waitForExit() {
    return this.proc.exited;
  }
}

// poof keeps a stash in /tmp/poof-* whenever changes are discarded. Tests that
// discard on purpose clean up after themselves; this catches the rest so a suite
// run leaves nothing behind (without touching stashes that predate the run).
function listPoofStashes(): string[] {
  try {
    return readdirSync("/tmp")
      .filter((n) => n.startsWith("poof-"))
      .map((n) => join("/tmp", n));
  } catch {
    return [];
  }
}

describe("poof CLI", () => {
  let stashesBefore: string[] = [];

  beforeAll(() => {
    if (!existsSync(POOF_BIN)) {
      throw new Error(`poof binary not found at ${POOF_BIN}. Run 'zig build' first.`);
    }
    TEST_DIR = mkdtempSync(join("/var/tmp", "poof-test-"));
    // Force bash for consistent prompt detection
    process.env.SHELL = "/bin/bash";
    stashesBefore = listPoofStashes();
  });

  afterAll(() => {
    if (TEST_DIR && existsSync(TEST_DIR)) {
      rmSync(TEST_DIR, { recursive: true });
    }
    for (const path of listPoofStashes()) {
      if (!stashesBefore.includes(path)) rmSync(path, { recursive: true, force: true });
    }
  });

  // ============================================================================
  // Help and Usage
  // ============================================================================
  describe("help and usage", () => {
    test("--help shows usage on stdout", () => {
      const result = spawnSync([POOF_BIN, "--help"]);
      const output = result.stdout.toString();
      expect(output).toContain("USAGE");
      expect(output).toContain("COMMANDS");
      expect(output).toContain("exec");
      expect(output).toContain("run");
      expect(output).toContain("enter");
      // Help is the requested result: it must be pipeable, not on stderr.
      expect(result.stderr.toString()).toBe("");
      expect(result.exitCode).toBe(0);
    });

    test("-h shows usage on stdout", () => {
      const result = spawnSync([POOF_BIN, "-h"]);
      expect(result.stdout.toString()).toContain("USAGE");
      expect(result.exitCode).toBe(0);
    });

    test("--version prints to stdout", () => {
      const result = spawnSync([POOF_BIN, "--version"]);
      expect(result.stdout.toString()).toMatch(/^poof \S+/);
      expect(result.stderr.toString()).toBe("");
      expect(result.exitCode).toBe(0);
    });

    test("-V prints version to stdout", () => {
      const result = spawnSync([POOF_BIN, "-V"]);
      expect(result.stdout.toString()).toMatch(/^poof \S+/);
      expect(result.exitCode).toBe(0);
    });

    test("per-mode help after the subcommand", () => {
      const cases: [string, string][] = [
        ["exec", "poof exec"],
        ["run", "poof run"],
        ["enter", "poof enter"],
      ];
      for (const [mode, marker] of cases) {
        const result = spawnSync([POOF_BIN, mode, "--help"]);
        expect(result.stdout.toString()).toContain(marker);
        expect(result.stdout.toString()).toContain("OPTIONS");
        expect(result.exitCode).toBe(0);
      }
    });

    test("no arguments enters shell mode (exits cleanly with no changes)", () => {
      // poof with no args now defaults to enter mode
      const result = spawnSync([POOF_BIN]);
      const output = result.stderr.toString();
      expect(output).toContain("No changes made");
      expect(result.exitCode).toBe(0);
    });

    test("unknown option shows error", () => {
      const result = spawnSync([POOF_BIN, "--unknown"]);
      const output = result.stderr.toString();
      expect(output).toContain("unknown option");
      expect(result.exitCode).toBe(1);
    });

    test("missing command shows help on stderr", () => {
      const result = spawnSync([POOF_BIN, "exec"]);
      const output = result.stderr.toString();
      expect(output).toContain("poof exec");
      expect(output).toContain("USAGE");
      // A usage error is not the requested result: keep it off stdout.
      expect(result.stdout.toString()).toBe("");
      expect(result.exitCode).toBe(1);
    });
  });

  // ============================================================================
  // Exec Mode (Ephemeral)
  // ============================================================================
  describe("exec mode", () => {
    describe("basic execution", () => {
      test("runs command and exits with status 0", () => {
        const result = spawnSync([POOF_BIN, "exec", "true"]);
        expect(result.exitCode).toBe(0);
      });

      test("propagates non-zero exit code", () => {
        const result = spawnSync([POOF_BIN, "exec", "false"]);
        expect(result.exitCode).toBe(1);
      });

      test("propagates specific exit code (42)", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "exit 42"]);
        expect(result.exitCode).toBe(42);
      });

      test("propagates exit code 255", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "exit 255"]);
        expect(result.exitCode).toBe(255);
      });

      test("returns 127 for non-existent command", () => {
        const result = spawnSync([POOF_BIN, "exec", "nonexistent-command-xyz"]);
        expect(result.exitCode).toBe(127);
      });

      test("passes arguments to command", () => {
        const result = spawnSync([POOF_BIN, "exec", "echo", "hello", "world"]);
        expect(result.stdout.toString().trim()).toBe("hello world");
      });

      test("works with -- separator", () => {
        const result = spawnSync([POOF_BIN, "exec", "--", "echo", "-n", "test"]);
        expect(result.stdout.toString()).toBe("test");
      });
    });

    describe("filesystem isolation", () => {
      test("file created inside does not exist outside", () => {
        const testFile = join(TEST_DIR, "exec-create.txt");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `echo "created" > ${testFile} && cat ${testFile}`
        ]);
        expect(result.stdout.toString().trim()).toBe("created");
        expect(result.exitCode).toBe(0);
        expect(existsSync(testFile)).toBe(false);
      });

      test("can read existing files from host", () => {
        const testFile = join(TEST_DIR, "exec-read.txt");
        writeFileSync(testFile, "readable content");
        const result = spawnSync([POOF_BIN, "exec", "cat", testFile]);
        expect(result.stdout.toString().trim()).toBe("readable content");
      });

      test("modifications to existing files are isolated", () => {
        const testFile = join(TEST_DIR, "exec-modify.txt");
        writeFileSync(testFile, "original");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `echo "modified" > ${testFile} && cat ${testFile}`
        ]);
        expect(result.stdout.toString().trim()).toBe("modified");
        expect(readFileSync(testFile, "utf-8")).toBe("original");
      });

      test("file deletion is isolated", () => {
        const testFile = join(TEST_DIR, "exec-delete.txt");
        writeFileSync(testFile, "to be deleted");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `rm ${testFile} && test ! -f ${testFile} && echo "deleted"`
        ]);
        expect(result.stdout.toString().trim()).toBe("deleted");
        expect(existsSync(testFile)).toBe(true);
      });

      test("directory creation is isolated", () => {
        const testDir = join(TEST_DIR, "exec-newdir");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `mkdir -p ${testDir}/subdir && test -d ${testDir}/subdir && echo "created"`
        ]);
        expect(result.stdout.toString().trim()).toBe("created");
        expect(existsSync(testDir)).toBe(false);
      });

      test("symlink creation is isolated", () => {
        const target = join(TEST_DIR, "exec-symlink-target.txt");
        const link = join(TEST_DIR, "exec-symlink-link");
        writeFileSync(target, "target content");
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          `ln -s ${target} ${link} && cat ${link}`
        ]);
        expect(result.stdout.toString().trim()).toBe("target content");
        expect(existsSync(link)).toBe(false);
      });
    });

    describe("device nodes", () => {
      test("/dev/null is available", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo test > /dev/null && echo ok"]);
        expect(result.stdout.toString().trim()).toBe("ok");
        expect(result.exitCode).toBe(0);
      });

      test("/dev/zero is available", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "head -c 4 /dev/zero | xxd -p"]);
        expect(result.stdout.toString().trim()).toBe("00000000");
        expect(result.exitCode).toBe(0);
      });

      test("/dev/urandom is available", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "head -c 16 /dev/urandom | wc -c"]);
        expect(result.stdout.toString().trim()).toBe("16");
        expect(result.exitCode).toBe(0);
      });

      test("/dev/random is available", () => {
        const result = spawnSync([POOF_BIN, "exec", "test", "-c", "/dev/random"]);
        expect(result.exitCode).toBe(0);
      });

      test("disk devices are NOT available", () => {
        // /dev/sda, /dev/nvme*, etc should not be accessible
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "ls /dev/sd* /dev/nvme* 2>&1 || echo 'no disk devices'"]);
        expect(result.stdout.toString()).toContain("no disk devices");
      });

      test("/dev/mem is NOT available", () => {
        const result = spawnSync([POOF_BIN, "exec", "test", "-e", "/dev/mem"]);
        expect(result.exitCode).not.toBe(0);
      });
    });

    describe("environment", () => {
      test("sets IS_SANDBOX=1", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo $IS_SANDBOX"]);
        expect(result.stdout.toString().trim()).toBe("1");
      });

      test("preserves environment variables", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo $MY_VAR"], {
          env: { ...process.env, MY_VAR: "test-value" }
        });
        expect(result.stdout.toString().trim()).toBe("test-value");
      });

      test("preserves PATH", () => {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo $PATH"]);
        expect(result.stdout.toString().trim()).toContain("/bin");
      });

      test("preserves cwd (non-/tmp)", () => {
        const result = spawnSync([POOF_BIN, "exec", "pwd"], { cwd: "/var" });
        expect(result.stdout.toString().trim()).toBe("/var");
      });

      test("cwd works in TEST_DIR", () => {
        const result = spawnSync([POOF_BIN, "exec", "pwd"], { cwd: TEST_DIR });
        expect(result.stdout.toString().trim()).toBe(TEST_DIR);
      });
    });

    describe("namespace isolation", () => {
      test("PID namespace shows low PID", () => {
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          "cat /proc/self/status | grep -E '^Pid:'"
        ]);
        expect(result.stdout.toString()).toMatch(/Pid:\s+[1-5]/);
      });

      test("/proc shows only isolated processes", () => {
        const hostProcs = spawnSync(["ls", "/proc"]).stdout.toString()
          .split("\n").filter(p => /^\d+$/.test(p)).length;
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          "ls /proc | grep -E '^[0-9]+$' | wc -l"
        ]);
        const poofProcs = parseInt(result.stdout.toString().trim());
        expect(poofProcs).toBeLessThan(hostProcs);
        // The sandbox holds only its own tree: tiny init + fuse-overlayfs + the
        // command and the forks its pipeline needs. Far below the host's count.
        expect(poofProcs).toBeLessThanOrEqual(8);
      });

      test("/tmp is fresh (isolated from host)", () => {
        const hostMarker = `/tmp/host-marker-${Date.now()}`;
        writeFileSync(hostMarker, "host");
        try {
          const result = spawnSync([
            POOF_BIN, "exec", "sh", "-c",
            `test -f ${hostMarker} && echo "found" || echo "not found"`
          ]);
          expect(result.stdout.toString().trim()).toBe("not found");
        } finally {
          rmSync(hostMarker, { force: true });
        }
      });

      test("/tmp is writable inside poof", () => {
        const result = spawnSync([
          POOF_BIN, "exec", "sh", "-c",
          "echo test > /tmp/write-test && cat /tmp/write-test"
        ]);
        expect(result.stdout.toString().trim()).toBe("test");
      });
    });

    describe("options", () => {
      test("--timeout kills long-running process", () => {
        const start = Date.now();
        const result = spawnSync([POOF_BIN, "exec", "--timeout=1", "sleep", "60"]);
        const elapsed = Date.now() - start;
        expect(result.exitCode).toBe(124);
        expect(elapsed).toBeLessThan(5000);
      });

      test("--timeout allows fast commands", () => {
        const result = spawnSync([POOF_BIN, "exec", "--timeout=10", "echo", "fast"]);
        expect(result.stdout.toString().trim()).toBe("fast");
        expect(result.exitCode).toBe(0);
      });

      test("-v shows verbose output", () => {
        const result = spawnSync([POOF_BIN, "-v", "exec", "true"]);
        expect(result.stderr.toString()).toContain("uid=");
      });

      test("--verbose shows verbose output", () => {
        const result = spawnSync([POOF_BIN, "--verbose", "exec", "true"]);
        expect(result.stderr.toString()).toContain("uid=");
      });

      test("invalid --timeout shows error", () => {
        const result = spawnSync([POOF_BIN, "exec", "--timeout=abc", "true"]);
        expect(result.stderr.toString()).toContain("invalid timeout");
        expect(result.exitCode).toBe(1);
      });

      test("invalid --memory shows error", () => {
        const result = spawnSync([POOF_BIN, "exec", "--memory=invalid", "true"]);
        expect(result.stderr.toString()).toContain("invalid memory limit");
        expect(result.exitCode).toBe(1);
      });

      test("invalid --pids shows error", () => {
        const result = spawnSync([POOF_BIN, "exec", "--pids=abc", "true"]);
        expect(result.stderr.toString()).toContain("invalid pids limit");
        expect(result.exitCode).toBe(1);
      });

      test("zero limits are rejected instead of killing everything", () => {
        const cases: [string, string][] = [
          ["--timeout=0", "invalid timeout"],
          ["--memory=0", "invalid memory limit"],
          ["--pids=0", "invalid pids limit"],
        ];
        for (const [opt, marker] of cases) {
          const result = spawnSync([POOF_BIN, "exec", opt, "--", "true"]);
          expect(result.stderr.toString()).toContain(marker);
          expect(result.exitCode).toBe(1);
        }
      });
    });
  });

  // ============================================================================
  // Exit codes
  // ============================================================================
  describe("exit codes", () => {
    test("death by signal propagates as 128 + signum", () => {
      const cases: [string, number][] = [
        ["TERM", 143],
        ["INT", 130],
        ["KILL", 137],
        ["USR1", 138],
      ];
      for (const [sig, code] of cases) {
        const result = spawnSync([POOF_BIN, "exec", "sh", "-c", `kill -${sig} $$`]);
        expect(result.exitCode).toBe(code);
      }
    });

    test("exit code 0 for a command that succeeds after work", () => {
      const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo hi > /tmp/x && exit 0"]);
      expect(result.exitCode).toBe(0);
    });
  });

  // ============================================================================
  // Resource limits (cgroups v2)
  // ============================================================================
  describe("resource limits", () => {
    // Enforcing limits needs a place in the cgroup hierarchy where poof may create
    // a limited child cgroup. Some containers refuse that; poof then fails loudly,
    // and these enforcement tests are skipped rather than falsely failing.
    const limitsAvailable = (() => {
      const probe = spawnSync([POOF_BIN, "exec", "--memory=64M", "--", "true"]);
      return probe.exitCode === 0;
    })();

    test("limits are never silently ignored", () => {
      const result = spawnSync([POOF_BIN, "exec", "--memory=64M", "--", "true"]);
      if (result.exitCode !== 0) {
        // If limits cannot be applied, poof must say so instead of running unlimited.
        expect(result.stderr.toString()).toContain("cannot apply --memory/--pids");
      }
    });

    const maybeTest = limitsAvailable ? test : test.skip;

    maybeTest("--memory kills a process that exceeds the limit", () => {
      const result = spawnSync(
        [POOF_BIN, "exec", "--timeout=60", "--memory=100M", "--", "sh", "-c",
          'a=$(head -c 200000000 /dev/zero | tr "\\0" "x"); echo got ${#a}'],
        { timeout: 90_000 },
      );
      expect(result.exitCode).toBe(137);
    });

    maybeTest("--memory leaves a small allocation alone", () => {
      const result = spawnSync(
        [POOF_BIN, "exec", "--timeout=60", "--memory=100M", "--", "sh", "-c",
          'a=$(head -c 10000000 /dev/zero | tr "\\0" "x"); echo got ${#a}'],
        { timeout: 90_000 },
      );
      expect(result.stdout.toString()).toContain("got 10000000");
      expect(result.exitCode).toBe(0);
    });

    test("a --pids limit too small to boot the sandbox is rejected up front", () => {
      const result = spawnSync([POOF_BIN, "exec", "--pids=1", "--", "true"]);
      expect(result.stderr.toString()).toContain("needs at least 2 processes");
      expect(result.exitCode).toBe(1);
    });

    maybeTest("a --pids limit that starves the sandbox fails cleanly, not with a crash", () => {
      // 2 slots cannot hold the namespace init, the FUSE daemon and the command.
      const result = spawnSync([POOF_BIN, "exec", "--pids=2", "--", "true"], { timeout: 30_000 });
      const output = result.stderr.toString();
      expect(output).not.toContain("panic");
      expect(output).not.toContain("Segmentation");
      // 134 = SIGABRT (Zig panic), 139 = SIGSEGV: both mean an unhandled fork failure.
      expect(result.exitCode).not.toBe(134);
      expect(result.exitCode).not.toBe(139);
      expect(result.exitCode).not.toBe(0);
      expect(output).toContain("error");
    });

    maybeTest("--memory, --pids and --timeout combine", () => {
      const result = spawnSync(
        [POOF_BIN, "exec", "--memory=1G", "--pids=100", "--timeout=30", "--", "sh", "-c", "echo combined-ok"],
        { timeout: 60_000 },
      );
      expect(result.stdout.toString()).toContain("combined-ok");
      expect(result.exitCode).toBe(0);
    });

    maybeTest("--pids stops a fork bomb", () => {
      const result = spawnSync(
        [POOF_BIN, "exec", "--timeout=30", "--pids=10", "--", "sh", "-c",
          "i=0; while [ $i -lt 50 ]; do (sleep 5) & i=$((i+1)); done; echo started=$i"],
        { timeout: 60_000 },
      );
      // The bomb must be stopped short of spawning all 50 processes.
      expect(result.stdout.toString()).not.toContain("started=50");
      expect(result.exitCode).not.toBe(0);
    });
  });

  // ============================================================================
  // Run Mode (Persistent)
  // ============================================================================
  describe("run mode", () => {
    let runTestDir: string;

    beforeEach(() => {
      runTestDir = mkdtempSync(join(TEST_DIR, "run-"));
    });

    afterEach(() => {
      if (runTestDir && existsSync(runTestDir)) {
        rmSync(runTestDir, { recursive: true });
      }
      // Clean up the .work directory poof keeps beside the user's upper dir
      for (const suffix of [".work"]) {
        const path = runTestDir + suffix;
        if (existsSync(path)) {
          rmSync(path, { recursive: true });
        }
      }
    });

    describe("persistence", () => {
      test("saves new file to upper directory", () => {
        const upperDir = join(runTestDir, "upper");
        const testFile = join(runTestDir, "newfile.txt");

        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `echo "persisted" > ${testFile}`
        ]);
        expect(result.exitCode).toBe(0);

        // File in upper dir mirrors the path
        const persistedFile = join(upperDir, testFile);
        expect(existsSync(persistedFile)).toBe(true);
        expect(readFileSync(persistedFile, "utf-8").trim()).toBe("persisted");
      });

      test("saves modifications to upper directory", () => {
        const upperDir = join(runTestDir, "upper");
        const testFile = join(runTestDir, "existing.txt");
        writeFileSync(testFile, "original");

        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `echo "modified" > ${testFile}`
        ]);
        expect(result.exitCode).toBe(0);

        // Original unchanged
        expect(readFileSync(testFile, "utf-8")).toBe("original");
        // Modification in upper
        const modifiedFile = join(upperDir, testFile);
        expect(readFileSync(modifiedFile, "utf-8").trim()).toBe("modified");
      });

      test("saves directory creation to upper", () => {
        const upperDir = join(runTestDir, "upper");
        const newDir = join(runTestDir, "newdir", "subdir");

        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `mkdir -p ${newDir} && echo "test" > ${newDir}/file.txt`
        ]);
        expect(result.exitCode).toBe(0);

        const persistedDir = join(upperDir, newDir);
        expect(existsSync(persistedDir)).toBe(true);
        expect(readFileSync(join(persistedDir, "file.txt"), "utf-8").trim()).toBe("test");
      });

      test("multiple files are persisted", () => {
        const upperDir = join(runTestDir, "upper");

        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `echo "a" > ${runTestDir}/a.txt && echo "b" > ${runTestDir}/b.txt && echo "c" > ${runTestDir}/c.txt`
        ]);
        expect(result.exitCode).toBe(0);

        expect(readFileSync(join(upperDir, runTestDir, "a.txt"), "utf-8").trim()).toBe("a");
        expect(readFileSync(join(upperDir, runTestDir, "b.txt"), "utf-8").trim()).toBe("b");
        expect(readFileSync(join(upperDir, runTestDir, "c.txt"), "utf-8").trim()).toBe("c");
      });
    });

    describe("auto-generated upper (non-interactive)", () => {
      test("uses command name as directory", () => {
        const result = spawnSync([POOF_BIN, "run", "true"], { cwd: runTestDir });
        const output = result.stderr.toString();
        expect(output).toContain("Changes will persist to");
        expect(output).toContain("/true");
        expect(result.exitCode).toBe(0);

        // Cleanup
        rmSync(join(runTestDir, "true"), { recursive: true, force: true });
        rmSync(join(runTestDir, "true.work"), { recursive: true, force: true });

      });

      test("adds timestamp when directory exists", () => {
        // Create directory to force timestamp
        const existingDir = join(runTestDir, "echo");
        mkdirSync(existingDir);

        const result = spawnSync([POOF_BIN, "run", "echo", "hi"], { cwd: runTestDir });
        const output = result.stderr.toString();
        expect(output).toMatch(/echo\.\d{14}/);

        // Cleanup
        rmSync(existingDir, { recursive: true, force: true });
        // Find and clean the timestamped dir
        const dirs = spawnSync(["sh", "-c", `ls -d ${runTestDir}/echo.* 2>/dev/null || true`])
          .stdout.toString().trim().split("\n").filter(Boolean);
        for (const dir of dirs) {
          rmSync(dir, { recursive: true, force: true });
          rmSync(dir + ".work", { recursive: true, force: true });

        }
      });
    });

    describe("relative paths", () => {
      test("--upper with relative path works", () => {
        const result = spawnSync([
          POOF_BIN, "run", "--upper=my-changes", "sh", "-c",
          `echo "test" > ${runTestDir}/reltest.txt`
        ], { cwd: runTestDir });
        expect(result.exitCode).toBe(0);

        const upperDir = join(runTestDir, "my-changes");
        expect(existsSync(join(upperDir, runTestDir, "reltest.txt"))).toBe(true);

        // Cleanup
        rmSync(upperDir, { recursive: true, force: true });
        rmSync(upperDir + ".work", { recursive: true, force: true });
      });
    });

    describe("upper directory handling", () => {
      test("--upper pointing at a file fails with a clear error", () => {
        const notADir = join(runTestDir, "afile");
        writeFileSync(notADir, "x");

        const result = spawnSync([POOF_BIN, "run", `--upper=${notADir}`, "true"]);
        expect(result.stderr.toString()).toContain("not a directory");
        expect(result.exitCode).toBe(1);
      });

      test("--upper creates missing parent directories", () => {
        const upperDir = join(runTestDir, "deep", "nested", "upper");
        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `echo deep > ${runTestDir}/deepfile.txt`
        ]);
        expect(result.exitCode).toBe(0);
        expect(existsSync(join(upperDir, runTestDir, "deepfile.txt"))).toBe(true);
      });

      test("run mode leaves no merged mount point beside upper", () => {
        const upperDir = join(runTestDir, "cleanupper");
        const result = spawnSync([
          POOF_BIN, "run", `--upper=${upperDir}`, "sh", "-c",
          `echo x > ${runTestDir}/f.txt`
        ]);
        expect(result.exitCode).toBe(0);
        // The merged mount lives in a private tmpfs, so nothing is left beside
        // the user's upper dir except the changes themselves.
        expect(existsSync(upperDir + ".merged")).toBe(false);
        expect(existsSync(upperDir + ".work")).toBe(false);
      });
    });
  });

  // ============================================================================
  // Enter Mode (Interactive with PTY)
  // ============================================================================
  describe("enter mode", () => {
    let enterTestDir: string;

    beforeEach(() => {
      enterTestDir = mkdtempSync(join(TEST_DIR, "enter-"));
    });

    afterEach(async () => {
      // Kill any active session
      if (activeSession) {
        activeSession.kill();
        await activeSession.waitForExit();
        activeSession = null;
      }
      if (enterTestDir && existsSync(enterTestDir)) {
        rmSync(enterTestDir, { recursive: true });
      }
    });

    test("enters and exits cleanly", async () => {
      const session = new TerminalSession(enterTestDir);

      // Wait for first shell prompt
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitFor("No changes made");

      await session.waitForExit();

      expect(session.output).toContain("No changes made");
    });

    test("enter <directory> sandboxes that directory, not the cwd", async () => {
      const targetDir = mkdtempSync(join(TEST_DIR, "enter-target-"));
      const newFile = join(targetDir, "from-enter-arg.txt");

      // cwd is enterTestDir, but the session is asked to sandbox targetDir
      const session = new TerminalSession(enterTestDir, undefined, [targetDir]);

      await session.waitForNew(SHELL_PROMPT);

      // The shell must start inside the requested directory
      session.write("pwd\n");
      await session.waitForNew(targetDir);

      session.write(`echo entered > ${newFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("]: ");

      session.write("y\n");
      await session.waitFor("Changes applied");
      await session.waitForExit();

      expect(existsSync(newFile)).toBe(true);
      rmSync(targetDir, { recursive: true, force: true });
    });

    test("enter with a missing directory fails clearly", () => {
      const result = spawnSync([POOF_BIN, "enter", join(TEST_DIR, "no-such-dir")]);
      expect(result.stderr.toString()).toContain("not a directory");
      expect(result.exitCode).toBe(1);
    });

    test("creates file and shows in diff", async () => {
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "test content" > ${enterTestDir}/newfile.txt\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      session.write("n\n");
      await session.waitForExit();

      expect(session.output).toContain("newfile.txt");
      expect(existsSync(join(enterTestDir, "newfile.txt"))).toBe(false);
      cleanupStash(session.output);
    });

    test("applies changes when user confirms with y", async () => {
      const testFile = join(enterTestDir, "applied.txt");
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "applied content" > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("]: ");

      session.write("y\n");
      await session.waitFor("Changes applied");

      await session.waitForExit();

      expect(session.output).toContain("applied.txt");
      expect(existsSync(testFile)).toBe(true);
      expect(readFileSync(testFile, "utf-8").trim()).toBe("applied content");
    });

    test("discards changes when user declines", async () => {
      const testFile = join(enterTestDir, "discarded.txt");
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "should not exist" > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      session.write("n\n");
      await session.waitFor("Stashed changes in");

      await session.waitForExit();

      expect(existsSync(testFile)).toBe(false);
      // Discarded means "kept in a stash", not "gone": the change must be there.
      const stash = stashPath(session.output);
      expect(stash).not.toBeNull();
      expect(existsSync(join(stash!, testFile))).toBe(true);
      cleanupStash(session.output);
    });

    test("shows diff when user presses d", async () => {
      const testFile = join(enterTestDir, "difftest.txt");
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "diff line 1" > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "diff line 2" >> ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      session.write("d\n");
      await session.waitFor("diff line 1");
      await session.waitForNew("[y/N]");

      session.write("n\n");
      await session.waitForExit();

      expect(existsSync(testFile)).toBe(false);
      cleanupStash(session.output);
    });

    test("modifying existing file shows in diff", async () => {
      const testFile = join(enterTestDir, "modify-me.txt");
      writeFileSync(testFile, "original line\n");

      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo "modified line" > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      session.write("n\n");
      await session.waitFor("Stashed changes in");

      await session.waitForExit();

      expect(session.output).toContain("modify-me.txt");
      expect(readFileSync(testFile, "utf-8")).toBe("original line\n");
      cleanupStash(session.output);
    });

    test("no changes shows success message", async () => {
      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitFor("No changes made");

      await session.waitForExit();

      expect(session.output).toContain("No changes made");
    });

    test("deleted file shows in changed files list", async () => {
      const testFile = join(enterTestDir, "to-delete.txt");
      writeFileSync(testFile, "delete me\n");

      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`rm ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      // Should show the deleted file with - prefix (ANSI codes between - and filename)
      expect(session.output).toContain("to-delete.txt");
      expect(session.output).toContain("-\u001b[0m to-delete.txt");

      session.write("n\n");
      await session.waitForExit();

      // File should still exist on host (change was not applied)
      expect(existsSync(testFile)).toBe(true);
      cleanupStash(session.output);
    });

    test("new empty directory shows in changed files list", async () => {
      const testDir = join(enterTestDir, "new-empty-dir");

      const session = new TerminalSession(enterTestDir);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`mkdir ${testDir}\n`);
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitForNew("[y/N/d(iff)]");

      // Should show the new directory with + prefix and trailing / (ANSI codes between + and dirname)
      expect(session.output).toContain("new-empty-dir/");
      expect(session.output).toContain("+\u001b[0m new-empty-dir/");

      session.write("n\n");
      await session.waitForExit();

      // Directory should not exist on host
      expect(existsSync(testDir)).toBe(false);
      cleanupStash(session.output);
    });

    test("uses $SHELL environment variable", async () => {
      const session = new TerminalSession(enterTestDir, { SHELL: "/bin/bash" });

      await session.waitForNew(SHELL_PROMPT);

      session.write("echo $0\n");
      await session.waitForNew(SHELL_PROMPT);

      session.write("exit\n");
      await session.waitFor("No changes made");

      await session.waitForExit();

      expect(session.output).toContain("bash");
    });

    test("--timeout stashes changes instead of deleting them", async () => {
      const testFile = join(enterTestDir, "timeout-changes.txt");
      const session = new TerminalSession(enterTestDir, undefined, ["--timeout=5"]);

      await session.waitForNew(SHELL_PROMPT);

      session.write(`echo lost > ${testFile}\n`);
      await session.waitForNew(SHELL_PROMPT);

      // The timeout kills the shell: the changes must survive as a stash.
      const code = await session.waitForExit();
      expect(code).toBe(124);
      expect(session.output).toContain("Stashed changes in");
      expect(existsSync(testFile)).toBe(false);
      const stash = stashPath(session.output);
      expect(stash).not.toBeNull();
      expect(existsSync(join(stash!, testFile))).toBe(true);
      cleanupStash(session.output);
    }, 20_000);

    test("a relative directory argument is resolved against the cwd", async () => {
      const subDir = join(enterTestDir, "relative-target");
      mkdirSync(subDir);

      const session = new TerminalSession(enterTestDir, undefined, ["relative-target"]);

      await session.waitForNew(SHELL_PROMPT);

      session.write("pwd\n");
      await session.waitForNew(subDir);

      session.write("exit\n");
      await session.waitFor("No changes made");
      await session.waitForExit();
    });

    test("more than one directory argument is rejected", () => {
      const result = spawnSync([POOF_BIN, "enter", TEST_DIR, "/var"]);
      expect(result.stderr.toString()).toContain("at most one directory");
      expect(result.exitCode).toBe(1);
    });
  });

  // ============================================================================
  // Run Mode (Interactive) — the documented "review & apply" flow
  // ============================================================================
  describe("run mode (interactive)", () => {
    let runDir: string;

    beforeEach(() => {
      runDir = mkdtempSync(join(TEST_DIR, "runint-"));
    });

    afterEach(async () => {
      if (activeSession) {
        activeSession.kill();
        await activeSession.waitForExit();
        activeSession = null;
      }
      if (runDir && existsSync(runDir)) {
        rmSync(runDir, { recursive: true });
      }
    });

    test("shows the change summary and prompt after the command exits", async () => {
      const session = new TerminalSession(
        runDir, undefined, ["sh", "-c", `echo hi > ${runDir}/prompt-me.txt`], "run");

      await session.waitForNew("[y/N/d(iff)]");
      expect(session.output).toContain("1 changed file");
      expect(session.output).toContain("prompt-me.txt");

      session.write("n\n");
      await session.waitForExit();

      expect(existsSync(join(runDir, "prompt-me.txt"))).toBe(false);
      cleanupStash(session.output);
    });

    test("applies changes when the user confirms with y", async () => {
      const testFile = join(runDir, "run-applied.txt");
      const session = new TerminalSession(
        runDir, undefined, ["sh", "-c", `echo applied > ${testFile}`], "run");

      await session.waitForNew("[y/N/d(iff)]");
      session.write("y\n");
      await session.waitFor("Changes applied");
      await session.waitForExit();

      expect(existsSync(testFile)).toBe(true);
      expect(readFileSync(testFile, "utf-8").trim()).toBe("applied");
    });

    test("applying replays deletions instead of copying whiteouts", async () => {
      const doomed = join(runDir, "doomed.txt");
      const kept = join(runDir, "kept.txt");
      writeFileSync(doomed, "remove me\n");
      writeFileSync(kept, "keep me\n");

      const session = new TerminalSession(
        runDir, undefined, ["sh", "-c", `rm ${doomed}`], "run");

      await session.waitForNew("[y/N/d(iff)]");
      expect(session.output).toContain("doomed.txt");

      session.write("y\n");
      await session.waitFor("Changes applied");
      await session.waitForExit();

      // A deletion inside the sandbox is an overlay whiteout (a 0:0 character
      // device in the upper dir). It must become a real deletion in the target,
      // not a device node copied into it.
      expect(existsSync(doomed)).toBe(false);
      expect(readFileSync(kept, "utf-8").trim()).toBe("keep me");
    });

    test("applying preserves file modes", async () => {
      const script = join(runDir, "mode.sh");
      writeFileSync(script, "#!/bin/sh\necho hi\n");

      const session = new TerminalSession(
        runDir, undefined, ["sh", "-c", `chmod 750 ${script}`], "run");

      await session.waitForNew("[y/N/d(iff)]");
      session.write("y\n");
      await session.waitFor("Changes applied");
      await session.waitForExit();

      expect(statSync(script).mode & 0o777).toBe(0o750);
    });

    test("applying recreates symlinks as symlinks", async () => {
      const link = join(runDir, "link-to-nothing");

      const session = new TerminalSession(
        runDir, undefined, ["sh", "-c", `ln -s /does-not-exist ${link}`], "run");

      await session.waitForNew("[y/N/d(iff)]");
      session.write("y\n");
      await session.waitFor("Changes applied");
      await session.waitForExit();

      expect(lstatSync(link).isSymbolicLink()).toBe(true);
      expect(readlinkSync(link)).toBe("/does-not-exist");
    });

    test("applying creates missing subdirectories and replays edits", async () => {
      const nested = join(runDir, "sub/deep/nested.txt");
      const edited = join(runDir, "edited.txt");
      writeFileSync(edited, "v1\n");

      const session = new TerminalSession(
        runDir, undefined,
        ["sh", "-c", `mkdir -p ${join(runDir, "sub/deep")} && echo v2 > ${nested} && echo v2 > ${edited}`],
        "run");

      await session.waitForNew("[y/N/d(iff)]");
      session.write("y\n");
      await session.waitFor("Changes applied");
      await session.waitForExit();

      expect(readFileSync(nested, "utf-8").trim()).toBe("v2");
      expect(readFileSync(edited, "utf-8").trim()).toBe("v2");
    });

    test("applying creates a directory that is empty inside the sandbox", async () => {
      const session = new TerminalSession(
        runDir, undefined, ["sh", "-c", `mkdir -p ${join(runDir, "empty-dir")}`], "run");

      await session.waitForNew("[y/N/d(iff)]");
      expect(session.output).toContain("empty-dir/");

      session.write("y\n");
      await session.waitFor("Changes applied");
      await session.waitForExit();

      expect(statSync(join(runDir, "empty-dir")).isDirectory()).toBe(true);
    });

    test("the change summary ignores overlay bookkeeping markers", async () => {
      const session = new TerminalSession(
        runDir, undefined,
        ["sh", "-c", `mkdir -p ${join(runDir, "newdir/deeper")} && echo x > ${join(runDir, "newdir/deeper/f.txt")}`],
        "run");

      await session.waitForNew("[y/N/d(iff)]");
      // A directory created inside the sandbox carries .wh..wh..opq / .wh..opq
      // markers in the upper dir; they are not user changes.
      expect(session.output).not.toContain(".wh.");
      expect(session.output).toContain("1 changed file");

      session.write("n\n");
      await session.waitForExit();
      cleanupStash(session.output);
    });

    test("discards on n but keeps the stash", async () => {
      const testFile = join(runDir, "run-discarded.txt");
      const session = new TerminalSession(
        runDir, undefined, ["sh", "-c", `echo gone > ${testFile}`], "run");

      await session.waitForNew("[y/N/d(iff)]");
      session.write("n\n");
      await session.waitFor("Stashed changes in");
      await session.waitForExit();

      expect(existsSync(testFile)).toBe(false);
      const stash = stashPath(session.output);
      expect(stash).not.toBeNull();
      expect(existsSync(join(stash!, testFile))).toBe(true);
      // The overlay work dir is meaningless once the mount is gone: it must not
      // litter the stash.
      expect(existsSync(stash! + ".work")).toBe(false);
      rmSync(stash!, { recursive: true, force: true });
    });

    test("d shows the full diff, then y applies", async () => {
      const testFile = join(runDir, "run-diff.txt");
      const session = new TerminalSession(
        runDir, undefined, ["sh", "-c", `echo diff-marker-91 > ${testFile}`], "run");

      await session.waitForNew("[y/N/d(iff)]");
      session.write("d\n");
      await session.waitFor("diff-marker-91");
      await session.waitForNew("[y/N]");

      session.write("y\n");
      await session.waitFor("Changes applied");
      await session.waitForExit();

      expect(existsSync(testFile)).toBe(true);
    });

    test("--timeout stashes the changes made before the kill", async () => {
      const testFile = join(runDir, "run-timeout.txt");
      const session = new TerminalSession(
        runDir, undefined,
        ["--timeout=2", "sh", "-c", `echo late > ${testFile} && sleep 30`], "run");

      const code = await session.waitForExit();
      expect(code).toBe(124);
      expect(session.output).toContain("Stashed changes in");
      expect(existsSync(testFile)).toBe(false);
      const stash = stashPath(session.output);
      expect(stash).not.toBeNull();
      expect(existsSync(join(stash!, testFile))).toBe(true);
      cleanupStash(session.output);
    }, 20_000);
  });

  // ============================================================================
  // Stash lifecycle — poof stash list / poof apply
  // ============================================================================
  describe("stash apply", () => {
    let stashDir: string; // a fake upper dir: its tree mirrors absolute paths
    let targetDir: string; // what that stash applies onto

    beforeEach(() => {
      stashDir = mkdtempSync(join(TEST_DIR, "stash-"));
      targetDir = mkdtempSync(join(TEST_DIR, "apply-target-"));
    });

    afterEach(() => {
      rmSync(stashDir, { recursive: true, force: true });
      rmSync(targetDir, { recursive: true, force: true });
    });

    // Where an absolute path lives inside the upper dir.
    const mirror = (abs: string) => join(stashDir, abs);

    test("stash list says so when there is nothing to apply", () => {
      const r = spawnSync([POOF_BIN, "stash", "list"]);
      const out = r.stdout.toString() + r.stderr.toString();
      expect(r.exitCode).toBe(0);
      expect(out.includes("no stashes with changes") || /poof-[0-9a-f]{16}/.test(out)).toBe(true);
    });

    test("apply without a stash argument fails", () => {
      const r = spawnSync([POOF_BIN, "apply"]);
      expect(r.stderr.toString()).toContain("needs a stash directory");
      expect(r.exitCode).toBe(1);
    });

    test("apply rejects a directory that is not there", () => {
      const r = spawnSync([POOF_BIN, "apply", join(TEST_DIR, "not-a-stash")]);
      expect(r.stderr.toString()).toContain("not a stash directory");
      expect(r.exitCode).toBe(1);
    });

    test("apply refuses / as a stash", () => {
      const r = spawnSync([POOF_BIN, "apply", "/"]);
      expect(r.stderr.toString()).toContain("refusing to treat /");
      expect(r.exitCode).toBe(1);
    });

    test("a second positional argument is rejected", () => {
      const r = spawnSync([POOF_BIN, "apply", stashDir, targetDir]);
      expect(r.stderr.toString()).toContain("too many arguments");
      expect(r.exitCode).toBe(1);
    });

    test("apply shows the changes and refuses to write without a terminal", () => {
      mkdirSync(mirror(targetDir), { recursive: true });
      writeFileSync(join(mirror(targetDir), "never-written.txt"), "new\n");

      const r = spawnSync([POOF_BIN, "apply", stashDir]);
      expect(r.stderr.toString()).toContain("without a terminal");
      expect(r.exitCode).toBe(1);
      expect(existsSync(join(targetDir, "never-written.txt"))).toBe(false);
    });

    test("apply --yes replays adds, edits, deletions, modes and symlinks", () => {
      const mirrored = mirror(targetDir);
      mkdirSync(join(mirrored, "sub"), { recursive: true });
      writeFileSync(join(mirrored, "added.txt"), "added\n");
      writeFileSync(join(mirrored, "edited.txt"), "edited\n");
      writeFileSync(join(mirrored, ".wh.deleted.txt"), ""); // userspace whiteout
      writeFileSync(join(mirrored, "sub", "nested.txt"), "nested\n");
      symlinkSync("added.txt", join(mirrored, "link.txt"));
      chmodSync(join(mirrored, "added.txt"), 0o750);

      writeFileSync(join(targetDir, "edited.txt"), "original\n");
      writeFileSync(join(targetDir, "deleted.txt"), "still here\n");
      mkdirSync(join(targetDir, "sub"));

      const r = spawnSync([POOF_BIN, "apply", stashDir, "--yes"]);
      expect(r.exitCode).toBe(0);
      expect(r.stderr.toString()).toContain("Applied 5 change(s)");

      expect(readFileSync(join(targetDir, "added.txt"), "utf8")).toBe("added\n");
      expect(readFileSync(join(targetDir, "edited.txt"), "utf8")).toBe("edited\n");
      expect(readFileSync(join(targetDir, "sub", "nested.txt"), "utf8")).toBe("nested\n");
      expect(existsSync(join(targetDir, "deleted.txt"))).toBe(false);
      expect(readlinkSync(join(targetDir, "link.txt"))).toBe("added.txt");
      expect(statSync(join(targetDir, "added.txt")).mode & 0o777).toBe(0o750);
    });

    test("the preview names a deletion by its target path, not the .wh. marker", () => {
      const mirrored = mirror(targetDir);
      mkdirSync(mirrored, { recursive: true });
      writeFileSync(join(mirrored, ".wh.gone.txt"), "");
      writeFileSync(join(targetDir, "gone.txt"), "x\n");

      const out = spawnSync([POOF_BIN, "apply", stashDir]).stderr.toString();
      expect(out).toContain(`${targetDir.slice(1)}/gone.txt`);
      expect(out).not.toContain(".wh.");
    });

    test("an empty stash applies nothing", () => {
      const r = spawnSync([POOF_BIN, "apply", stashDir]);
      expect(r.stdout.toString() + r.stderr.toString()).toContain("no changes in");
      expect(r.exitCode).toBe(0);
    });

    test("poof run --apply=<stash> applies without starting a sandbox", () => {
      mkdirSync(mirror(targetDir), { recursive: true });
      writeFileSync(join(mirror(targetDir), "via-run.txt"), "via run\n");

      const r = spawnSync([POOF_BIN, "run", `--apply=${stashDir}`, "--yes"]);
      expect(r.exitCode).toBe(0);
      expect(readFileSync(join(targetDir, "via-run.txt"), "utf8")).toBe("via run\n");
    });

    test("apply --help goes to stdout", () => {
      const r = spawnSync([POOF_BIN, "apply", "--help"]);
      expect(r.exitCode).toBe(0);
      expect(r.stdout.toString()).toContain("poof apply");
      expect(r.stdout.toString()).toContain("--yes");
    });

    test("stash list finds a stash by its poof-<hex> name", () => {
      const named = join("/tmp", `poof-${"ab".repeat(8)}`);
      mkdirSync(join(named, targetDir.slice(1)), { recursive: true });
      writeFileSync(join(named, targetDir.slice(1), "listed.txt"), "x\n");
      try {
        const r = spawnSync([POOF_BIN, "stash", "list"]);
        expect(r.stdout.toString() + r.stderr.toString()).toContain(named);
      } finally {
        rmSync(named, { recursive: true, force: true });
      }
    });

    test("stash list ignores /tmp dirs that are not poof upper dirs", () => {
      const named = join("/tmp", "poof-not-a-stash");
      mkdirSync(join(named, "var"), { recursive: true });
      writeFileSync(join(named, "var", "junk.txt"), "x\n");
      try {
        const r = spawnSync([POOF_BIN, "stash", "list"]);
        expect(r.stdout.toString() + r.stderr.toString()).not.toContain("poof-not-a-stash");
      } finally {
        rmSync(named, { recursive: true, force: true });
      }
    });

    test("a deletion made in a real session is applied for real", async () => {
      const dir = mkdtempSync(join(TEST_DIR, "apply-e2e-"));
      const victim = join(dir, "victim.txt");
      writeFileSync(victim, "delete me\n");

      const session = new TerminalSession(dir, undefined, ["sh", "-c", `rm ${victim}`], "run");
      await session.waitForNew("[y/N/d(iff)]");
      session.write("n\n"); // decline in the session, apply it later via the stash
      await session.waitFor("Stashed changes in");
      await session.waitForExit();

      const stash = stashPath(session.output);
      expect(stash).not.toBeNull();
      expect(existsSync(victim)).toBe(true);

      const r = spawnSync([POOF_BIN, "apply", stash!, "--yes"]);
      expect(r.exitCode).toBe(0);
      expect(existsSync(victim)).toBe(false);

      cleanupStash(session.output);
      rmSync(dir, { recursive: true, force: true });
    }, 30_000);
  });

  // ============================================================================
  // I/O passthrough
  // ============================================================================
  describe("io passthrough", () => {
    test("stdin reaches the sandboxed command", () => {
      const f = join(TEST_DIR, "stdin-file.txt");
      writeFileSync(f, "piped-through");
      const result = spawnSync(["sh", "-c", `${POOF_BIN} exec cat < ${f}`]);
      expect(result.stdout.toString()).toBe("piped-through");
      expect(result.exitCode).toBe(0);
    });

    test("the command's stderr reaches the caller", () => {
      const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo to-stderr >&2"]);
      expect(result.stderr.toString()).toContain("to-stderr");
    });

    test("large stdout is not truncated", () => {
      const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "head -c 200000 /dev/urandom | wc -c"]);
      expect(result.stdout.toString().trim()).toBe("200000");
    });
  });

  // ============================================================================
  // Devices documented in the README
  // ============================================================================
  describe("device nodes (documented set)", () => {
    test("/dev/full rejects writes", () => {
      const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "echo x > /dev/full 2>/dev/null; echo rc=$?"]);
      expect(result.stdout.toString().trim()).toBe("rc=1");
    });

    test("/dev/tty is available", () => {
      expect(spawnSync([POOF_BIN, "exec", "test", "-c", "/dev/tty"]).exitCode).toBe(0);
    });

    test("/dev/ptmx is available (private devpts)", () => {
      const result = spawnSync([POOF_BIN, "exec", "sh", "-c", "test -c /dev/ptmx && echo ptmx-ok"]);
      expect(result.stdout.toString().trim()).toBe("ptmx-ok");
    });
  });

  // ============================================================================
  // UTS namespace
  // ============================================================================
  describe("uts namespace", () => {
    const hasHostname = spawnSync(["sh", "-c", "command -v hostname"]).exitCode === 0;
    const maybeTest = hasHostname ? test : test.skip;

    maybeTest("a hostname set inside the sandbox does not leak to the host", () => {
      const before = spawnSync(["uname", "-n"]).stdout.toString().trim();
      const inside = spawnSync([POOF_BIN, "exec", "sh", "-c", "hostname poof-uts-check && hostname"]);
      expect(inside.stdout.toString().trim()).toBe("poof-uts-check");
      expect(spawnSync(["uname", "-n"]).stdout.toString().trim()).toBe(before);
    });
  });

  // ============================================================================
  // Signals sent to poof itself
  // ============================================================================
  describe("signals to poof", () => {
    test("SIGTERM exits 143 after cleaning up the sandbox", async () => {
      const proc = spawn([POOF_BIN, "exec", "--", "sleep", "30"], { stdout: "ignore", stderr: "ignore" });
      await Bun.sleep(500);
      proc.kill(15);
      expect(await proc.exited).toBe(143);
    });

    test("SIGINT exits 130", async () => {
      const proc = spawn([POOF_BIN, "exec", "--", "sleep", "30"], { stdout: "ignore", stderr: "ignore" });
      await Bun.sleep(500);
      proc.kill(2);
      expect(await proc.exited).toBe(130);
    });
  });

  // ============================================================================
  // Color handling (NO_COLOR)
  // ============================================================================
  describe("color output", () => {
    test("colors are used when stderr is a terminal", async () => {
      const session = new TerminalSession(TEST_DIR, undefined, ["--unknown"], "exec");
      await session.waitForExit();
      expect(session.output).toContain("\u001b[");
    });

    test("NO_COLOR=1 disables colors even on a terminal", async () => {
      const session = new TerminalSession(TEST_DIR, { NO_COLOR: "1" }, ["--unknown"], "exec");
      await session.waitForExit();
      expect(session.output).toContain("unknown option");
      expect(session.output).not.toContain("\u001b[");
    });
  });

  // ============================================================================
  // Option interaction
  // ============================================================================
  describe("option interaction", () => {
    test("--upper warns when the mode ignores it", () => {
      for (const mode of ["exec", "enter"]) {
        const result = spawnSync([POOF_BIN, mode, "--upper=/var/tmp/poof-unused-upper", "--", "true"]);
        expect(result.stderr.toString()).toContain("only used by run mode");
      }
    });

    test("--upper= with an empty value is rejected", () => {
      const result = spawnSync([POOF_BIN, "run", "--upper=", "--", "true"]);
      expect(result.stderr.toString()).toContain("not a directory");
      expect(result.exitCode).toBe(1);
    });

    test("exec of a directory reports 126", () => {
      const result = spawnSync([POOF_BIN, "exec", "--", TEST_DIR]);
      expect(result.stderr.toString()).toContain("cannot execute");
      expect(result.exitCode).toBe(126);
    });
  });

  // ============================================================================
  // run mode with --upper: misc behavior
  // ============================================================================
  describe("run mode with --upper", () => {
    test("propagates the command exit code", () => {
      const upper = join(TEST_DIR, "runexit-upper");
      const result = spawnSync([POOF_BIN, "run", `--upper=${upper}`, "--", "sh", "-c", "exit 7"]);
      expect(result.exitCode).toBe(7);
    });

    test("sets IS_SANDBOX=1", () => {
      const upper = join(TEST_DIR, "runenv-upper");
      const result = spawnSync([POOF_BIN, "run", `--upper=${upper}`, "--", "sh", "-c", "echo $IS_SANDBOX"]);
      expect(result.stdout.toString().trim()).toBe("1");
    });

    test("a failing command still persists its changes", () => {
      const upper = join(TEST_DIR, "runfail-upper");
      const target = join(TEST_DIR, "runfail-target.txt");
      const result = spawnSync([
        POOF_BIN, "run", `--upper=${upper}`, "--", "sh", "-c",
        `echo kept > ${target} && exit 3`,
      ]);
      expect(result.exitCode).toBe(3);
      expect(readFileSync(join(upper, target), "utf-8").trim()).toBe("kept");
    });
  });
});
