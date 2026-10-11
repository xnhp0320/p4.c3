module p4c3;
import std::collections::list;

// Semantic index and v0-subset validation for the reference model.
// See docs/v0-subset.md §2: programs outside the subset must receive an
// explicit diagnostic, never silent degradation.

struct Diag {
    String filename;
    uint line;
    uint column;
    String msg;
}

struct DiagList {
    List{Diag} items;
}

fn void DiagList.init(&self, Allocator allocator) {
    self.items.init(allocator);
}

fn void DiagList.add(&self, Token tok, String msg) {
    self.items.push({ .line = tok.line, .column = tok.column, .msg = msg });
}

fn bool DiagList.has_errors(&self) {
    return self.items.len() > 0;
}

// ---- Program index ------------------------------------------------------

struct TypeIndex {
    List{Decl*} headers;
    List{Decl*} structs;
    List{Decl*} parsers;
    List{Decl*} controls;
    List{Decl*} consts;
}

fn void TypeIndex.init(&self, Allocator allocator) {
    self.headers.init(allocator);
    self.structs.init(allocator);
    self.parsers.init(allocator);
    self.controls.init(allocator);
    self.consts.init(allocator);
}

fn bool decl_in(List{Decl*}* list, Decl* decl) {
    foreach (d : *list) if (d == decl) return true;
    return false;
}

fn void TypeIndex.add_locals(&self, List{Decl*}* locals) {
    foreach (d : *locals) {
        switch (d.kind) {
            case HEADER:
                if (!decl_in(&self.headers, d)) self.headers.push(d);
            case STRUCT:
                if (!decl_in(&self.structs, d)) self.structs.push(d);
            case TYPEDEF:
                if (!decl_in(&self.structs, d)) self.structs.push(d);
            case CONST:
                if (!decl_in(&self.consts, d)) self.consts.push(d);
            default:
        }
    }
}

fn void TypeIndex.build(&self, Allocator allocator, Program* program) {
    self.init(allocator);
    foreach (d : program.decls) {
        switch (d.kind) {
            case HEADER:
                self.headers.push(d);
            case STRUCT:
            case TYPEDEF:
                self.structs.push(d);
            case PARSER:
                self.parsers.push(d);
                self.add_locals(&d.locals);
            case CONTROL:
                self.controls.push(d);
                self.add_locals(&d.locals);
            case CONST:
                self.consts.push(d);
            default:
        }
    }
}

fn Decl*? TypeIndex.find_header(&self, String name) {
    foreach (d : self.headers) if (d.name == name) return d;
    return NOT_FOUND~;
}

fn Decl*? TypeIndex.find_struct(&self, String name) {
    foreach (d : self.structs) if (d.name == name) return d;
    return NOT_FOUND~;
}

fn Decl*? TypeIndex.find_const(&self, String name) {
    foreach (d : self.consts) if (d.name == name) return d;
    return NOT_FOUND~;
}

fn Decl*? TypeIndex.find_parser_state(&self, Decl* parser, String name) {
    foreach (s : parser.states) if (s.name == name) return parser;
    return NOT_FOUND~;
}

excuse NOT_FOUND;

// ---- Layout helpers -----------------------------------------------------
// 
// v0 is byte-oriented: header fixed size and field offsets are whole bytes.

// Fixed size in bytes: sum of bit<W> fields / 8. varbit fields contribute 0.
fn sz header_fixed_size(Decl* header) {
    sz size = 0;
    foreach (f : header.fields) {
        if (f.type.kind == TypeKind.BIT) size += f.type.width / 8;
    }
    return size;
}

// Byte offset of a field within the fixed part. varbit fields sit at the end
// of the fixed part; their content starts at the fixed size.
fn sz? header_field_offset(Decl* header, String field_name, sz* width_bytes) {
    sz off = 0;
    foreach (f : header.fields) {
        if (f.name == field_name) {
            *width_bytes = f.type.kind == TypeKind.BIT ? (sz)f.type.width / 8 : 0;
            return off;
        }
        if (f.type.kind == TypeKind.BIT) off += (sz)f.type.width / 8;
    }
    return NOT_FOUND~;
}

// Is this TypeRef a header stack (NAME type with [N])?
fn bool is_stack_type(TypeRef* type) {
    return type.kind == TypeKind.NAME && type.stack_size > 0;
}

fn Decl*? resolve_member_type(TypeIndex* idx, Decl* struct_decl, String member) {
    foreach (f : struct_decl.fields) {
        if (f.name == member) {
            if (f.type.kind != TypeKind.NAME) return NOT_FOUND~;
            Decl*? header = idx.find_header(f.type.name);
            if (catch header) {
                Decl*? sub = idx.find_struct(f.type.name);
                if (catch sub) return NOT_FOUND~;
                return sub;
            }
            return header;
        }
    }
    return NOT_FOUND~;
}

// ---- v0 subset validation -----------------------------------------------

struct SubsetChecker {
    TypeIndex* idx;
    DiagList* diags;
    String filename;
    List{String} emitted; // deparser instance paths, for duplicate-emit check
}

fn bool type_is_headers_root(SubsetChecker* checker, TypeRef* type) {
    if (type.kind != TypeKind.NAME) return false;
    if (catch d = checker.idx.find_struct(type.name)) return true;
    if (catch d = checker.idx.find_header(type.name)) return true;
    return false;
}

fn void SubsetChecker.check_program(&self, Program* program) {
    foreach (d : program.decls) {
        switch (d.kind) {
            case HEADER:
                self.check_header(d);
            case STRUCT:
                self.check_struct(d);
            case PARSER:
                self.check_parser(d);
            case CONTROL:
                self.check_control(d);
            case ACTION:
            case TABLE:
                self.diags.add(d.token, string::tformat("'%s': actions and tables are outside the v0 subset", d.name));
            default:
        }
    }
}

fn void SubsetChecker.check_header(&self, Decl* header) {
    foreach (f : header.fields) {
        if (f.type.kind == TypeKind.BIT) {
            if (f.type.width == 0 || f.type.width % 8 != 0) {
                self.diags.add(
                    f.token,
                    string::tformat(
                        "header '%s': field '%s' bit<%d> is not byte-aligned, v0 requires widths that are multiples of 8",
                        header.name,
                        f.name,
                        f.type.width
                    )
                );
            }
            continue;
        }
        if (f.type.kind == TypeKind.VARBIT) continue;
        self.diags.add(
            f.token,
            string::tformat(
                "header '%s': field '%s' has unsupported type, v0 headers allow only bit<W> (W multiple of 8) and varbit<W>",
                header.name,
                f.name
            )
        );
    }
}

fn void SubsetChecker.check_struct(&self, Decl* struct_decl) {
    foreach (f : struct_decl.fields) {
        if (f.type.kind == TypeKind.NAME) continue;
        if (f.type.kind == TypeKind.BIT && f.type.width % 8 == 0) continue;
        self.diags.add(
            f.token,
            string::tformat(
                "struct '%s': member '%s' has type outside the v0 subset (only byte-aligned bit<W> and header instances)",
                struct_decl.name,
                f.name
            )
        );
    }
}

fn bool expr_is_packet_method(Expr* expr, String method) {
    if (expr.kind != ExprKind.CALL) return false;
    Expr* callee = expr.kids[0];
    if (callee.kind != ExprKind.MEMBER) return false;
    return callee.token.text == method;
}

// The member path text of `a.b.c` (for diagnostics and duplicate-emit keys).
fn void expr_path(Expr* expr, List{char}* buf) {
    if (expr.kind == ExprKind.MEMBER) {
        expr_path(expr.kids[0], buf);
        buf.push('.');
        buf.push_all(expr.token.text);
        return;
    }
    if (expr.kind == ExprKind.IDENT) {
        buf.push_all(expr.token.text);
        return;
    }
    if (expr.kind == ExprKind.INDEX) {
        expr_path(expr.kids[0], buf);
        buf.push('[');
        buf.push('i');
        buf.push(']');
        return;
    }
    buf.push('?');
}

// Whitelisted parser-side method calls.
fn bool parser_call_allowed(Expr* call) {
    if (call.kind != ExprKind.CALL) return false;
    Expr* callee = call.kids[0];
    if (callee.kind != ExprKind.MEMBER) return false;
    String m = callee.token.text;
    return m == "extract" || m == "extract_end" || m == "lookahead" || m == "setValid" || m == "setInvalid"
        || m == "isValid";
}

fn void SubsetChecker.check_stmt_list(&self, List{Stmt*}* body, bool in_deparser, Decl* control) {
    foreach (s : *body) {
        self.check_stmt(s, in_deparser, control);
    }
}

fn Token stmt_token(Stmt* stmt) {
    if (stmt.rhs) return stmt.rhs.token;
    if (stmt.lhs) return stmt.lhs.token;
    if (stmt.cond) return stmt.cond.token;
    return { .line = 1, .column = 1 };
}

fn void SubsetChecker.check_stmt(&self, Stmt* stmt, bool in_deparser, Decl* control) {
    switch (stmt.kind) {
        case BLOCK:
            self.check_stmt_list(&stmt.kids, in_deparser, control);
        case IF:
        case ASSIGN:
        case VAR:
        case EXPR:
            if (stmt.kind == StmtKind.EXPR) {
                Expr* e = stmt.rhs;
                if (e.kind == ExprKind.CALL) {
                    if (in_deparser) {
                        self.check_emit_call(e, control);
                    } else if (!parser_call_allowed(e)) {
                        self.diags.add(
                            e.token,
                            string::tformat(
                                "control '%s': only packet.extract/extract_end/lookahead and header setValid/setInvalid/isValid calls are in the v0 subset",
                                control.name
                            )
                        );
                    }
                }
            }
        case RETURN:
            if (in_deparser) self.diags.add(
                stmt_token(stmt),
                string::tformat(
                    "deparser '%s': return is outside the v0 deparser subset (straight-line emit sequence)",
                    control.name
                )
            );
        case EXIT:
            self.diags.add(stmt_token(stmt), string::tformat("'%s': exit is outside the v0 subset", control.name));
    }
}

fn void SubsetChecker.check_emit_call(&self, Expr* call, Decl* control) {
    Expr* callee = call.kids[0];
    if (callee.kind != ExprKind.MEMBER || callee.token.text != "emit") {
        self.diags.add(
            call.token,
            string::tformat(
                "deparser '%s': only emit calls, guarded emits, and assignments are allowed in the v0 deparser",
                control.name
            )
        );
        return;
    }
    if (call.kids.len() != 2) {
        self.diags.add(call.token, "emit takes exactly one argument");
        return;
    }
    // Duplicate emit of the same instance is unsupported (value-version modeling).
    List{char} path;
    path.init(tmem);
    expr_path(call.kids[1], &path);
    String key = (String)path.array_view();
    foreach (prev : self.emitted) {
        if (prev == key) {
            self.diags.add(
                call.token,
                string::tformat(
                    "deparser '%s': instance '%s' is emitted more than once, which requires value-version modeling outside the v0 subset",
                    control.name,
                    key
                )
            );
            return;
        }
    }
    self.emitted.push(key);
}

fn bool control_is_deparser(TypeIndex* idx, Decl* control) {
    foreach (p : control.params) {
        if (p.type.kind == TypeKind.NAME && p.type.name == "packet_out") return true;
    }
    return false;
}

fn void SubsetChecker.check_control(&self, Decl* control) {
    bool deparser = control_is_deparser(self.idx, control);
    if (deparser) self.emitted.clear();
    foreach (t : control.tables) {
        self.diags.add(
            t.token,
            string::tformat("control '%s': table '%s' is outside the v0 subset", control.name, t.name)
        );
    }
    self.check_stmt_list(&control.apply, deparser, control);
}

fn void SubsetChecker.check_parser(&self, Decl* parser) {
    foreach (state : parser.states) {
        foreach (s : state.body) {
            self.check_stmt(s, false, parser);
        }
        switch (state.transition.kind) {
            case NAME:
                String t = state.transition.target;
                if (t != "accept" && t != "reject") {
                    bool found = false;
                    foreach (other : parser.states) if (other.name == t) found = true;
                    if (!found) self.diags.add(
                        state.token,
                        string::tformat("parser '%s': transition to undefined state '%s'", parser.name, t)
                    );
                }
            case SELECT:
                foreach (c : state.transition.cases) {
                    if (c.is_default) continue;
                    bool found = false;
                    foreach (other : parser.states) if (other.name == c.target) found = true;
                    if (c.target == "accept" || c.target == "reject") found = true;
                    if (!found) self.diags.add(
                        state.token,
                        string::tformat("parser '%s': select case to undefined state '%s'", parser.name, c.target)
                    );
                }
            default:
                self.diags.add(
                    state.token,
                    string::tformat("parser '%s': state '%s' has no transition", parser.name, state.name)
                );
        }
    }
}
