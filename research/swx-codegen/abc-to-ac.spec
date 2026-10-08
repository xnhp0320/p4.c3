struct a_t {
    bit<32> value
}
struct b_t {
    bit<64> value
}
struct c_t {
    bit<32> value
}
struct metadata_t {
    bit<64> input_port
    bit<64> output_port
}
header a instanceof a_t
header b instanceof b_t
header c instanceof c_t
metadata instanceof metadata_t
apply {
    rx m.input_port
    extract h.a
    extract h.b
    extract h.c
    mov m.output_port 0
    emit h.a
    emit h.c
    tx m.output_port
}
