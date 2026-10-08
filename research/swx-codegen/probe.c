/* Research fixture, not a DPDK implementation or ABI-compatible runtime.
 * The included helper bodies are extracted unchanged from the pinned DPDK
 * source. Only TRACE and memcpy are intercepted; packet storage is synthetic.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define __rte_unused __attribute__((unused))
#define TRACE(...) ((void)0)
#define MASK64_BIT_GET(mask, pos) ((mask) & (1LLU << (pos)))
#define MASK64_BIT_SET(mask, pos) ((mask) | (1LLU << (pos)))
#define MASK64_BIT_CLR(mask, pos) ((mask) & ~(1LLU << (pos)))

/* Only members used by the extracted helpers; no ABI/layout equivalence. */
struct rte_swx_pipeline { unsigned thread_id; };
struct header_runtime { uint8_t *ptr0; uint32_t n_bytes; };
struct header_out_runtime { uint8_t *ptr0; uint8_t *ptr; uint32_t n_bytes; };
struct thread {
	struct { uint32_t offset, length; } pkt;
	uint8_t *ptr;
	uint8_t **structs;
	struct header_runtime *headers;
	struct header_out_runtime *headers_out;
	uint8_t *header_out_storage;
	uint64_t valid_headers;
	uint32_t n_headers_out;
	uint8_t *metadata;
};
struct instruction {
	struct {
		struct { uint8_t offset, n_bits; } io;
		struct { uint8_t header_id[8], struct_id[8], n_bytes[8]; } hdr;
	} io;
	struct { uint8_t header_id, struct_id; } valid;
};

static size_t copy_calls, copy_bytes;

static void *counted_memcpy(void *destination, const void *source, size_t size) {
	copy_calls++;
	copy_bytes += size;
	return memcpy(destination, source, size);
}

#define memcpy counted_memcpy
#include "swx_helpers.inc"
#undef memcpy

struct fixture {
	struct rte_swx_pipeline pipeline;
	struct thread thread;
	uint8_t packet[256];
	uint8_t storage[20];
	uint8_t scratch[20];
	uint8_t *views[4];
	struct header_runtime headers[4];
	struct header_out_runtime outputs[4];
	uint64_t metadata;
};

static void init(struct fixture *f) {
	static const uint32_t lengths[] = {4, 8, 4, 4};
	memset(f, 0, sizeof(*f));
	memcpy(f->packet + 32, "AAAABBBBBBBBCCCCPAYLOAD!", 24);
	f->thread.pkt.offset = 32;
	f->thread.pkt.length = 24;
	f->thread.ptr = f->packet + 32;
	f->thread.structs = f->views;
	f->thread.headers = f->headers;
	f->thread.headers_out = f->outputs;
	f->thread.header_out_storage = f->scratch;
	f->thread.metadata = (uint8_t *)&f->metadata;
	uint32_t offset = 0;
	for (unsigned i = 0; i < 4; i++) {
		f->headers[i].ptr0 = f->storage + offset;
		f->headers[i].n_bytes = lengths[i];
		f->views[i] = f->headers[i].ptr0;
		offset += lengths[i];
	}
	copy_calls = copy_bytes = 0;
}

static void extract_abc(struct fixture *f) {
	const struct instruction instruction = {.io.hdr = {
		.header_id = {0, 1, 2}, .struct_id = {0, 1, 2}, .n_bytes = {4, 8, 4}
	}};
	__instr_hdr_extract_many_exec(&f->pipeline, &f->thread, &instruction, 3);
	assert(f->views[0] == f->packet + 32);
	assert(f->views[1] == f->packet + 36);
	assert(f->views[2] == f->packet + 44);
	assert(f->thread.ptr == f->packet + 48);
	assert(f->thread.pkt.offset == 48 && f->thread.pkt.length == 8);
	assert(f->thread.valid_headers == 7);
	assert(copy_calls == 0);
}

static void emit(struct fixture *f, const uint8_t *ids, unsigned count) {
	struct instruction instruction = {0};
	assert(count <= 8);
	for (unsigned i = 0; i < count; i++) {
		instruction.io.hdr.header_id[i] = ids[i];
		instruction.io.hdr.struct_id[i] = ids[i];
	}
	__instr_hdr_emit_many_exec(&f->pipeline, &f->thread, &instruction, count);
}

static void layout_case(const char *name, const uint8_t *ids, unsigned count,
	const char *expected, unsigned expected_spans, size_t expected_calls,
	size_t expected_bytes) {
	struct fixture f;
	init(&f);
	extract_abc(&f);
	const struct instruction create_x = {.valid = {.header_id = 3, .struct_id = 3}};
	__instr_hdr_validate_exec(&f.pipeline, &f.thread, &create_x);
	memcpy(f.views[3], "XXXX", 4);
	emit(&f, ids, count);
	assert(copy_calls == 0);
	assert(f.thread.n_headers_out == expected_spans);
	emit_handler(&f.thread);
	assert(f.thread.pkt.length == strlen(expected));
	assert(f.thread.pkt.offset == 56 - strlen(expected));
	assert(memcmp(f.packet + f.thread.pkt.offset, expected, strlen(expected)) == 0);
	assert(memcmp(f.packet + 48, "PAYLOAD!", 8) == 0);
	assert(copy_calls == expected_calls && copy_bytes == expected_bytes);
	printf("%-18s spans=%u offset=%u length=%u memcpy_calls=%zu memcpy_bytes=%zu\n",
		name, expected_spans, f.thread.pkt.offset, f.thread.pkt.length,
		copy_calls, copy_bytes);
}

static void parser_and_validity_cases(void) {
	struct fixture f;
	struct instruction instruction = {.io.hdr = {
		.header_id = {0}, .struct_id = {0}, .n_bytes = {4}
	}};
	init(&f);
	__instr_hdr_lookahead_exec(&f.pipeline, &f.thread, &instruction);
	assert(f.views[0] == f.packet + 32 && f.thread.valid_headers == 1);
	assert(f.thread.pkt.offset == 32 && f.thread.pkt.length == 24);
	assert(f.thread.ptr == f.packet + 32 && copy_calls == 0);

	init(&f);
	f.metadata = 3;
	const struct instruction variable = {.io = {
		.io = {.n_bits = 64},
		.hdr = {.header_id = {1}, .struct_id = {1}, .n_bytes = {2}}
	}};
	__instr_hdr_extract_m_exec(&f.pipeline, &f.thread, &variable);
	assert(f.headers[1].n_bytes == 5);
	assert(f.thread.ptr == f.packet + 37);
	assert(f.thread.pkt.offset == 37 && f.thread.pkt.length == 19);
	assert(copy_calls == 0);

	init(&f);
	extract_abc(&f);
	const struct instruction a = {.valid = {.header_id = 0, .struct_id = 0}};
	__instr_hdr_validate_exec(&f.pipeline, &f.thread, &a);
	assert(f.views[0] == f.packet + 32);
	__instr_hdr_invalidate_exec(&f.pipeline, &f.thread, &a);
	assert(!(f.thread.valid_headers & 1));
	assert(f.views[0] == f.packet + 32);
	__instr_hdr_validate_exec(&f.pipeline, &f.thread, &a);
	assert(f.views[0] == f.headers[0].ptr0);
	assert(copy_calls == 0);

	init(&f);
	f.thread.pkt.length = 2;
	instruction.io.hdr.n_bytes[0] = 4;
	__instr_hdr_extract_many_exec(&f.pipeline, &f.thread, &instruction, 1);
	/* Allocated storage is large enough: this observes length underflow without
	 * actually accessing out-of-bounds memory or invoking a full SWX pipeline. */
	assert(f.thread.pkt.length == UINT32_MAX - 1);
	printf("parser helpers     lookahead, varbit, validity: OK; short length wraps to %u\n",
		f.thread.pkt.length);
}

static void deferred_emit_case(void) {
	struct fixture f;
	const uint8_t a[] = {0};
	init(&f);
	extract_abc(&f);
	emit(&f, a, 1);
	memset(f.views[0], 'Z', 4);
	emit(&f, a, 1);
	assert(f.thread.n_headers_out == 2);
	emit_handler(&f.thread);
	assert(memcmp(f.packet + f.thread.pkt.offset, "ZZZZZZZZPAYLOAD!", 16) == 0);
	assert(copy_bytes == 16);
	puts("deferred emit      emit A; mutate A; emit A => both outputs contain new bytes");
}

int main(void) {
	parser_and_validity_cases();
	layout_case("unchanged ABC", (uint8_t[]){0, 1, 2}, 3,
		"AAAABBBBBBBBCCCCPAYLOAD!", 1, 0, 0);
	layout_case("prefix drop BC", (uint8_t[]){1, 2}, 2,
		"BBBBBBBBCCCCPAYLOAD!", 1, 0, 0);
	layout_case("middle drop AC", (uint8_t[]){0, 2}, 2,
		"AAAACCCCPAYLOAD!", 2, 3, 16);
	layout_case("suffix drop AB", (uint8_t[]){0, 1}, 2,
		"AAAABBBBBBBBPAYLOAD!", 1, 2, 24);
	layout_case("prepend XABC", (uint8_t[]){3, 0, 1, 2}, 4,
		"XXXXAAAABBBBBBBBCCCCPAYLOAD!", 2, 1, 4);
	layout_case("insert AXBC", (uint8_t[]){0, 3, 1, 2}, 4,
		"AAAAXXXXBBBBBBBBCCCCPAYLOAD!", 3, 4, 40);
	layout_case("reorder BAC", (uint8_t[]){1, 0, 2}, 3,
		"BBBBBBBBAAAACCCCPAYLOAD!", 3, 4, 32);
	layout_case("payload only", NULL, 0, "PAYLOAD!", 0, 0, 0);
	deferred_emit_case();
	puts("All helper-level assertions passed.");
	return 0;
}
