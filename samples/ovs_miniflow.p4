// Packet-field extraction study of OVS v2.17.2 lib/flow.c.
// See docs/ovs-miniflow.md for the contract, differences and validation limits.
// This is a parser component, not a switch architecture or a miniflow serializer.
#include <core.p4>

header ethernet_t { bit<48> dst; bit<48> src; bit<16> type; }
header vlan_t { bit<16> tci; bit<16> type; }
header snap_t {
    bit<8> dsap; bit<8> ssap; bit<8> control;
    bit<24> oui; bit<16> type;
}
header mpls_t { bit<32> lse; }
header ipv4_t {
    bit<4> version; bit<4> ihl; bit<8> tos; bit<16> total_len;
    bit<16> id; bit<16> frag; bit<8> ttl; bit<8> protocol;
    bit<16> checksum; bit<32> src; bit<32> dst;
}
header ipv6_t {
    bit<4> version; bit<8> tc; bit<20> label;
    bit<16> payload_len; bit<8> next; bit<8> hop_limit;
    bit<128> src; bit<128> dst;
}
header ipv6_ext_t { bit<8> next; bit<8> len; }
header ipv6_frag_t {
    bit<8> next; bit<8> reserved; bit<16> off_flags; bit<32> id;
}
header tcp_t {
    bit<16> src; bit<16> dst; bit<32> seq; bit<32> ack;
    // OVS TCP_FLAGS masks all low 12 bits, including the reserved bits.
    bit<4> offset; bit<12> flags;
    bit<16> window; bit<16> checksum; bit<16> urgent;
}
header udp_t { bit<16> src; bit<16> dst; bit<16> len; bit<16> checksum; }
header sctp_t { bit<16> src; bit<16> dst; bit<32> tag; bit<32> checksum; }
header icmp_t { bit<8> type; bit<8> code; bit<16> checksum; bit<32> data; }
header arp_t {
    bit<16> hardware; bit<16> protocol; bit<8> hlen; bit<8> plen;
    bit<16> op; bit<48> sha; bit<32> spa; bit<48> tha; bit<32> tpa;
}
header nd_target_t { bit<128> target; }
header nd_option_t { bit<8> type; bit<8> len; bit<48> mac; }
header nsh_t {
    bit<2> version; bit<2> flags; bit<6> ttl; bit<6> words;
    bit<8> md_type; bit<8> next; bit<32> path;
}
header nsh_context_t { bit<32> c0; bit<32> c1; bit<32> c2; bit<32> c3; }

// Scratch headers, including a reusable slot for variable-length sequences.
// Consumers use key presence flags, not the validity of these scratch headers.
struct ovs_headers_t {
    ethernet_t ethernet; vlan_t vlan; snap_t snap; mpls_t mpls;
    ipv4_t ipv4; ipv6_t ipv6; ipv6_ext_t ext; ipv6_frag_t fragment;
    tcp_t tcp; udp_t udp; sctp_t sctp; icmp_t icmp; arp_t arp;
    nd_target_t target; nd_option_t option; nsh_t nsh; nsh_context_t context;
}

struct ovs_input_t {
    bit<32> packet_type; // 0 = Ethernet; otherwise use the low 16-bit ethertype.
    bit<32> vlan_limit;  // Host must provide 0..2, as in the OVS configuration.
}

// Logical flow fields in host numeric notation, NOT the struct miniflow ABI.
// Fields behind false presence flags are unspecified and must not be consumed.
struct ovs_key_t {
    bool has_l2; bool has_type; bool has_ipv4; bool has_ipv6;
    bool has_nw; bool has_ports; bool has_tcp_flags; bool has_arp;
    bool has_arp_op; bool has_igmp; bool has_nd; bool has_nd_target;
    bool has_nsh;
    bit<48> dl_dst; bit<48> dl_src; bit<16> dl_type;
    bit<32> vlan_count;
    bit<16> vlan0_tpid; bit<16> vlan0_tci;
    bit<16> vlan1_tpid; bit<16> vlan1_tci;
    bit<32> mpls_count; bit<32> mpls0; bit<32> mpls1; bit<32> mpls2;
    bit<32> nw_src; bit<32> nw_dst;
    bit<128> ipv6_src; bit<128> ipv6_dst; bit<20> ipv6_label;
    bit<8> nw_frag; bit<8> nw_tos; bit<8> nw_ttl; bit<8> nw_proto;
    bit<16> tp_src; bit<16> tp_dst; bit<16> tcp_flags;
    bit<48> arp_sha; bit<48> arp_tha; bit<8> arp_op;
    bit<32> igmp_group;
    bit<128> nd_target; bit<32> nd_reserved; bit<8> nd_opt_type;
    bit<2> nsh_flags; bit<6> nsh_ttl; bit<8> nsh_md_type;
    bit<8> nsh_next; bit<32> nsh_path;
    bit<32> nsh_c0; bit<32> nsh_c1; bit<32> nsh_c2; bit<32> nsh_c3;
}

struct ovs_parse_t {
    // Software-profile offsets; 0xffffffff means unset (OVS uses uint16_t).
    bit<32> l2_5; bit<32> l3; bit<32> l4; bit<32> l2_padding;
    // Internal cursor, bounded remaining length and scratch values.
    bit<32> offset; bit<32> remaining; bit<32> header_len;
    bit<32> payload_len; bit<32> option_len;
    bit<8> proto; bit<8> frag; bit<8> tos; bit<8> ttl;
}

parser OvsMiniflow(packet_in packet, out ovs_headers_t h,
                   out ovs_key_t key, out ovs_parse_t m, in ovs_input_t input) {
    state start {
        key.has_l2 = false; key.has_type = false;
        key.has_ipv4 = false; key.has_ipv6 = false; key.has_nw = false;
        key.has_ports = false; key.has_tcp_flags = false;
        key.has_arp = false; key.has_arp_op = false; key.has_igmp = false;
        key.has_nd = false; key.has_nd_target = false; key.has_nsh = false;
        key.vlan_count = 0; key.mpls_count = 0;
        m.l2_5 = 0xffffffff; m.l3 = 0xffffffff; m.l4 = 0xffffffff;
        m.l2_padding = 0; m.offset = 0; m.remaining = packet.length();
        m.frag = 0;
        transition select(input.packet_type) {
            0: ethernet_check;
            default: bare_l3;
        }
    }
    state bare_l3 {
        key.dl_type = (bit<16>)input.packet_type;
        key.has_type = true;
        transition network;
    }
    state ethernet_check {
        transition select(m.remaining >= 14) {
            true: ethernet;
            default: accept;
        }
    }
    state ethernet {
        packet.extract(h.ethernet);
        m.offset = 14; m.remaining = m.remaining - 14;
        key.dl_dst = h.ethernet.dst; key.dl_src = h.ethernet.src;
        key.dl_type = h.ethernet.type;
        key.has_l2 = true; key.has_type = true;
        transition vlan_check;
    }
    state vlan_check {
        // Four MORE bytes are needed: TCI plus the following ethertype.
        transition select((key.dl_type == 0x8100 || key.dl_type == 0x88a8)
                          && key.vlan_count < input.vlan_limit
                          && key.vlan_count < 2 && m.remaining >= 4) {
            true: vlan;
            default: ethertype;
        }
    }
    state vlan {
        packet.extract(h.vlan);
        if (key.vlan_count == 0) {
            key.vlan0_tpid = key.dl_type;
            key.vlan0_tci = h.vlan.tci | 0x1000;
        } else {
            key.vlan1_tpid = key.dl_type;
            key.vlan1_tci = h.vlan.tci | 0x1000;
        }
        key.vlan_count = key.vlan_count + 1;
        key.dl_type = h.vlan.type;
        m.offset = m.offset + 4; m.remaining = m.remaining - 4;
        transition vlan_check;
    }
    state ethertype {
        transition select(key.dl_type >= 0x0600) {
            true: network;
            default: snap_check;
        }
    }
    state snap_check {
        key.dl_type = 0x05ff; // FLOW_DL_TYPE_NONE
        transition select(m.remaining >= 8) {
            true: snap_peek;
            default: network;
        }
    }
    state snap_peek {
        h.snap = packet.lookahead<snap_t>();
        transition select(h.snap.dsap == 0xaa && h.snap.ssap == 0xaa
                          && h.snap.control == 3 && h.snap.oui == 0) {
            true: snap;
            default: network;
        }
    }
    state snap {
        packet.advance(64);
        m.offset = m.offset + 8; m.remaining = m.remaining - 8;
        if (h.snap.type >= 0x0600) { key.dl_type = h.snap.type; }
        transition network;
    }
    state network {
        m.l3 = m.offset;
        transition select(key.dl_type) {
            0x8847: mpls_start;
            0x8848: mpls_start;
            0x0800: ipv4_check;
            0x86dd: ipv6_check;
            0x0806: arp_check;
            0x8035: arp_check;
            0x894f: nsh_check;
            default: accept;
        }
    }
    state mpls_start {
        m.l2_5 = m.offset;
        transition mpls_check;
    }
    state mpls_check {
        transition select(m.remaining >= 4) {
            true: mpls;
            default: mpls_done;
        }
    }
    state mpls {
        packet.extract(h.mpls);
        if (key.mpls_count == 0) { key.mpls0 = h.mpls.lse; }
        if (key.mpls_count == 1) { key.mpls1 = h.mpls.lse; }
        if (key.mpls_count == 2) { key.mpls2 = h.mpls.lse; }
        if (key.mpls_count < 3) { key.mpls_count = key.mpls_count + 1; }
        m.offset = m.offset + 4; m.remaining = m.remaining - 4;
        transition select(h.mpls.lse & 0x100) {
            0: mpls_check;
            default: mpls_done;
        }
    }
    state mpls_done {
        // OVS consumes the whole stack, stores only three labels, and does
        // NOT guess IPv4/IPv6 from the MPLS payload's first nibble.
        m.l3 = m.offset;
        transition accept;
    }
    state ipv4_check {
        transition select(m.remaining >= 20) {
            true: ipv4_peek;
            default: accept;
        }
    }
    state ipv4_peek {
        h.ipv4 = packet.lookahead<ipv4_t>();
        m.header_len = (bit<32>)h.ipv4.ihl * 4;
        m.payload_len = (bit<32>)h.ipv4.total_len;
        // Like this OVS version, do not add an IP-version/checksum check.
        transition select(m.header_len >= 20 && m.header_len <= m.payload_len
                          && m.payload_len <= m.remaining
                          && m.remaining - m.payload_len <= 65535) {
            true: ipv4;
            default: accept;
        }
    }
    state ipv4 {
        key.nw_src = h.ipv4.src; key.nw_dst = h.ipv4.dst;
        key.has_ipv4 = true; key.ipv6_label = 0;
        m.tos = h.ipv4.tos; m.ttl = h.ipv4.ttl; m.proto = h.ipv4.protocol;
        if ((h.ipv4.frag & 0x3fff) != 0) { m.frag = 1; }
        if ((h.ipv4.frag & 0x1fff) != 0) { m.frag = 3; }
        m.l2_padding = m.remaining - m.payload_len;
        // advance() skips IPv4 options; the logical bound excludes padding.
        packet.advance(m.header_len * 8);
        m.offset = m.offset + m.header_len;
        m.remaining = m.payload_len - m.header_len;
        transition network_done;
    }
    state ipv6_check {
        transition select(m.remaining >= 40) {
            true: ipv6_peek;
            default: accept;
        }
    }
    state ipv6_peek {
        h.ipv6 = packet.lookahead<ipv6_t>();
        m.payload_len = (bit<32>)h.ipv6.payload_len;
        transition select(m.payload_len <= m.remaining - 40
                          && m.remaining - 40 - m.payload_len <= 65535) {
            true: ipv6;
            default: accept;
        }
    }
    state ipv6 {
        key.ipv6_src = h.ipv6.src; key.ipv6_dst = h.ipv6.dst;
        key.has_ipv6 = true;
        m.tos = h.ipv6.tc; m.ttl = h.ipv6.hop_limit; m.proto = h.ipv6.next;
        m.l2_padding = m.remaining - 40 - m.payload_len;
        packet.advance(320);
        m.offset = m.offset + 40; m.remaining = m.payload_len;
        transition ipv6_dispatch;
    }
    state ipv6_dispatch {
        transition select(m.proto) {
            0: ipv6_ext_check;
            43: ipv6_ext_check;
            60: ipv6_ext_check;
            51: ipv6_ext_check;
            44: ipv6_frag_check;
            default: ipv6_done;
        }
    }
    state ipv6_ext_check {
        transition select(m.remaining >= 8) {
            true: ipv6_ext_peek;
            default: accept;
        }
    }
    state ipv6_ext_peek {
        h.ext = packet.lookahead<ipv6_ext_t>();
        if (m.proto == 51) {
            m.header_len = ((bit<32>)h.ext.len + 2) * 4;
        } else {
            m.header_len = ((bit<32>)h.ext.len + 1) * 8;
        }
        transition select(m.header_len <= m.remaining) {
            true: ipv6_ext;
            default: accept;
        }
    }
    state ipv6_ext {
        packet.advance(m.header_len * 8);
        m.offset = m.offset + m.header_len;
        m.remaining = m.remaining - m.header_len;
        m.proto = h.ext.next;
        transition ipv6_dispatch;
    }
    state ipv6_frag_check {
        transition select(m.remaining >= 8) {
            true: ipv6_frag;
            default: accept;
        }
    }
    state ipv6_frag {
        packet.extract(h.fragment);
        m.offset = m.offset + 8; m.remaining = m.remaining - 8;
        m.proto = h.fragment.next;
        if (h.fragment.off_flags != 0) { m.frag = 1; }
        transition select(h.fragment.off_flags & 0xfff8) {
            0: ipv6_dispatch;
            default: ipv6_later;
        }
    }
    state ipv6_later {
        m.frag = 3; m.proto = 44;
        transition ipv6_done;
    }
    state ipv6_done {
        key.ipv6_label = h.ipv6.label;
        transition network_done;
    }
    state network_done {
        m.l4 = m.offset;
        key.nw_frag = m.frag; key.nw_tos = m.tos;
        key.nw_ttl = m.ttl; key.nw_proto = m.proto; key.has_nw = true;
        transition select(m.frag & 2) {
            0: transport;
            default: accept;
        }
    }
    state transport {
        transition select(m.proto) {
            6: tcp_check;
            17: udp_check;
            132: sctp_check;
            1: icmp_check;
            2: icmp_check;
            58: icmp_check;
            default: accept;
        }
    }
    state tcp_check {
        transition select(m.remaining >= 20) {
            true: tcp_peek;
            default: accept;
        }
    }
    state tcp_peek {
        h.tcp = packet.lookahead<tcp_t>();
        m.header_len = (bit<32>)h.tcp.offset * 4;
        transition select(m.header_len >= 20 && m.header_len <= m.remaining) {
            true: tcp;
            default: accept;
        }
    }
    state tcp {
        key.tp_src = h.tcp.src; key.tp_dst = h.tcp.dst; key.has_ports = true;
        key.tcp_flags = (bit<16>)h.tcp.flags; key.has_tcp_flags = true;
        transition accept;
    }
    state udp_check {
        transition select(m.remaining >= 8) {
            true: udp;
            default: accept;
        }
    }
    state udp {
        h.udp = packet.lookahead<udp_t>();
        // OVS extracts ports without validating UDP length/checksum.
        key.tp_src = h.udp.src; key.tp_dst = h.udp.dst; key.has_ports = true;
        transition accept;
    }
    state sctp_check {
        transition select(m.remaining >= 12) {
            true: sctp;
            default: accept;
        }
    }
    state sctp {
        h.sctp = packet.lookahead<sctp_t>();
        key.tp_src = h.sctp.src; key.tp_dst = h.sctp.dst; key.has_ports = true;
        transition accept;
    }
    state icmp_check {
        transition select(m.remaining >= 8) {
            true: icmp;
            default: accept;
        }
    }
    state icmp {
        h.icmp = packet.lookahead<icmp_t>();
        key.tp_src = (bit<16>)h.icmp.type;
        key.tp_dst = (bit<16>)h.icmp.code; key.has_ports = true;
        transition select(m.proto) {
            2: igmp;
            58: icmpv6;
            default: accept;
        }
    }
    state igmp {
        key.igmp_group = h.icmp.data; key.has_igmp = true;
        transition accept;
    }
    state icmpv6 {
        packet.advance(64);
        m.offset = m.offset + 8; m.remaining = m.remaining - 8;
        transition select(h.icmp.code == 0
                          && (h.icmp.type == 135 || h.icmp.type == 136)) {
            true: nd_check;
            default: accept;
        }
    }
    state nd_check {
        key.has_nd = true; key.nd_reserved = h.icmp.data;
        key.arp_sha = 0; key.arp_tha = 0; key.nd_opt_type = 0;
        transition select(m.remaining >= 16) {
            true: nd_target;
            default: accept;
        }
    }
    state nd_target {
        packet.extract(h.target);
        key.nd_target = h.target.target; key.has_nd_target = true;
        m.offset = m.offset + 16; m.remaining = m.remaining - 16;
        transition nd_option_check;
    }
    state nd_option_check {
        transition select(m.remaining >= 8) {
            true: nd_option_peek;
            default: accept;
        }
    }
    state nd_option_peek {
        h.option = packet.lookahead<nd_option_t>();
        m.option_len = (bit<32>)h.option.len * 8;
        transition select(m.option_len != 0 && m.option_len <= m.remaining) {
            true: nd_option;
            default: accept; // Keep target and options already extracted.
        }
    }
    state nd_option {
        transition select(h.option.type, h.option.len) {
            (1, 1): nd_source;
            (2, 1): nd_destination;
            default: nd_advance;
        }
    }
    state nd_source {
        // Deliberately match OVS's zero-MAC sentinel, not a seen-option flag.
        transition select(key.arp_sha == 0) {
            true: nd_source_save;
            default: nd_invalid;
        }
    }
    state nd_source_save {
        key.arp_sha = h.option.mac;
        if (key.nd_opt_type == 0) { key.nd_opt_type = 1; }
        transition nd_advance;
    }
    state nd_destination {
        transition select(key.arp_tha == 0) {
            true: nd_destination_save;
            default: nd_invalid;
        }
    }
    state nd_destination_save {
        key.arp_tha = h.option.mac;
        if (key.nd_opt_type == 0) { key.nd_opt_type = 2; }
        transition nd_advance;
    }
    state nd_advance {
        packet.advance(m.option_len * 8);
        m.offset = m.offset + m.option_len;
        m.remaining = m.remaining - m.option_len;
        transition nd_option_check;
    }
    state nd_invalid {
        key.has_nd_target = false; key.arp_sha = 0; key.arp_tha = 0;
        // OVS retains the first option type and reserved field here.
        transition accept;
    }
    state arp_check {
        transition select(m.remaining >= 28) {
            true: arp_peek;
            default: accept;
        }
    }
    state arp_peek {
        h.arp = packet.lookahead<arp_t>();
        transition select(h.arp.hardware == 1 && h.arp.protocol == 0x0800
                          && h.arp.hlen == 6 && h.arp.plen == 4) {
            true: arp;
            default: accept;
        }
    }
    state arp {
        key.nw_src = h.arp.spa; key.nw_dst = h.arp.tpa;
        key.arp_sha = h.arp.sha; key.arp_tha = h.arp.tha; key.has_arp = true;
        if (h.arp.op <= 255) {
            key.arp_op = (bit<8>)h.arp.op; key.has_arp_op = true;
        }
        transition accept;
    }
    state nsh_check {
        transition select(m.remaining >= 8) {
            true: nsh_peek;
            default: accept;
        }
    }
    state nsh_peek {
        h.nsh = packet.lookahead<nsh_t>();
        m.header_len = (bit<32>)h.nsh.words * 4;
        transition select(h.nsh.version == 0 && m.header_len <= m.remaining) {
            true: nsh_dispatch;
            default: accept;
        }
    }
    state nsh_dispatch {
        transition select(h.nsh.md_type) {
            1: nsh_md1_check;
            2: nsh_md2_check;
            default: nsh;
        }
    }
    state nsh_md1_check {
        transition select(m.header_len == 24) {
            true: nsh_md1;
            default: accept;
        }
    }
    state nsh_md1 {
        packet.advance(64);
        packet.extract(h.context);
        transition nsh;
    }
    state nsh_md2_check {
        transition select(m.header_len >= 8) {
            true: nsh;
            default: accept;
        }
    }
    state nsh {
        key.nsh_flags = h.nsh.flags; key.nsh_ttl = h.nsh.ttl;
        key.nsh_md_type = h.nsh.md_type; key.nsh_next = h.nsh.next;
        key.nsh_path = h.nsh.path;
        key.nsh_c0 = 0; key.nsh_c1 = 0; key.nsh_c2 = 0; key.nsh_c3 = 0;
        if (h.nsh.md_type == 1) {
            key.nsh_c0 = h.context.c0; key.nsh_c1 = h.context.c1;
            key.nsh_c2 = h.context.c2; key.nsh_c3 = h.context.c3;
        }
        key.has_nsh = true;
        // Terminal extraction only: do not recurse into the NSH payload.
        transition accept;
    }
}
