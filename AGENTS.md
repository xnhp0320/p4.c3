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
- Do **not** run `c3fmt` (from alexveden/c3tools) — it is hardcoded to C3's default
  Allman brace style and would rewrite every brace away from K&R.
- There is no approved automatic formatter; formatting is enforced by review and by the
  tab check below. Before committing, verify:

  ```bash
  grep -rP '\t' src test README.md && echo "FAIL: tabs found" || echo "ok"
  ```

## Verification

Build and test commands: see [README.md](README.md) (`c3c build`, `c3c test`).
