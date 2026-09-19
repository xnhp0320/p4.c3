module p4c3;
import std::io;

fn int main(String[] args)
{
	if (args.len < 2)
	{
		io::eprintfn("usage: %s <file.p4>", args[0]);
		io::eprintfn("Parse a simple P4_16 program and print its syntax tree.");
		return 1;
	}
	String path = args[1];
	int status = 0;
	@pool()
	{
		Program*? program = parse_file(tmem, path);
		if (catch err = program)
		{
			status = 1;
		}
		else
		{
			dump_program(program);
			io::printfn("ok: parsed %s (%d declaration%s)", path, program.decls.len(),
				program.decls.len() == 1 ? "" : "s");
		}
	};
	return status;
}
