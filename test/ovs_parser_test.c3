module p4c3;

fn Decl* ovs_test_decl(Program* program, String name) {
    foreach (decl : program.decls) {
        if (decl.name == name) return decl;
    }
    unreachable("Missing declaration: %s", name);
}

fn sz ovs_test_state(Decl* parser, String name) {
    foreach (i, state : parser.states) {
        if (state.name == name) return i;
    }
    unreachable("Missing parser state: %s", name);
}

fn void ovs_test_target(Decl* parser, String target) {
    if (target == "accept" || target == "reject") return;
    (void)ovs_test_state(parser, target);
}

fn int ovs_test_header_bits(Program* program, String name) {
    Decl* decl = ovs_test_decl(program, name);
    uint bits = 0;
    foreach (field : decl.fields) {
        test::eq(field.type.kind, TypeKind.BIT);
        bits += field.type.width;
    }
    return (int)bits;
}

// This is a structural fixture test, NOT execution or P4 type checking.
// Packet-level parity needs an executable backend and an OVS oracle.
fn void parses_ovs_model_with_closed_state_graph_and_wire_layouts() @test {
    @pool() {
        Program* program = parse_file(tmem, "samples/ovs_miniflow.p4", null)!!;
        Decl* parser = ovs_test_decl(program, "OvsMiniflow");
        test::eq(parser.kind, DeclKind.PARSER);
        test::eq((int)parser.params.len(), 5);
        test::eq(parser.states[0].name, "start");
        foreach (i, state : parser.states) {
            for (sz j = 0; j < i; j++) {
                assert(parser.states[j].name != state.name, "Duplicate state");
            }
            assert(state.transition.kind != TransitionKind.NONE);
            if (state.transition.kind == TransitionKind.NAME) {
                ovs_test_target(parser, state.transition.target);
            } else {
                foreach (c : state.transition.cases) ovs_test_target(parser, c.target);
            }
        }
        test::eq(ovs_test_header_bits(program, "ethernet_t"), 112);
        test::eq(ovs_test_header_bits(program, "vlan_t"), 32);
        test::eq(ovs_test_header_bits(program, "snap_t"), 64);
        test::eq(ovs_test_header_bits(program, "ipv4_t"), 160);
        test::eq(ovs_test_header_bits(program, "ipv6_t"), 320);
        test::eq(ovs_test_header_bits(program, "ipv6_frag_t"), 64);
        test::eq(ovs_test_header_bits(program, "tcp_t"), 160);
        test::eq(ovs_test_header_bits(program, "udp_t"), 64);
        test::eq(ovs_test_header_bits(program, "sctp_t"), 96);
        test::eq(ovs_test_header_bits(program, "icmp_t"), 64);
        test::eq(ovs_test_header_bits(program, "arp_t"), 224);
        test::eq(ovs_test_header_bits(program, "nsh_t"), 64);
        test::eq(ovs_test_header_bits(program, "nsh_context_t"), 128);
        // These backedges must survive; finite unrolling changes the contract.
        test::eq(parser.states[ovs_test_state(parser, "vlan")].transition.target, "vlan_check");
        test::eq(parser.states[ovs_test_state(parser, "ipv6_ext")].transition.target, "ipv6_dispatch");
        test::eq(parser.states[ovs_test_state(parser, "nd_advance")].transition.target, "nd_option_check");
        ParserState mpls = parser.states[ovs_test_state(parser, "mpls")];
        test::eq(mpls.transition.cases[0].target, "mpls_check");
    };
}
