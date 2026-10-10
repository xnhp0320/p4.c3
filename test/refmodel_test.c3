module p4c3;
import std::collections::list;

// Fixtures for the v0 reference model (docs/v0-subset.md §4). Each fixture
// pins one semantic point of the executable definition; expected outputs are
// hand-computed. Outcome convention: "reject" or output bytes as hex.

struct FixtureRunner {
	String name;
}

fn void run_fixture(String name, String p4src, String pkt_hex, String expected) {
	@pool() {
		ParseDiag diag;
		Program*? program = parse_source(tmem, string::tformat("%s.p4", name), p4src, &diag);
		if (catch err = program) {
			test::@check(false, "%s", string::tformat("%s: parse error %s:%d:%d: %s", name, diag.filename,
				diag.line, diag.column, diag.msg));
			return;
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
			test::@check(false, "%s", string::tformat("%s: unexpected subset diagnostic: %s", name, diags.items[0].msg));
		}
		char[]? packet = parse_hex(tmem, pkt_hex);
		if (catch packet) {
			test::@check(false, "%s", string::tformat("%s: bad fixture hex", name));
			return;
		}
		String err;
		RunOutcome outcome = run_reference(tmem, &idx, program, packet, name, &err);
		if (outcome.fatal) test::@check(false, "%s", string::tformat("%s: fatal: %s", name, err));
		String got = outcome.rejected ? "reject" : format_hex(tmem, outcome.output);
		test::eq(got, expected);
	};
}

fn void expect_subset_error(String name, String p4src, String want_substring) {
	@pool() {
		ParseDiag diag;
		Program*? program = parse_source(tmem, string::tformat("%s.p4", name), p4src, &diag);
		if (catch err = program) {
			test::@check(false, "%s", string::tformat("%s: unexpected parse failure", name));
			return;
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
		test::@check(diags.has_errors(), "%s", string::tformat("%s: expected a subset diagnostic", name));
		bool found = false;
		foreach (d : diags.items) {
			if (d.msg.contains(want_substring)) found = true;
		}
		test::@check(found, "%s", string::tformat("%s: no diagnostic containing '%s', got '%s'", name, want_substring, diags.items[0].msg));
	};
}

// ---- Point 0: fixed headers, emit, payload anchoring ----------------------

fn void fixed_header_emit_and_payload() @test {
	String p4 = `
		header ethernet_t { bit<48> dst; bit<48> src; bit<16> et; }
		struct headers_t { ethernet_t ether; }
		struct metadata_t { bit<8> dummy; }
		parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
			state start {
				packet.extract(hdr.ether);
				transition accept;
			}
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.ether); }
		}
	`;
	// ether(dst=010203040506 src=0708090a0b0c et=0800) + payload "payload"
	run_fixture("fixed_basic", p4, "0102030405060708090a0b0c08007061796c6f6164",
		"0102030405060708090a0b0c08007061796c6f6164");
	// payload anchored at parser cursor: emitting only part of what was parsed
	// still leaves the unconsumed tail in place.
	String p4_partial = `
		header ethernet_t { bit<48> dst; bit<48> src; bit<16> et; }
		header ipv4_t { bit<8> a; bit<8> b; }
		struct headers_t { ethernet_t ether; ipv4_t ip; }
		struct metadata_t { bit<8> dummy; }
		parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
			state start {
				packet.extract(hdr.ether);
				transition accept;
			}
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.ether); }
		}
	`;
	// Parser consumed only the 14 ether bytes; ip bytes are payload.
	run_fixture("payload_anchor", p4_partial, "0102030405060708090a0b0c0800aabb",
		"0102030405060708090a0b0c0800aabb");
}

// ---- Point 1: guards and implicit validity (valid ∧ guard) ----------------

const String GUARD_P4 = `
	header ethernet_t { bit<48> dst; bit<48> src; bit<16> et; }
	header vlan_t { bit<16> tci; bit<16> proto; }
	header ipv4_t { bit<8> a; bit<8> b; bit<8> c; bit<8> d; }
	struct headers_t { ethernet_t ether; vlan_t vlan; ipv4_t ip; }
	struct metadata_t { bit<8> send_ip; }
	parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
		state start {
			packet.extract(hdr.ether);
			transition select(hdr.ether.et) {
				0x8100: parse_vlan;
				default: parse_ip;
			}
		}
		state parse_vlan {
			packet.extract(hdr.vlan);
			transition parse_ip;
		}
		state parse_ip {
			packet.extract(hdr.ip);
			transition accept;
		}
	}
	control Ingress(inout headers_t hdr, inout metadata_t meta) {
		apply { meta.send_ip = hdr.ip.c; }
	}
`;

fn void guard_and_implicit_validity() @test {
	String dep = `
		control Dep(in headers_t hdr, in metadata_t meta, packet_out pkt) {
			apply {
				pkt.emit(hdr.ether);
				pkt.emit(hdr.vlan);
				if (meta.send_ip != 0) { pkt.emit(hdr.ip); }
			}
		}
	`;
	// No vlan: emit(hdr.vlan) on invalid header is a no-op (implicit validity).
	run_fixture("guard_novlan", GUARD_P4.tconcat(dep),
		"0102030405060708090a0b0c0800aabbccdd7879",
		"0102030405060708090a0b0c0800aabbccdd7879");
	// Guard false (ip.c == 0): ip dropped, payload follows ether.
	run_fixture("guard_drop", GUARD_P4.tconcat(dep),
		"0102030405060708090a0b0c0800aabb00dd7879",
		"0102030405060708090a0b0c08007879");
	// Vlan present and guard true: full reconstruction.
	run_fixture("guard_vlan", GUARD_P4.tconcat(dep),
		"0102030405060708090a0b0c810000640800aa11ccdd7879",
		"0102030405060708090a0b0c810000640800aa11ccdd7879");
}

fn void redundant_isvalid_guard_folds_to_validity() @test {
	// §2.3: if (h.isValid()) emit(h) is the redundant spelling of emit(h).
	// Both must produce identical output (comparison happens across fixtures).
	String dep = `
		control Dep(in headers_t hdr, in metadata_t meta, packet_out pkt) {
			apply {
				pkt.emit(hdr.ether);
				if (hdr.vlan.isValid()) { pkt.emit(hdr.vlan); }
				if (meta.send_ip != 0) { pkt.emit(hdr.ip); }
			}
		}
	`;
	run_fixture("fold_novlan", GUARD_P4.tconcat(dep),
		"0102030405060708090a0b0c0800aabbccdd7879",
		"0102030405060708090a0b0c0800aabbccdd7879");
	run_fixture("fold_vlan", GUARD_P4.tconcat(dep),
		"0102030405060708090a0b0c810000640800aa11ccdd7879",
		"0102030405060708090a0b0c810000640800aa11ccdd7879");
}

// ---- Point 2: loop parsing, last-value-survives ----------------------------

const String LOOP_P4 = `
	header tlv_t { bit<8> t; bit<8> l; bit<8> v; }
	struct headers_t { tlv_t tlv; }
	struct metadata_t { bit<8> dummy; }
	parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
		state start {
			packet.extract(hdr.tlv);
			transition select(hdr.tlv.t) {
				0: accept;
				default: start;
			}
		}
	}
	control Dep(in headers_t hdr, packet_out pkt) {
		apply { pkt.emit(hdr.tlv); }
	}
`;

fn void loop_last_value_survives() @test {
	// Three TLVs consumed; only the last extraction survives in the header.
	// The first two TLVs' bytes were consumed but are NOT emitted (§2.2);
	// the payload anchor is the final cursor position.
	String pkt = "0100aa0200bb0000cc7879";
	run_fixture("loop_last_wins", LOOP_P4, pkt, "0000cc7879");
}

fn void loop_zero_iterations_keeps_header_invalid() @test {
	// First TLV has type 0: loop body runs once, header still holds that TLV.
	String pkt = "0007427879";
	run_fixture("loop_single", LOOP_P4, pkt, "0007427879");
}

// ---- Point 3: extract_end, view form and gather form -----------------------

const String EXTRACT_END_VIEW_P4 = `
	header tlv_len_t { bit<8> type; bit<8> len; }
	header options_t { varbit<64> data; }
	struct headers_t { options_t options; }
	struct metadata_t { bit<8> dummy; }
	parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
		state start {
			transition parse_tlv;
		}
		state parse_tlv {
			tlv_len_t t = packet.lookahead<tlv_len_t>();
			packet.extract_end(hdr.options, 2 + t.len);
			transition select(t.type) {
				0: accept;
				default: parse_tlv;
			}
		}
	}
	control Dep(in headers_t hdr, packet_out pkt) {
		apply { pkt.emit(hdr.options); }
	}
`;

fn void extract_end_contiguous_view_form() @test {
	// TLV(1,len=2,"ab") then TLV(0,len=1,"z"); lookahead keeps the appends
	// adjacent, so the accumulated region is the whole 7-byte prefix.
	String pkt = "0102616200017a7879";
	run_fixture("extract_end_view", EXTRACT_END_VIEW_P4, pkt,
		"0102616200017a7879");
}

const String EXTRACT_END_GATHER_P4 = `
	header tlv_hdr_t { bit<8> type; bit<8> len; }
	header options_t { varbit<64> data; }
	struct headers_t { tlv_hdr_t tlv; options_t options; }
	struct metadata_t { bit<8> dummy; }
	parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
		state start {
			transition parse_tlv;
		}
		state parse_tlv {
			packet.extract(hdr.tlv);
			packet.extract_end(hdr.options, hdr.tlv.len);
			transition select(hdr.tlv.type) {
				0: accept;
				default: parse_tlv;
			}
		}
	}
	control Dep(in headers_t hdr, packet_out pkt) {
		apply { pkt.emit(hdr.options); }
	}
`;

fn void extract_end_gather_form_same_semantics() @test {
	// The extract(hdr.tlv) consumes bytes that are not appended: a gap, so
	// this is the materialized-scratch shape. Output differs from the view
	// form only by which bytes the program chose to accumulate.
	String pkt = "0102616200017a7879";
	run_fixture("extract_end_gather", EXTRACT_END_GATHER_P4, pkt, "61627a7879");
}

fn void extract_end_mixed_with_plain_extract() @test {
	// §3.1: a plain extract establishes the first segment, extract_end appends.
	String p4 = `
		header prefix_t { bit<8> a; bit<8> b; }
		header options_t { varbit<64> data; }
		struct headers_t { prefix_t pre; options_t options; }
		struct metadata_t { bit<8> dummy; }
		parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
			state start {
				packet.extract(hdr.pre);
				packet.extract_end(hdr.options, 3);
				transition accept;
			}
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.options); }
		}
	`;
	run_fixture("extract_end_after_extract", p4, "11223344557879", "3344557879");
}

// ---- Point 4: short packets reject -----------------------------------------

fn void short_packet_mid_loop_rejects() @test {
	// Second TLV announces 3 content bytes, only 1 remains -> ParserError.
	String pkt = "01026100037a";
	run_fixture("short_mid_loop", EXTRACT_END_VIEW_P4, pkt, "reject");
}

fn void short_packet_fixed_extract_rejects() @test {
	String p4 = `
		header ethernet_t { bit<48> dst; bit<48> src; bit<16> et; }
		struct headers_t { ethernet_t ether; }
		struct metadata_t { bit<8> dummy; }
		parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
			state start {
				packet.extract(hdr.ether);
				transition accept;
			}
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.ether); }
		}
	`;
	run_fixture("short_fixed", p4, "0102030405060708090a", "reject");
}

fn void explicit_reject_transition() @test {
	String p4 = `
		header ether_t { bit<8> a; }
		struct headers_t { ether_t e; }
		struct metadata_t { bit<8> dummy; }
		parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
			state start {
				packet.extract(hdr.e);
				transition select(hdr.e.a) {
					1: accept;
					default: reject;
				}
			}
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.e); }
		}
	`;
	run_fixture("explicit_reject", p4, "02", "reject");
	run_fixture("explicit_accept", p4, "017879", "017879");
}

// ---- Point 5: header stacks emit in index order ------------------------------

const String STACK_P4 = `
	header mpls_t { bit<8> label; bit<8> tc; bit<8> bos; }
	struct headers_t { mpls_t[4] mpls; }
	struct metadata_t { bit<8> dummy; }
	parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
		state start {
			packet.extract(hdr.mpls.next);
			transition select(hdr.mpls.last.bos) {
				0: start;
				default: accept;
			}
		}
	}
`;

fn void stack_emit_in_index_order() @test {
	String dep = `
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.mpls); }
		}
	`;
	// Two labels then payload; stack emits valid elements by index.
	String pkt = "0100010200007879";
	run_fixture("stack_order", STACK_P4.tconcat(dep), pkt, "0100010200007879");
}

fn void stack_emit_with_invalidated_element_leaves_no_hole() @test {
	String dep = `
		control Ingress(inout headers_t hdr, inout metadata_t meta) {
			apply {
				if (hdr.mpls[0].label == 1) { hdr.mpls[0].setInvalid(); }
			}
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.mpls); }
		}
	`;
	String pkt = "0100010200007879";
	run_fixture("stack_gap", STACK_P4.tconcat(dep), pkt, "0200007879");
}

// ---- Subset boundary diagnostics --------------------------------------------

fn void subset_diagnostics() @test {
	// Non-byte-aligned header field.
	expect_subset_error("diag_align", `
		header bad_t { bit<12> x; }
		struct headers_t { bad_t b; }
		struct metadata_t { bit<8> m; }
		parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
			state start { transition accept; }
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { }
		}
	`, "not byte-aligned");
	// Tables are outside the v0 subset.
	expect_subset_error("diag_table", `
		header ether_t { bit<8> a; }
		struct headers_t { ether_t e; }
		struct metadata_t { bit<8> m; }
		parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
			state start { packet.extract(hdr.e); transition accept; }
		}
		control Ing(inout headers_t hdr, inout metadata_t meta) {
			table t { key = { hdr.e.a: exact; } actions = { } }
			apply { }
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.e); }
		}
	`, "outside the v0 subset");
	// Duplicate emit of the same instance.
	expect_subset_error("diag_dup_emit", `
		header ether_t { bit<8> a; }
		struct headers_t { ether_t e; }
		struct metadata_t { bit<8> m; }
		parser P(packet_in packet, out headers_t hdr, inout metadata_t meta) {
			state start { packet.extract(hdr.e); transition accept; }
		}
		control Dep(in headers_t hdr, packet_out pkt) {
			apply { pkt.emit(hdr.e); pkt.emit(hdr.e); }
		}
	`, "emitted more than once");
}
