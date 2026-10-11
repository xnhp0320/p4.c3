# p4c3

A work-in-progress **P4-to-C code generator** written in [C3](https://c3-lang.org), targeting DPDK. Its current implementation lexes and parses a small, usable subset of P4_16. The project aims to generate efficient C for custom packet formats, parsing, and packet construction, with future P4 extensions; a direct C3 backend is also under consideration. A lightweight frontend is the current preference, while reuse of the official p4c remains an option.

This is a parser plus a v0 reference interpreter. There is no type checker beyond
the v0 subset validation, no full P4 toolchain, and no code generator yet.

See [the project motivation, goals, and intended deliverables](docs/project-vision.md).
The agreed v0 language subset, the `extract_end` extension, and the first-phase
implementation order are drafted in [docs/v0-subset.md](docs/v0-subset.md).

Research notes: [existing C/uBPF and DPDK backends](docs/codegen-research.md),
[parser/deparser code generation challenges](docs/parser-deparser-challenges.md),
and [the p4c-DPDK → SWX spec boundary](docs/swx-spec-pipeline.md).
For implementation details, see [SWX interpreter internals and optional C codegen](docs/swx-parser-deparser-internals.md)
and the [reproducible helper experiments](research/swx-codegen/README.md).
The proposed static order analysis, runtime packet layout, and action-boundary
reconstruction are assessed in [the incremental header rebuild evaluation](docs/incremental-header-rebuild-evaluation.md),
including a comparison with SWX and an extension path for header reordering.

## V0 target

The v0 milestone is a self-contained C3 frontend for a deliberately *designed* P4_16
subset — programs outside the subset are rejected with explicit diagnostics, never
silently miscompiled. The full definition and rationale are in
[docs/v0-subset.md](docs/v0-subset.md); in short:

- **Types:** byte-aligned fixed-width headers (`bit<W>`), bounded header stacks, and
  varbit headers.
- **Parser:** states and transitions compile to label/goto; loop edges are allowed and
  every extract keeps a bounds check (short packets take the reject path).
- **Deparser:** a straight-line sequence of guarded emits. Output selection is
  `valid ∧ guard` with declaration order fixed; the packet is physically rebuilt only
  here (single-commit model): fixed payload, move only the affected prefix, with a
  gather-to-scratch fallback.
- **Target:** DPDK direct-mbuf fast path with a defined entry predicate and explicit
  fallback paths.
- **Extension:** `extract_end` preserves byte regions across loop parse paths.

Delivery order: (1) reference interpreter + differential-testing oracle — implemented,
see `p4c3 runref` below; (2) minimal semantic analysis; (3) layout planner, diffed
byte-for-byte against the oracle; (4) measurement against handwritten C.

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

### v0 reference model

`docs/v0-subset.md` §5 step 1 is implemented: a slow but obviously correct
interpreter (the differential-testing oracle) plus the v0 subset validator.

```bash
./build/p4c3 runref <file.p4> <packet-hex>
```

The program must contain a parser and a deparser (a control with a `packet_out`
parameter) and stay inside the v0 subset; violations are reported as
`file:line:column: error: ...` with exit status 2. On success the tool prints
`reject` (short packet or explicit reject) or the reference output bytes as
hex. See `test/refmodel_test.c3` for executable examples of the pinned
semantic points.

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

C3 here uses **K&R braces**: the opening `{` stays on the same line as `fn`, `if`,
`else`, `while`, `for`, `foreach`, `switch`, `struct`, and `enum`. Do not put the brace
on its own line.

Indent with **4 spaces — tabs are never used**, not even inside string literals. Names
follow C3 rules: types `PascalCase`, functions and locals `snake_case`. The full rules,
including formatter guidance, live in [AGENTS.md](AGENTS.md): clang-format does not
support C3, and `c3fmt` enforces the C3-default brace style we deliberately avoid, so
formatting is maintained by convention rather than by an automatic formatter.

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

## Layout

Official C3 project layout (`c3c init`):

| Path | Role |
| --- | --- |
| `project.json` | Build config and `p4c3` executable target |
| `src/` | Lexer, AST, parser, dump, v0 subset validator + reference interpreter, CLI |
| `samples/simple.p4` | Sample the parser can actually parse |
| `test/` | Unit tests for the subset |

## Direction

DPDK code generation is an explicit project goal, and DPDK is the only current target. Kernel, eBPF, and other targets are deferred for future consideration. C and C3 are output language choices for the DPDK target.

The first stage targets header format conversion, parser code generation, and deparser code generation for integration and validation in DPDK. The central challenge is to minimize packet copies and generate construction code with performance close to handwritten C. The packet build planning approach and implementation roadmap are still being defined.
