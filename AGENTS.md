# AGENTS.md

Code style rules for this repository. Every edit, human or agent-made, must follow them.

## Rules

1. **Indent with 4 spaces per level. Tab characters (`\t`) are forbidden** anywhere in
   source files, including inside string literals (e.g. P4 sources embedded in tests).
2. **Braces follow K&R / 1TBS.** The opening `{` stays on the same line as the construct
   that introduces it: `fn`, `macro`, `if`, `else`, `while`, `for`, `foreach`, `switch`,
   `struct`, `enum`, `union`. Write `} else {` on one line. Never put an opening brace on
   its own line (Allman) — that is the C3 default convention and is deliberately not
   used here.
3. **Names follow C3 conventions:** types `PascalCase`; functions, parameters, and locals
   `snake_case`; enum values and constants `UPPER_SNAKE` (C3 constants keep the `~`
   suffix, e.g. `NOT_FOUND~`).

## Tooling

- Do **not** run `clang-format` on `.c3` files — clang-format does not support the C3
  language and will corrupt them.
- The approved formatter is [lmichaudel/c3fmt](https://github.com/lmichaudel/c3fmt)
  (v0.3.3, verified against this repo; supports K&R braces and 4-space indent).
  **Name collision:** alexveden/c3tools ships a *different* `c3fmt` that is hardcoded to
  Allman braces — never run that one; it would rewrite every brace away from K&R.
- The repo-root [`.c3fmt`](.c3fmt) pins the house style (K&R braces, 4-space indent, one
  trailing newline, no tabs, no `=`/comment alignment). Without it, or when formatting a
  file outside this repo, c3fmt defaults to tabs + Allman, violating rules 1–2. Install
  once (or when the binary is missing):

  ```bash
  curl -fsSL -o ~/.local/bin/c3fmt \
    https://github.com/lmichaudel/c3fmt/releases/download/v0.3.3/c3fmt-linux
  chmod +x ~/.local/bin/c3fmt
  ```

  Then, from the repo root:

  ```bash
  c3fmt --check src/*.c3 test/*.c3   # exit 1 if any file would change
  c3fmt -i src/*.c3 test/*.c3        # format in place (canonical)
  ```

  The tree is c3fmt-clean (`--check` passes); keep it that way by running `-i` on the
  files you touch rather than reformatting unrelated ones. Use `// c3fmt off` /
  `// c3fmt on` around blocks c3fmt must not touch. Known v0.3.3 quirks: `--stdout`
  and `--stdin` append an extra trailing blank line — use `-i`/`--check` for
  canonical output; a lone `//` comment gains a trailing space; blank padding before
  trailing comments is collapsed; lines over 120 columns and some ternaries are
  re-wrapped. The style rules above win over anything c3fmt would emit.
- Formatting is still enforced by review and by the checks below. Before committing,
  verify:

  ```bash
  c3fmt --check src/*.c3 test/*.c3
  grep -rP '\t' src test README.md && echo "FAIL: tabs found" || echo "ok"
  ```

## Verification

Build and test commands: see [README.md](README.md) (`c3c build`, `c3c test`).
