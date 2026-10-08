module p4c3;
import std::io;

fn void report_error(String path, ParseDiag* diag, fault err) {
	if (err == PARSE_FAILED) {
		String got = diag.has_tok
			? (diag.error_tok.kind == END ? "end of file"
				: (diag.error_tok.text.len ? diag.error_tok.text : diag.error_tok.kind.label()))
			: "";
		io::eprintfn("%s:%d:%d: error: %s (got %s)", diag.filename, diag.line, diag.column, diag.msg, got);
	} else {
		io::eprintfn("error: cannot read %s: %s", path, err);
	}
}

fn int main(String[] args) {
	if (args.len < 2) {
		io::eprintfn("usage: %s <file.p4>", args[0]);
		io::eprintfn("Parse a simple P4_16 program and print its syntax tree.");
		return 1;
	}
	String path = args[1];
	int status = 0;
	@pool() {
		ParseDiag diag;
		Program*? program = parse_file(tmem, path, &diag);
		if (catch err = program) {
			report_error(path, &diag, err);
			status = 1;
		} else {
			dump_program(program);
			io::printfn("ok: parsed %s (%d declaration%s)", path, program.decls.len(),
				program.decls.len() == 1 ? "" : "s");
		}
	};
	return status;
}
