# p4c3

A work-in-progress **P4-to-C code generator** written in [C3](https://c3-lang.org), targeting DPDK. Its current implementation lexes and parses a small, usable subset of P4_16. The project aims to generate efficient C for custom packet formats, parsing, and packet construction, with future P4 extensions; a direct C3 backend is also under consideration. A lightweight frontend is the current preference, while reuse of the official p4c remains an option.

This is a parser only. There is no type checker, no full P4 toolchain, and no code generator yet.

See [the project motivation, goals, and intended deliverables](docs/project-vision.md).

Research notes: [existing C/uBPF and DPDK backends](docs/codegen-research.md),
[parser/deparser code generation challenges](docs/parser-deparser-challenges.md),
and [the p4c-DPDK → SWX spec boundary](docs/swx-spec-pipeline.md).
For implementation details, see [SWX interpreter internals and optional C codegen](docs/swx-parser-deparser-internals.md)
and the [reproducible helper experiments](research/swx-codegen/README.md).
The proposed static order analysis, runtime packet layout, and action-boundary
reconstruction are assessed in [the incremental header rebuild evaluation](docs/incremental-header-rebuild-evaluation.md),
including a comparison with SWX and an extension path for header reordering.

## What it parses

- Header types and structs (`header`, `struct`, `header_union`)
- Typedefs, constants, and simple enums
- Parser states with `extract`, `transition`, and `select`
- Controls with `apply`
- Actions and tables (`key`, `actions`, `size`, `default_action`)
- A practical expression and statement subset (`if`, assignment, calls, bit types)
- Builtin casts (`bit<W>`, `int<W>`, `bool`) and explicit method type arguments
  such as `packet.lookahead<ipv4_t>()` or `packet.lookahead<bit<16>>()`

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

## OVS extraction study

[`samples/ovs_miniflow.p4`](samples/ovs_miniflow.p4) models packet-field
extraction paths from OVS 2.17.2 `miniflow_extract`, including VLAN/MPLS,
IPv4/IPv6 and extension headers, transport headers, ARP, ND options, and NSH.
It is a parser component for evaluating whether P4 is a useful input for
readable C generation, not an executable OVS replacement.

```bash
./build/p4c3 samples/ovs_miniflow.p4
```

See [the comparison and limitations](docs/ovs-miniflow.md). The tests validate
syntax, AST preservation, wire layouts and state targets; they do not execute
packets or establish behavioral equivalence with OVS. No C backend exists yet.

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

## Direction

DPDK code generation is an explicit project goal, and DPDK is the only current target. Kernel, eBPF, and other targets are deferred for future consideration. C and C3 are output language choices for the DPDK target.

The first stage targets header format conversion, parser code generation, and deparser code generation for integration and validation in DPDK. The central challenge is to minimize packet copies and generate construction code with performance close to handwritten C. The packet build planning approach and implementation roadmap are still being defined.
