// Simple P4_16 subset: Ethernet parse + L2 exact-match table.
// p4c3 parses header types, structs, parser states, controls, actions, and tables.

const bit<16> ETHERTYPE_IPV4 = 0x0800;

header ethernet_t {
    bit<48> dst_addr;
    bit<48> src_addr;
    bit<16> ether_type;
}

struct headers_t {
    ethernet_t ethernet;
}

struct metadata_t {
    bit<9> egress_port;
    bit<1> drop;
}

parser EthernetParser(packet_in packet, out headers_t hdr) {
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            ETHERTYPE_IPV4: parse_done;
            default: reject;
        }
    }

    state parse_done {
        transition accept;
    }
}

control Ingress(inout headers_t hdr, inout metadata_t meta) {
    action drop() {
        meta.drop = 1;
    }

    action l2_forward(bit<9> port) {
        meta.drop = 0;
        meta.egress_port = port;
    }

    table dmac {
        key = {
            hdr.ethernet.dst_addr: exact;
        }
        actions = {
            l2_forward;
            drop;
        }
        size = 1024;
        default_action = drop();
    }

    apply {
        if (hdr.ethernet.ether_type == ETHERTYPE_IPV4) {
            dmac.apply();
        } else {
            drop();
        }
    }
}

control Egress(inout headers_t hdr, inout metadata_t meta) {
    apply { }
}
