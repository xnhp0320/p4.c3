module p4c3;
import std::io;
import std::collections::list;

fn Program*? parse_ok(String source) {
	return parse_source(tmem, "test.p4", source, null);
}

fn void parses_headers_and_structs() @test {
	@pool() {
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

fn void parses_parser_states() @test {
	@pool() {
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

fn void parses_control_actions_tables() @test {
	@pool() {
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

fn void rejects_garbage() @test {
	@pool() {
		test::@error(parse_ok("this is not p4;"), PARSE_FAILED);
	};
}

fn void preserves_lookahead_types_and_cast_precedence() @test {
	@pool() {
		Program* program = parse_ok(`
			parser P(packet_in packet, out metadata_t m) {
				state start {
					m.word = packet.lookahead<bit<16>>();
					m.header = packet.lookahead<ipv4_t>();
					m.length = (bit<32>)m.word * 4;
					m.shifted = m.word >> 2;
					transition accept;
				}
			}
		`)!!;
		List{Stmt*} body = program.decls[0].states[0].body;
		Expr* call = body[0].rhs;
		test::eq(call.kind, ExprKind.CALL);
		test::eq((int)call.type_args.len(), 1);
		test::eq(call.type_args[0].kind, TypeKind.BIT);
		test::eq((int)call.type_args[0].width, 16);
		test::eq(body[1].rhs.type_args[0].name, "ipv4_t");
		Expr* product = body[2].rhs;
		test::eq(product.kind, ExprKind.BINARY);
		test::eq(product.token.kind, TokenKind.STAR);
		test::eq(product.kids[0].kind, ExprKind.CAST);
		test::eq((int)product.kids[0].type.width, 32);
		test::eq(body[3].rhs.token.kind, TokenKind.RSHIFT);
	};
}

fn void rejects_incomplete_typed_calls_and_casts() @test {
	@pool() {
		test::@error(parse_ok(`control C() {
			apply { x = packet.lookahead<bit<16>(); }
		}`), PARSE_FAILED);
		test::@error(parse_ok(`control C() {
			apply { x = (bit<32>); }
		}`), PARSE_FAILED);
	};
}
