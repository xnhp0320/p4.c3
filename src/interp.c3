module p4c3;
import std::collections::list;

// Reference model for the v0 subset (docs/v0-subset.md §4): a slow but
// obviously correct interpreter. It is the executable definition of v0
// semantics and the oracle for differential testing against the planner.
// 
// All runtime values are big-endian byte strings; arithmetic is done on
// ulongs. This is the byte-oriented v0: header fields are bit<W> with W a
// multiple of 8, and numbers normalize to 8 bytes at eval time.

excuse INTERP_ERROR;

struct Value {
    List{char} bytes;
}

fn Value make_value(Allocator alloc) {
    Value v;
    v.bytes.init(alloc);
    return v;
}

fn Value value_from_slice(Allocator alloc, char[] bytes) {
    Value v = make_value(alloc);
    v.bytes.push_all(bytes);
    return v;
}

fn ulong value_as_ulong(Value* v) {
    ulong r = 0;
    foreach (b : v.bytes) r = (r << 8) | (char)b;
    return r;
}

fn bool value_truthy(Value* v) {
    foreach (b : v.bytes) if (b != 0) return true;
    return false;
}

fn Value value_uint(Allocator alloc, ulong n) {
    Value v = make_value(alloc);
    for (int i = 7; i >= 0; i--) v.bytes.push((char)((n >> (i * 8)) & 0xff));
    return v;
}

// Parse a P4 integer literal: [0x|0b|0o]digits with optional width prefix
// (e.g. "16w0x8100"). Underscores are skipped.
fn ulong? parse_uint_lit(String text) {
    String s = text;
    usz i = 0;
    while (i < s.len && s[i].is_digit()) i++;
    if (i > 0 && i < s.len && (s[i] == 'w' || s[i] == 'W' || s[i] == 's' || s[i] == 'S')) {
        s = s[i + 1..];
    }
    if (s.len < 2) {
        ulong? v = s.to_ulong();
        if (catch v) return PARSE_FAILED~;
        return v;
    }
    ulong base = 10;
    usz start = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        start = 2;
    } else if (s[0] == '0' && (s[1] == 'b' || s[1] == 'B')) {
        base = 2;
        start = 2;
    } else if (s[0] == '0' && (s[1] == 'o' || s[1] == 'O')) {
        base = 8;
        start = 2;
    }
    if (start >= s.len) return PARSE_FAILED~;
    ulong v = 0;
    foreach (c : s[start..]) {
        uint d;
        if (c == '_') continue;
        if (c.is_digit()) {
            d = (uint)c - '0';
        } else if (c.is_xdigit() && base == 16) {
            d = 10 + (uint)(c | 0x20) - 'a';
        } else {
            return PARSE_FAILED~;
        }
        if (d >= base) return PARSE_FAILED~;
        v = v * base + d;
    }
    return v;
}

// ---- Runtime stores ------------------------------------------------------

struct ParamBind {
    String pname;
    String type_name;
}

struct HdrInst {
    bool valid;
    Decl* type;
    List{char} data; // fixed part followed by varbit content
}

fn void HdrInst.init(&self, Allocator alloc, Decl* type) {
    self.valid = false;
    self.type = type;
    self.data.init(alloc);
}

fn sz HdrInst.fixed_size(&self) {
    return header_fixed_size(self.type);
}

struct StoreMember {
    String name;
    bool is_stack;
    // Header instance member:
    HdrInst hdr;
    List{HdrInst} stack;
    usz stack_next;
    // Flat (metadata) member:
    List{char} flat;
    usz width;
}

struct StructStore {
    String type_name;
    Decl* decl;
    bool flat;
    List{StoreMember} members;
}

struct LocalVar {
    String name;
    List{char} bytes;
    Decl* hdr_type; // set when the local is a header-typed variable
}

struct Ref {
    HdrInst* hdr; // whole header instance (extract/emit/setValid/isValid)
    List{HdrInst}* stack; // whole stack (emit hdr.stack)
    StoreMember* member; // owning stack member (for .next advancement)
    List{char}* buf; // value lvalue storage (header data, flat field, or local)
    sz field_off;
    sz field_width; // 0 with is_field = varbit "rest of content"
    bool is_field;
    bool via_next; // resolved through .next (extract advances stack_next)
}

struct Interp {
    Allocator alloc;
    TypeIndex* idx;
    Program* prog;
    String src_name;
    char[] packet;
    sz cursor;
    List{StructStore} roots;
    List{LocalVar} locals;
    List{ParamBind} binds;
    List{char} out;
    String packet_in_name;
    String packet_out_name;
    String err;
    bool stopped; // reject/exit: unwind without faulting
    bool rejected;
}

fn void? Interp.fail(&self, String msg) {
    if (!self.err) self.err = msg;
    return INTERP_ERROR~;
}

// ---- Root store management ----------------------------------------------

fn StoreMember* new_member(Allocator alloc, StructStore* store, String name) {
    store.members.push({ .name = name });
    StoreMember* m = &store.members[store.members.len() - 1];
    m.hdr.data.init(alloc);
    m.stack.init(alloc);
    m.flat.init(alloc);
    return m;
}

// Get or create the store for a struct type, populating members from the decl.
fn StructStore*? Interp.get_root(&self, String type_name) {
    foreach (&r : self.roots) if (r.type_name == type_name) return r;
    Decl*? decl = self.idx.find_struct(type_name);
    if (catch decl) {
        self.fail(string::tformat("undefined struct type '%s'", type_name))!;
        unreachable("fail always faults");
    }
    StructStore store;
    store.type_name = type_name;
    store.decl = decl;
    store.flat = true;
    foreach (f : decl.fields) {
        if (f.type.kind == TypeKind.NAME) store.flat = false;
    }
    store.members.init(self.alloc);
    self.roots.push(store);
    StructStore* r = &self.roots[self.roots.len() - 1];
    foreach (f : decl.fields) {
        StoreMember* m = new_member(self.alloc, r, f.name);
        if (f.type.kind == TypeKind.NAME) {
            Decl* h = self.idx.find_header(f.type.name)!!;
            m.is_stack = f.type.stack_size > 0;
            if (m.is_stack) {
                for (sz i = 0; i < (sz)f.type.stack_size; i++) {
                    m.stack.push({ });
                    m.stack[i].init(self.alloc, h);
                }
            } else {
                m.hdr.init(self.alloc, h);
            }
        } else {
            m.width = f.type.width / 8;
            for (usz i = 0; i < m.width; i++) m.flat.push(0);
        }
    }
    return r;
}

// Bind a callable's params: struct params map onto shared stores keyed by
// type name (parser out-param and deparser in-param share storage); the
// packet_in/packet_out names are recorded for method dispatch.
fn void? Interp.bind_params(&self, Decl* callable) {
    foreach (p : callable.params) {
        if (p.type.kind != TypeKind.NAME) continue;
        if (p.type.name == "packet_in") {
            self.packet_in_name = p.name;
            continue;
        }
        if (p.type.name == "packet_out") {
            self.packet_out_name = p.name;
            continue;
        }
        if (catch self.idx.find_struct(p.type.name)) continue;
        (void)self.get_root(p.type.name)!;
        bool known = false;
        foreach (b : self.binds) if (b.pname == p.name && b.type_name == p.type.name) known = true;
        if (!known) self.binds.push({ .pname = p.name, .type_name = p.type.name });
    }
}

// Resolve a param name to its store.
fn StructStore* Interp.store_for(&self, String pname) {
    foreach (b : self.binds) {
        if (b.pname == pname) {
            foreach (&r : self.roots) if (r.type_name == b.type_name) return r;
        }
    }
    return null;
}

// Find the StructStore whose struct declares a header/member name — used for
// param names bound before their store exists is impossible, but locals and
// consts take priority during expression resolution.
fn StoreMember* find_member(StructStore* store, String name) {
    foreach (&m : store.members) if (m.name == name) return m;
    return null;
}
// ---- Path resolution -----------------------------------------------------
// 
// A Ref describes what `hdr.a.b[i]` designates: a whole header instance, a
// field slice within it, a whole stack, or a flat metadata field.

fn Ref ref_hdr(HdrInst* h, bool via_next, StoreMember* m) {
    return { .hdr = h, .via_next = via_next, .member = m };
}

// Resolve an lvalue/member expression to a Ref.
fn Ref? Interp.resolve_path(&self, Expr* expr) {
    if (expr.kind == ExprKind.MEMBER) {
        Expr* base = expr.kids[0];
        // Stack selector: hdr.stack.next / hdr.stack.last
        if (base.kind == ExprKind.MEMBER && (expr.token.text == "next" || expr.token.text == "last")) {
            Ref r = self.resolve_path(base)!;
            if (!r.member || !r.member.is_stack) {
                self.fail(string::tformat("'%s' is not a header stack", expr.token.text))!;
                unreachable("fail always faults");
            }
            sz idx = (sz)(expr.token.text == "next" ? r.member.stack_next : r.member.stack_next - 1);
            if (expr.token.text == "next" && idx >= r.member.stack.len()) {
                self.rejected = true;
                self.stopped = true;
                self.fail("parser stack overflow on .next")!;
                unreachable("fail always faults");
            }
            if (expr.token.text == "last" && r.member.stack_next == 0) {
                self.rejected = true;
                self.stopped = true;
                self.fail("parser stack underflow on .last")!;
                unreachable("fail always faults");
            }
            return ref_hdr(&r.member.stack[idx], expr.token.text == "next", r.member);
        }
        if (base.kind == ExprKind.IDENT) {
            // Header-typed local variable: t.field
            foreach (&lv : self.locals) {
                if (lv.name == base.token.text && lv.hdr_type) {
                    return self.field_in_buffer(&lv.bytes, lv.hdr_type, expr.token.text)!;
                }
            }
            // root.member — root is a param, member is a struct member.
            StructStore* store = self.store_for(base.token.text);
            if (!store) {
                self.fail(string::tformat("'%s' is not a header/metadata parameter", base.token.text))!;
                unreachable("fail always faults");
            }
            StoreMember* m = find_member(store, expr.token.text);
            if (m) {
                if (m.is_stack) return { .stack = &m.stack, .member = m };
                if (m.width > 0) return { .buf = &m.flat, .field_width = (sz)m.width, .is_field = true };
                return ref_hdr(&m.hdr, false, m);
            }
            // Deeper member: base must itself resolve to a header instance.
            Ref base_ref = self.resolve_path(base)!;
            if (!base_ref.hdr) {
                self.fail(string::tformat("cannot resolve '.%s'", expr.token.text))!;
                unreachable("fail always faults");
            }
            return self.resolve_field(base_ref.hdr, expr.token.text)!;
        }
        if (base.kind == ExprKind.MEMBER || base.kind == ExprKind.INDEX) {
            Ref base_ref = self.resolve_path(base)!;
            if (base_ref.hdr) return self.resolve_field(base_ref.hdr, expr.token.text)!;
            if (base_ref.buf && base_ref.is_field) {
                // Chained field access on values is not expressible in v0.
                self.fail(string::tformat("cannot resolve '.%s' on a field value", expr.token.text))!;
                unreachable("fail always faults");
            }
            if (base_ref.stack) {
                self.fail(
                    string::tformat("member '%s' of a stack: only .next/.last select elements", expr.token.text)
                )!;
                unreachable("fail always faults");
            }
            self.fail(string::tformat("cannot resolve '.%s'", expr.token.text))!;
            unreachable("fail always faults");
        }
        self.fail(string::tformat("cannot resolve member '%s'", expr.token.text))!;
        unreachable("fail always faults");
    }
    if (expr.kind == ExprKind.INDEX) {
        Ref r = self.resolve_path(expr.kids[0])!;
        if (!r.member || !r.member.is_stack) {
            self.fail("indexing is only supported on header stacks in v0")!;
            unreachable("fail always faults");
        }
        Value iv = self.eval(expr.kids[1])!;
        sz idx = (sz)value_as_ulong(&iv);
        if (idx >= r.member.stack.len()) {
            self.rejected = true;
            self.stopped = true;
            self.fail("header stack index out of bounds")!;
            unreachable("fail always faults");
        }
        return ref_hdr(&r.member.stack[idx], false, r.member);
    }
    self.fail(string::tformat("'%s' does not designate a header instance", expr.token.text))!;
    unreachable("fail always faults");
}

// Field lvalue within a raw byte buffer (header data or header-typed local).
fn Ref? Interp.field_in_buffer(&self, List{char}* buf, Decl* hdr_type, String field_name) {
    sz width;
    sz? off = header_field_offset(hdr_type, field_name, &width);
    if (catch off) {
        self.fail(string::tformat("header '%s' has no field '%s'", hdr_type.name, field_name))!;
        unreachable("fail always faults");
    }
    if (width == 0) {
        return { .buf = buf, .field_off = header_fixed_size(hdr_type), .field_width = 0, .is_field = true };
    }
    return { .buf = buf, .field_off = off, .field_width = width, .is_field = true };
}

fn Ref? Interp.resolve_field(&self, HdrInst* hdr, String field_name) {
    Ref r = self.field_in_buffer(&hdr.data, hdr.type, field_name)!;
    r.hdr = hdr;
    return r;
}

// ---- Expression evaluation ----------------------------------------------

fn Value? Interp.eval(&self, Expr* expr) {
    if (self.stopped) return make_value(self.alloc);
    switch (expr.kind) {
        case ExprKind.NUMBER:
            ulong? n = parse_uint_lit(expr.token.text);
            if (catch n) {
                self.fail(string::tformat("bad integer literal '%s'", expr.token.text))!;
                unreachable("fail always faults");
            }
            return value_uint(self.alloc, n);
        case ExprKind.IDENT:
            foreach (&lv : self.locals) {
                if (lv.name == expr.token.text) return value_from_slice(self.alloc, lv.bytes.array_view());
            }
            Decl*? decl = self.idx.find_const(expr.token.text);
            if (catch decl) {
                self.fail(string::tformat("undefined name '%s'", expr.token.text))!;
                unreachable("fail always faults");
            }
            return self.eval(decl.value)!;
        case ExprKind.MEMBER:
        case ExprKind.INDEX:
            Ref r = self.resolve_path(expr)!;
            if (!r.buf) {
                self.fail("expression does not denote a value")!;
                unreachable("fail always faults");
            }
            char[] b = r.buf.array_view();
            if (r.field_width == 0 && r.is_field) {
                // varbit field: rest of content
                return value_from_slice(self.alloc, b[r.field_off..]);
            }
            return value_from_slice(self.alloc, b[r.field_off:r.field_width]);
        case ExprKind.CALL:
            return self.eval_call(expr)!;
        case ExprKind.CAST:
            Value v = self.eval(expr.kids[0])!;
            sz want = (sz)expr.type.width / 8;
            Value out = make_value(self.alloc);
            char[] b = v.bytes.array_view();
            if (b.len >= want) {
                out.bytes.push_all(b[b.len - want..]);
            } else {
                for (sz i = want - b.len; i > 0; i--) out.bytes.push(0);
                out.bytes.push_all(b);
            }
            return out;
        case ExprKind.UNARY:
            Value v = self.eval(expr.kids[0])!;
            ulong n = value_as_ulong(&v);
            switch (expr.token.kind) {
                case TokenKind.BANG:
                    return value_uint(self.alloc, n == 0 ? 1 : 0);
                case TokenKind.TILDE:
                    return value_uint(self.alloc, ~n);
                case TokenKind.MINUS:
                    return value_uint(self.alloc, (ulong)(-(long)n));
                default:
                    self.fail(string::tformat("unsupported unary operator '%s'", expr.token.text))!;
                    unreachable("fail always faults");
            }
        case ExprKind.BINARY:
            return self.eval_binary(expr)!;
        case ExprKind.STR:
            self.fail("string literals are outside the v0 subset")!;
            unreachable("fail always faults");
        case ExprKind.TUPLE:
            Value out = make_value(self.alloc);
            foreach (kid : expr.kids) {
                Value v = self.eval(kid)!;
                out.bytes.push_all(v.bytes.array_view());
            }
            return out;
    }
    self.fail("unsupported expression")!;
    unreachable("fail always faults");
}

fn Value? Interp.eval_binary(&self, Expr* expr) {
    TokenKind op = expr.token.kind;
    if (op == TokenKind.ANDAND) {
        Value l = self.eval(expr.kids[0])!;
        if (!value_truthy(&l)) return value_uint(self.alloc, 0);
        Value r = self.eval(expr.kids[1])!;
        return value_uint(self.alloc, value_truthy(&r) ? 1 : 0);
    }
    if (op == TokenKind.OROR) {
        Value l = self.eval(expr.kids[0])!;
        if (value_truthy(&l)) return value_uint(self.alloc, 1);
        Value r = self.eval(expr.kids[1])!;
        return value_uint(self.alloc, value_truthy(&r) ? 1 : 0);
    }
    Value l = self.eval(expr.kids[0])!;
    Value r = self.eval(expr.kids[1])!;
    ulong a = value_as_ulong(&l);
    ulong b = value_as_ulong(&r);
    switch (op) {
        case TokenKind.PLUS: return value_uint(self.alloc, a + b);
        case TokenKind.MINUS: return value_uint(self.alloc, a - b);
        case TokenKind.STAR: return value_uint(self.alloc, a * b);
        case TokenKind.SLASH:
            if (b == 0) {
                self.fail("division by zero")!;
                unreachable("fail always faults");
            }
            return value_uint(self.alloc, a / b);
        case TokenKind.PERCENT:
            if (b == 0) {
                self.fail("division by zero")!;
                unreachable("fail always faults");
            }
            return value_uint(self.alloc, a % b);
        case TokenKind.LSHIFT: return value_uint(self.alloc, a << b);
        case TokenKind.RSHIFT: return value_uint(self.alloc, a >> b);
        case TokenKind.AMP: return value_uint(self.alloc, a & b);
        case TokenKind.PIPE: return value_uint(self.alloc, a | b);
        case TokenKind.CARET: return value_uint(self.alloc, a ^ b);
        case TokenKind.EQEQ: return value_uint(self.alloc, a == b ? 1 : 0);
        case TokenKind.NEQ: return value_uint(self.alloc, a != b ? 1 : 0);
        case TokenKind.LT: return value_uint(self.alloc, a < b ? 1 : 0);
        case TokenKind.GT: return value_uint(self.alloc, a > b ? 1 : 0);
        case TokenKind.LE: return value_uint(self.alloc, a <= b ? 1 : 0);
        case TokenKind.GE: return value_uint(self.alloc, a >= b ? 1 : 0);
        case TokenKind.MASKAND: return value_uint(self.alloc, a & b);
        default:
            self.fail(string::tformat("unsupported binary operator '%s'", expr.token.text))!;
            unreachable("fail always faults");
    }
}

// Method-call dispatch: packet.extract/extract_end/lookahead,
// hdr.setValid/setInvalid/isValid. emit is handled by the deparser driver.
fn Value? Interp.eval_call(&self, Expr* call) {
    Expr* callee = call.kids[0];
    if (callee.kind != ExprKind.MEMBER) {
        self.fail("unsupported call target")!;
        unreachable("fail always faults");
    }
    String method = callee.token.text;
    Expr* obj = callee.kids[0];
    String obj_name = obj.kind == ExprKind.IDENT ? obj.token.text : "";
    bool on_packet = obj_name == self.packet_in_name;

    switch (method) {
        case "extract":
            if (!on_packet) {
                self.fail("extract is only available on packet_in")!;
                unreachable("fail always faults");
            }
            if (call.kids.len() < 2 || call.kids.len() > 3) {
                self.fail("extract takes a header and optionally a byte length")!;
                unreachable("fail always faults");
            }
            Ref r = self.resolve_path(call.kids[1])!;
            if (!r.hdr) {
                self.fail("extract argument must be a header instance")!;
                unreachable("fail always faults");
            }
            sz n = r.hdr.fixed_size();
            sz varbit_extra = 0;
            if (call.kids.len() == 3) {
                Value lv = self.eval(call.kids[2])!;
                varbit_extra = (sz)value_as_ulong(&lv);
                n += varbit_extra;
            }
            self.extract_bytes(r.hdr, n)!;
            if (r.via_next && r.member) r.member.stack_next++;
            return make_value(self.alloc);
        case "extract_end":
            if (!on_packet) {
                self.fail("extract_end is only available on packet_in")!;
                unreachable("fail always faults");
            }
            if (call.kids.len() != 3) {
                self.fail("extract_end takes a header and a byte count")!;
                unreachable("fail always faults");
            }
            Ref r = self.resolve_path(call.kids[1])!;
            if (!r.hdr) {
                self.fail("extract_end argument must be a header instance")!;
                unreachable("fail always faults");
            }
            Value nv = self.eval(call.kids[2])!;
            sz n = (sz)value_as_ulong(&nv);
            self.extract_end_bytes(r.hdr, n)!;
            if (r.via_next && r.member) r.member.stack_next++;
            return make_value(self.alloc);
        case "lookahead":
            if (!on_packet) {
                self.fail("lookahead is only available on packet_in")!;
                unreachable("fail always faults");
            }
            if (call.type_args.len() != 1) {
                self.fail("lookahead requires one type argument")!;
                unreachable("fail always faults");
            }
            TypeRef ty = call.type_args[0];
            sz n;
            if (ty.kind == TypeKind.BIT) {
                n = ty.width / 8;
            } else {
                Decl*? h = self.idx.find_header(ty.name);
                if (catch h) {
                    self.fail(string::tformat("lookahead of unknown type '%s'", ty.name))!;
                    unreachable("fail always faults");
                }
                n = header_fixed_size(h);
            }
            if (self.cursor + n > self.packet.len) {
                self.rejected = true;
                self.stopped = true;
                return make_value(self.alloc);
            }
            return value_from_slice(self.alloc, self.packet[self.cursor:n]);
        case "setValid":
            Ref r = self.resolve_path(obj)!;
            if (!r.hdr) {
                self.fail("setValid argument must be a header instance")!;
                unreachable("fail always faults");
            }
            r.hdr.valid = true;
            if (r.hdr.data.len() < r.hdr.fixed_size()) {
                for (sz i = r.hdr.data.len(); i < r.hdr.fixed_size(); i++) r.hdr.data.push(0);
            }
            return make_value(self.alloc);
        case "setInvalid":
            Ref r = self.resolve_path(obj)!;
            if (!r.hdr) {
                self.fail("setInvalid argument must be a header instance")!;
                unreachable("fail always faults");
            }
            r.hdr.valid = false;
            return make_value(self.alloc);
        case "isValid":
            Ref r = self.resolve_path(obj)!;
            if (!r.hdr) {
                self.fail("isValid argument must be a header instance")!;
                unreachable("fail always faults");
            }
            return value_uint(self.alloc, r.hdr.valid ? 1 : 0);
        default:
            self.fail(string::tformat("unsupported method '%s' in v0", method))!;
            unreachable("fail always faults");
    }
}

// Copy n bytes from the packet at the cursor into the header instance,
// replacing its content (last-value-survives, docs/v0-subset.md §2.2);
// extract_end reuses this with n appended by the caller semantics below.
// This is the single place the ParserError/bounds rule lives.
fn void? Interp.extract_bytes(&self, HdrInst* hdr, sz n) {
    if (self.cursor + n > self.packet.len) {
        // Short packet: ParserError path -> reject.
        self.rejected = true;
        self.stopped = true;
        return;
    }
    hdr.data.clear();
    foreach (b : self.packet[self.cursor:n]) hdr.data.push(b);
    hdr.valid = true;
    self.cursor += n;
}

// extract_end semantics (docs/v0-subset.md §3.1): append n bytes to the
// current content; on an invalid header the content becomes exactly those
// bytes (which extract_bytes already produces for an empty instance).
fn void? Interp.extract_end_bytes(&self, HdrInst* hdr, sz n) {
    if (self.cursor + n > self.packet.len) {
        self.rejected = true;
        self.stopped = true;
        return;
    }
    if (!hdr.valid && hdr.data.len() == 0) {
        hdr.data.clear();
        foreach (b : self.packet[self.cursor:n]) hdr.data.push(b);
        hdr.valid = true;
        self.cursor += n;
        return;
    }
    foreach (b : self.packet[self.cursor:n]) hdr.data.push(b);
    hdr.valid = true;
    self.cursor += n;
}

// ---- Statement execution -------------------------------------------------

fn void? Interp.exec_stmt(&self, Stmt* stmt) {
    if (self.stopped) return;
    switch (stmt.kind) {
        case StmtKind.BLOCK:
            foreach (s : stmt.kids) self.exec_stmt(s)!;
        case StmtKind.VAR:
            LocalVar lv;
            lv.name = stmt.name;
            lv.bytes.init(self.alloc);
            if (stmt.type.kind == TypeKind.NAME) {
                Decl*? hdr = self.idx.find_header(stmt.type.name);
                if (catch hdr) {
                    // Not a header type; treat as opaque local below.
                } else {
                    lv.hdr_type = hdr;
                    for (sz i = 0; i < header_fixed_size(hdr); i++) lv.bytes.push(0);
                }
            }
            if (stmt.rhs) {
                Value v = self.eval(stmt.rhs)!;
                lv.bytes.clear();
                lv.bytes.push_all(v.bytes.array_view());
            } else if (!lv.hdr_type) {
                usz w = stmt.type.kind == TypeKind.BIT ? stmt.type.width / 8 : 8;
                for (usz i = 0; i < w; i++) lv.bytes.push(0);
            }
            foreach (&existing : self.locals) {
                if (existing.name == stmt.name) {
                    existing.bytes = lv.bytes;
                    existing.hdr_type = lv.hdr_type ? lv.hdr_type : existing.hdr_type;
                    return;
                }
            }
            self.locals.push(lv);
        case StmtKind.ASSIGN:
            Value v = self.eval(stmt.rhs)!;
            self.assign_to(stmt.lhs, v)!;
        case StmtKind.EXPR:
            (void)self.eval(stmt.rhs)!;
        case StmtKind.IF:
            Value c = self.eval(stmt.cond)!;
            if (value_truthy(&c)) {
                self.exec_stmt(stmt.kids[0])!;
            } else if (stmt.kids.len() > 1) {
                self.exec_stmt(stmt.kids[1])!;
            }
        case StmtKind.RETURN:
        case StmtKind.EXIT:
            self.stopped = true;
    }
}

// Assign a value to an lvalue: field slice, flat metadata field, or local.
fn void? Interp.assign_to(&self, Expr* lhs, Value v) {
    if (lhs.kind == ExprKind.IDENT) {
        foreach (&lv : self.locals) {
            if (lv.name == lhs.token.text) {
                lv.bytes.clear();
                lv.bytes.push_all(v.bytes.array_view());
                return;
            }
        }
        return self.fail(string::tformat("undefined name '%s'", lhs.token.text))!;
    }
    Ref r = self.resolve_path(lhs)!;
    if (!r.buf || !r.is_field) {
        return self.fail("assignment target must be a field or metadata member")!;
    }
    char[] b = v.bytes.array_view();
    if (r.field_width == 0) {
        // varbit field write: replace the content after the field offset
        while (r.buf.len() > r.field_off) (void)r.buf.pop();
        r.buf.push_all(b);
        return;
    }
    while (r.buf.len() < r.field_off + r.field_width) r.buf.push(0);
    for (sz i = 0; i < r.field_width; i++) {
        sz src = (sz)b.len - r.field_width + i;
        r.buf.set(r.field_off + i, src >= 0 ? b[src] : 0);
    }
}

// ---- Parser driver -------------------------------------------------------

fn void? Interp.run_parser(&self, Decl* parser) {
    self.bind_params(parser)!;
    ParserState* current = null;
    foreach (&s : parser.states) if (s.name == "start") current = s;
    if (!current) return self.fail(string::tformat("parser '%s' has no start state", parser.name))!;
    uint steps = 0;
    while (true) {
        if (++steps > 100000) return self.fail("parser step limit exceeded (runaway loop?)")!;
        foreach (s : current.body) self.exec_stmt(s)!;
        if (self.stopped) return;
        switch (current.transition.kind) {
            case TransitionKind.NAME:
                String t = current.transition.target;
                if (t == "accept") return;
                if (t == "reject") {
                    self.rejected = true;
                    self.stopped = true;
                    return;
                }
                ParserState* next = null;
                foreach (&s : parser.states) if (s.name == t) next = s;
                if (!next) return self.fail(string::tformat("undefined parser state '%s'", t))!;
                current = next;
            case TransitionKind.SELECT:
                Value key = self.eval_select_keys(&current.transition)!;
                String target = "";
                foreach (c : current.transition.cases) {
                    if (c.is_default) {
                        target = c.target;
                        break;
                    }
                    foreach (k : c.keys) {
                        Value kv = self.eval(k)!;
                        if (value_as_ulong(&kv) == value_as_ulong(&key)) {
                            target = c.target;
                            break;
                        }
                    }
                    if (target) break;
                }
                if (target.len == 0) {
                    // No select case matched: reject (ParserError path).
                    self.rejected = true;
                    self.stopped = true;
                    return;
                }
                if (target == "accept") return;
                if (target == "reject") {
                    self.rejected = true;
                    self.stopped = true;
                    return;
                }
                ParserState* next = null;
                foreach (&s : parser.states) if (s.name == target) next = s;
                if (!next) return self.fail(string::tformat("undefined parser state '%s'", target))!;
                current = next;
            default:
                return self.fail(string::tformat("state '%s' has no transition", current.name))!;
        }
    }
}

fn Value? Interp.eval_select_keys(&self, Transition* trans) {
    if (trans.select_keys.len() == 1) return self.eval(trans.select_keys[0])!;
    Value out = make_value(self.alloc);
    foreach (k : trans.select_keys) {
        Value v = self.eval(k)!;
        out.bytes.push_all(v.bytes.array_view());
    }
    return out;
}

// ---- Deparser driver -----------------------------------------------------
// 
// Straight-line emit sequence with guards (docs/v0-subset.md §2.3): output
// selection = valid ∧ guard per emit, order fixed by declaration sequence.

fn void? Interp.emit_ref(&self, Ref r) {
    if (r.stack) {
        foreach (&elem : r.stack) {
            if (elem.valid) self.out.push_all(elem.data.array_view());
        }
        return;
    }
    if (r.hdr) {
        if (r.hdr.valid) self.out.push_all(r.hdr.data.array_view());
        return;
    }
    return self.fail("emit argument must be a header instance or stack")!;
}

fn void? Interp.exec_dep_stmt(&self, Stmt* stmt, bool guarded, bool guard_value) {
    if (self.stopped) return;
    switch (stmt.kind) {
        case StmtKind.BLOCK:
            foreach (s : stmt.kids) self.exec_dep_stmt(s, guarded, guard_value)!;
        case StmtKind.EXPR:
            Expr* e = stmt.rhs;
            if (e.kind != ExprKind.CALL || e.kids[0].kind != ExprKind.MEMBER || e.kids[0].token.text != "emit") {
                (void)self.eval(e)!;
                return;
            }
            if (guarded && !guard_value) return;
            Ref r = self.resolve_path(e.kids[1])!;
            self.emit_ref(r)!;
        case StmtKind.IF:
            Value c = self.eval(stmt.cond)!;
            bool take = value_truthy(&c);
            if (guarded && !guard_value) take = false;
            // An if whose branches contain only emits folds into guarded
            // emits; other statements execute for their (disallowed by the
            // subset checker) side effects with the guard applied.
            if (stmt.kids.len() > 0) self.exec_dep_stmt(stmt.kids[0], true, take)!;
            if (stmt.kids.len() > 1) self.exec_dep_stmt(stmt.kids[1], true, !take && (!guarded || guard_value))!;
        case StmtKind.ASSIGN:
        case StmtKind.VAR:
            (void)self.exec_stmt(stmt)!;
        default:
            (void)self.exec_stmt(stmt)!;
    }
}

fn void? Interp.run_deparser(&self, Decl* deparser) {
    self.bind_params(deparser)!;
    foreach (s : deparser.apply) self.exec_dep_stmt(s, false, true)!;
    // Append the payload: everything past the parser cursor.
    self.out.push_all(self.packet[self.cursor..]);
}

// ---- Pipeline entry ------------------------------------------------------

struct RunOutcome {
    bool rejected;
    bool fatal;
    char[] output; // valid only when !rejected && !fatal
}

fn void? Interp.run_pipeline(&self, Decl* parser, List{Decl*}* controls, Decl* deparser) {
    self.run_parser(parser)!;
    if (self.rejected) return;
    self.stopped = false;
    foreach (c : *controls) {
        self.bind_params(c)!;
        foreach (s : c.apply) self.exec_stmt(s)!;
        self.stopped = false;
    }
    self.run_deparser(deparser)!;
}

fn RunOutcome run_reference(
    Allocator alloc,
    TypeIndex* idx,
    Program* program,
    char[] packet,
    String src_name,
    String* err_out
) {
    Interp interp;
    interp.alloc = alloc;
    interp.idx = idx;
    interp.prog = program;
    interp.src_name = src_name;
    interp.packet = packet;
    interp.roots.init(alloc);
    interp.locals.init(alloc);
    interp.binds.init(alloc);
    interp.out.init(alloc);

    Decl* parser = null;
    Decl* deparser = null;
    List{Decl*} controls;
    controls.init(alloc);
    foreach (d : program.decls) {
        switch (d.kind) {
            case DeclKind.PARSER:
                if (parser) {
                    *err_out = "multiple parsers in v0 program";
                    return { .fatal = true };
                }
                parser = d;
            case DeclKind.CONTROL:
                if (control_is_deparser(idx, d)) {
                    if (deparser) {
                        *err_out = "multiple deparsers in v0 program";
                        return { .fatal = true };
                    }
                    deparser = d;
                } else {
                    controls.push(d);
                }
            default:
        }
    }
    if (!parser) {
        *err_out = "v0 program needs a parser";
        return { .fatal = true };
    }
    if (!deparser) {
        *err_out = "v0 program needs a deparser (control with packet_out)";
        return { .fatal = true };
    }

    if (catch err = interp.run_pipeline(parser, &controls, deparser)) {
        *err_out = interp.err;
        return { .fatal = true };
    }
    if (interp.rejected) return { .rejected = true };
    return { .rejected = false, .output = interp.out.array_view() };
}
