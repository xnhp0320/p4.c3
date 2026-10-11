module p4c3;
import std::io;
import std::io::file;
import std::collections::list;

fn void report_error(String path, ParseDiag* diag, fault err) {
    if (err == PARSE_FAILED) {
        String got = diag.has_tok ? (diag.error_tok.kind == END ? "end of file"
            : (diag.error_tok.text.len ? diag.error_tok.text : diag.error_tok.kind.label()))
            : "";
        io::eprintfn("%s:%d:%d: error: %s (got %s)", diag.filename, diag.line, diag.column, diag.msg, got);
    } else {
        io::eprintfn("error: cannot read %s: %s", path, err);
    }
}

fn uint? hex_digit(char c) {
    if (c >= '0' && c <= '9') return (uint)c - '0';
    if (c >= 'a' && c <= 'f') return 10 + (uint)c - 'a';
    if (c >= 'A' && c <= 'F') return 10 + (uint)c - 'A';
    return NOT_FOUND~;
}

fn char[]? parse_hex(Allocator alloc, String text) {
    List{char} bytes;
    bytes.init(alloc);
    uint hi = 0;
    bool have_hi = false;
    foreach (c : text) {
        if (c == ' ' || c == '\n' || c == '\t' || c == '\r') continue;
        uint? d = hex_digit(c);
        if (catch d) return NOT_FOUND~;
        if (have_hi) {
            bytes.push((char)((hi << 4) | d));
            have_hi = false;
        } else {
            hi = d;
            have_hi = true;
        }
    }
    if (have_hi) return NOT_FOUND~;
    return bytes.to_array(alloc);
}

fn String format_hex(Allocator alloc, char[] bytes) {
    char[] digits = "0123456789abcdef";
    List{char} out;
    out.init(alloc);
    foreach (b : bytes) {
        uint ub = (uint)(char)b;
        out.push(digits[ub >> 4]);
        out.push(digits[ub & 0xf]);
    }
    return (String)out.array_view();
}

fn int cmd_dump(String path) {
    int status = 0;
    @pool() {
        ParseDiag diag;
        Program*? program = parse_file(tmem, path, &diag);
        if (catch err = program) {
            report_error(path, &diag, err);
            status = 1;
        } else {
            dump_program(program);
            io::printfn(
                "ok: parsed %s (%d declaration%s)",
                path,
                program.decls.len(),
                program.decls.len() == 1 ? "" : "s"
            );
        }
    };
    return status;
}

// runref: the differential-testing oracle entry point (docs/v0-subset.md §4).
// Packet bytes in -> "reject" or the reference output bytes in hex.
fn int cmd_runref(String path, String packet_hex) {
    int status = 0;
    @pool() {
        ParseDiag diag;
        Program*? program = parse_file(tmem, path, &diag);
        if (catch err = program) {
            report_error(path, &diag, err);
            status = 1;
            return 1;
        }
        char[]? packet = parse_hex(tmem, packet_hex);
        if (catch packet) {
            io::eprintfn("error: packet must be an even number of hex digits");
            status = 1;
            return 1;
        }
        TypeIndex idx;
        idx.build(tmem, program);
        DiagList diags;
        diags.init(tmem);
        SubsetChecker checker;
        checker.idx = &idx;
        checker.diags = &diags;
        checker.emitted.init(tmem);
        checker.check_program(program);
        if (diags.has_errors()) {
            foreach (d : diags.items) {
                io::eprintfn("%s:%d:%d: error: %s", path, d.line, d.column, d.msg);
            }
            status = 2;
            return 2;
        }
        String err;
        RunOutcome outcome = run_reference(tmem, &idx, program, packet, path, &err);
        if (outcome.fatal) {
            io::eprintfn("error: %s", err);
            status = 3;
            return 3;
        }
        if (outcome.rejected) {
            io::printfn("reject");
        } else {
            io::printfn("%s", format_hex(tmem, outcome.output));
        }
    };
    return status;
}

fn int main(String[] args) {
    if (args.len >= 3 && args[1] == "runref") {
        return cmd_runref(args[2], args[3]);
    }
    if (args.len >= 2 && args[1] == "dump") {
        return cmd_dump(args[2]);
    }
    if (args.len >= 2 && args[1] != "dump" && args[1] != "runref") {
        // Bare file argument: keep the original dump behavior.
        return cmd_dump(args[1]);
    }
    io::eprintfn("usage:");
    io::eprintfn("  %s dump <file.p4>            parse and print the syntax tree", args[0]);
    io::eprintfn("  %s runref <file.p4> <hex>    run the v0 reference model on a packet", args[0]);
    return 1;
}
