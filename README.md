# p4c3

A **P4_16 parser** written in [C3](https://c3-lang.org). It lexes and parses a small, usable subset of P4_16 — the first slice of a P4-like DSL compiler that will later grow custom keywords and a readable C backend for DPDK.

This is a parser only. There is no type checker, no full P4 toolchain, and no code generator yet.

## What it parses

- Header types and structs (`header`, `struct`, `header_union`)
- Typedefs, constants, and simple enums
- Parser states with `extract`, `transition`, and `select`
- Controls with `apply`
- Actions and tables (`key`, `actions`, `size`, `default_action`)
- A practical expression and statement subset (`if`, assignment, calls, bit types)

`#include` lines and `@annotations` are skipped. `extern`, `error`, `match_kind`, and `package` blocks are ignored so common preamble can appear without failing the parse.

## Requirements

- [C3 compiler](https://c3-lang.org/getting-started/prebuilt-binaries/) 0.8.x (`c3c`)
- A C toolchain for linking (GCC or Clang)

Install a Linux static build:

```bash
curl -fsSL -o /tmp/c3-linux-static.tar.gz \
  https://github.com/c3lang/c3c/releases/latest/download/c3-linux-static.tar.gz
mkdir -p ~/.local/opt
tar -xzf /tmp/c3-linux-static.tar.gz -C ~/.local/opt
export PATH="$HOME/.local/opt/c3:$PATH"
```

## Build and run

```bash
c3c build
./build/p4c3 samples/simple.p4
```

`c3c run p4c3 -- samples/simple.p4` builds if needed and runs the same command.

On success the tool prints a syntax tree, then a one-line summary:

```text
ok: parsed samples/simple.p4 (7 declarations)
```

A syntax error is reported as `file:line:column: error: ...` and the process exits with status 1.

## Tests

```bash
c3c test
```

## Code style

C3 here uses **K&R braces**: the opening `{` stays on the same line as `fn`, `if`, `else`, `while`, `for`, `foreach`, `switch`, `struct`, and `enum`. Do not put the brace on its own line.

```c3
fn int example(int x) {
	if (x > 0) {
		return x;
	} else {
		return 0;
	}
}

struct Point {
	int x;
	int y;
}
```

Indent with tabs. Names follow C3 rules: types `PascalCase`, functions and locals `snake_case`.

## Layout

Official C3 project layout (`c3c init`):

| Path | Role |
| --- | --- |
| `project.json` | Build config and `p4c3` executable target |
| `src/` | Lexer, AST, parser, dump, CLI |
| `samples/simple.p4` | Sample the parser can actually parse |
| `test/` | Unit tests for the subset |

## Later

- Extra keywords for the p4-like DSL
- A C backend that emits readable C for DPDK
