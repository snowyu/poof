# zglob (vendored)

Vendored from <https://github.com/pierrejoye/zig-glob> at commit
`b4cf33856b77146312cf54343d22b9e7577f6dc6` (BSD 3-Clause, see `LICENSE`).

poof uses it for the glob patterns a report may contain, i.e.
`zglob.globMatch(pattern, path)` in `src/report.zig`. It is vendored rather than
declared in `build.zig.zon` because upstream is written against an older Zig and
needs the changes below to build at all; a dependency entry would pin a tree that
does not compile, and the fix lives here where it can be seen.

Only the matcher is kept: `src/root.zig` was reduced to re-export `match.zig`,
and upstream's `glob.zig`, `fs.zig`, `fs/` (file finding) and `main.zig` were
dropped - poof walks the stash itself. Upstream's `tests/` are dropped too; they
are written against the same older Zig.

## Local changes to `src/match.zig`

Zig 0.17 removed the managed `std.ArrayList(T)` (it is now the former
`ArrayListUnmanaged`, whose methods take an allocator), so:

- `CaptureList` wraps the capture list with its allocator, keeping the single
  pointer the matcher's helpers pass around; `?*std.ArrayList(Capture)` became
  `?*CaptureList`, `x.items` became `x.list.items`, and `append`/`resize`/
  `deinit` go through the wrapper.
- `globMatchWithCaptures` and `MatchGlob.matchWithCaptures` return an owned
  `[]Capture` slice instead of a managed list.
- `splitByAlternation` returns a stack `Alternatives` (up to 128 alternatives)
  instead of a list allocated from `std.heap.page_allocator`, which matching had
  no way to free; the five `defer alternatives.deinit()` calls went with it.

Two older-Zig syntax fixes:

- `BraceStack.init`: `[_]State{State.init()} ** 10` replaced with `@memset`,
  because `[_]T{expr} ** n` no longer parses.
- `src/root.zig` rewritten as the matcher-only re-export described above.

Nothing else was touched: the matching itself is upstream's, including `{a,b}`,
`[a-z]`, `**/` and the `*(a|b)` style extglobs.
