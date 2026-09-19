module p4c3;
import std::io;

fn Program*? parse_ok(String source)
{
	return parse_source(tmem, "test.p4", source);
}

fn void parses_headers_and_structs() @test
{
	@pool()
	{
		Program* program = parse_ok(`
			header ethernet_t {
				bit<48> dst_addr;
				bit<48> src_addr;
				bit<16> ether_type;
			}
			struct headers_t {
				ethernet_t ethernet;
			}
		`)!!;
		test::eq((int)program.decls.len(), 2);
		test::eq(program.decls[0].kind, DeclKind.HEADER);
		test::eq(program.decls[0].name, "ethernet_t");
		test::eq((int)program.decls[0].fields.len(), 3);
		test::eq(program.decls[0].fields[0].name, "dst_addr");
		test::eq((int)program.decls[0].fields[0].type.width, 48);
		test::eq(program.decls[1].kind, DeclKind.STRUCT);
		test::eq(program.decls[1].name, "headers_t");
	};
}

fn void parses_parser_states() @test
{
	@pool()
	{
		Program* program = parse_ok(`
			parser P(packet_in packet, out headers_t hdr) {
				state start {
					packet.extract(hdr.ethernet);
					transition select(hdr.ethernet.ether_type) {
						0x0800: accept;
						default: reject;
					}
				}
			}
		`)!!;
		test::eq((int)program.decls.len(), 1);
		test::eq(program.decls[0].kind, DeclKind.PARSER);
		test::eq((int)program.decls[0].states.len(), 1);
		test::eq(program.decls[0].states[0].name, "start");
		test::eq(program.decls[0].states[0].transition.kind, TransitionKind.SELECT);
		test::eq((int)program.decls[0].states[0].transition.cases.len(), 2);
		test::eq(program.decls[0].states[0].transition.cases[1].is_default, true);
	};
}

fn void parses_control_actions_tables() @test
{
	@pool()
	{
		Program* program = parse_ok(`
			control Ingress(inout headers_t hdr, inout metadata_t meta) {
				action drop() {
					meta.drop = 1;
				}
				action fwd(bit<9> port) {
					meta.egress_port = port;
				}
				table dmac {
					key = {
						hdr.ethernet.dst_addr: exact;
					}
					actions = {
						fwd;
						drop;
					}
					size = 1024;
					default_action = drop();
				}
				apply {
					dmac.apply();
				}
			}
		`)!!;
		test::eq((int)program.decls.len(), 1);
		Decl* c = program.decls[0];
		test::eq(c.kind, DeclKind.CONTROL);
		test::eq((int)c.actions.len(), 2);
		test::eq((int)c.actions[1].params.len(), 1);
		test::eq((int)c.tables.len(), 1);
		test::eq(c.tables[0].name, "dmac");
		test::eq((int)c.tables[0].keys.len(), 1);
		test::eq((int)c.tables[0].actions.len(), 2);
		test::eq(c.tables[0].has_default, true);
		test::eq((int)c.apply.len(), 1);
	};
}

fn void rejects_garbage() @test
{
	@pool()
	{
		test::@error(parse_ok("this is not p4;"), PARSE_FAILED);
	};
}
