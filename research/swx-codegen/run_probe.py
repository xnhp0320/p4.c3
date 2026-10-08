#!/usr/bin/env python3
"""Run selected upstream SWX helpers with a small, independent packet fixture.

This does not build DPDK or invoke rte_swx_pipeline_codegen. Pass the original
rte_swx_pipeline_internal.h from the revision documented in README.md.
"""

import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile


FUNCTIONS = (
    "emit_handler",
    "__instr_hdr_extract_many_exec",
    "__instr_hdr_extract_m_exec",
    "__instr_hdr_lookahead_exec",
    "__instr_hdr_emit_many_exec",
    "__instr_hdr_validate_exec",
    "__instr_hdr_invalidate_exec",
)
EXPECTED_SHA256 = "09f99c1378e2fec31a2715d162e601a6797352938e55cfd608209d68b44c8f6d"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--cc", default="clang")
    args = parser.parse_args()
    original = args.source.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    if digest != EXPECTED_SHA256:
        raise SystemExit(f"Source revision mismatch: {digest}; expected {EXPECTED_SHA256}")
    source = original.decode()
    helpers = []
    for name in FUNCTIONS:
        pattern = rf"^static inline [^\n]+\n{re.escape(name)}\(.*?^\}}"
        matches = re.findall(pattern, source, re.MULTILINE | re.DOTALL)
        if len(matches) != 1:
            raise SystemExit(f"Expected one definition of {name}, got {len(matches)}")
        helpers.append(matches[0])
    metadata_read = source.split("#define METADATA_READ", 1)[1].split(
        "#define METADATA_WRITE", 1
    )[0]
    helpers.insert(0, "#define METADATA_READ" + metadata_read)
    print(f"Upstream header SHA256: {digest}", flush=True)
    print("Mode: extracted helpers; reduced fixture types; ASan + UBSan; no benchmark", flush=True)
    with tempfile.TemporaryDirectory(prefix="p4c3-swx-probe-") as temporary:
        directory = Path(temporary)
        (directory / "swx_helpers.inc").write_text("\n\n".join(helpers) + "\n")
        executable = directory / "probe"
        subprocess.run(
            [args.cc, "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
             "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
             "-I", str(directory), str(Path(__file__).with_name("probe.c")),
             "-o", str(executable)], check=True,
        )
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
