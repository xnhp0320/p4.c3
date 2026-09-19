module p4c3;
import std::io;
import std::collections::list;

fn void pad(int indent) {
	for (int i = 0; i < indent; i++) io::print("  ");
}

fn void dump_type(TypeRef type) {
	switch (type.kind) {
		case BIT:
			io::printf("bit<%d>", type.width);
		case INT:
			io::printf("int<%d>", type.width);
		case VARBIT:
			io::printf("varbit<%d>", type.width);
		case BOOL:
			io::print("bool");
		case VOID:
			io::print("void");
		case ERROR:
			io::print("error");
		case NAME:
			io::print(type.name);
	}
	if (type.stack_size) {
		io::printf("[%d]", type.stack_size);
	}
}

fn void dump_expr(Expr* expr) {
	if (!expr) {
		io::print("<null>");
		return;
	}
	switch (expr.kind) {
		case IDENT:
		case NUMBER:
			io::print(expr.token.text);
		case STR:
			io::print(expr.token.text);
		case MEMBER:
			dump_expr(expr.kids[0]);
			io::printf(".%s", expr.token.text);
		case INDEX:
			dump_expr(expr.kids[0]);
			io::print("[");
			dump_expr(expr.kids[1]);
			io::print("]");
		case CALL:
			dump_expr(expr.kids[0]);
			io::print("(");
			for (sz i = 1; i < expr.kids.len(); i++) {
				if (i > 1) io::print(", ");
				dump_expr(expr.kids[i]);
			}
			io::print(")");
		case UNARY:
			io::print(expr.token.text);
			dump_expr(expr.kids[0]);
		case BINARY:
			io::print("(");
			dump_expr(expr.kids[0]);
			io::printf(" %s ", expr.token.text);
			dump_expr(expr.kids[1]);
			io::print(")");
		case TUPLE:
			io::print("(");
			foreach (i, kid : expr.kids) {
				if (i > 0) io::print(", ");
				dump_expr(kid);
			}
			io::print(")");
	}
}

fn void dump_stmt(Stmt* stmt, int indent) {
	pad(indent);
	switch (stmt.kind) {
		case BLOCK:
			io::printn("{");
			foreach (kid : stmt.kids) dump_stmt(kid, indent + 1);
			pad(indent);
			io::printn("}");
		case ASSIGN:
			dump_expr(stmt.lhs);
			io::print(" = ");
			dump_expr(stmt.rhs);
			io::printn(";");
		case EXPR:
			dump_expr(stmt.rhs);
			io::printn(";");
		case IF:
			io::print("if (");
			dump_expr(stmt.cond);
			io::printn(")");
			if (stmt.kids.len() > 0) dump_stmt(stmt.kids[0], indent + 1);
			if (stmt.kids.len() > 1) {
				pad(indent);
				io::printn("else");
				dump_stmt(stmt.kids[1], indent + 1);
			}
		case RETURN:
			io::print("return");
			if (stmt.rhs) {
				io::print(" ");
				dump_expr(stmt.rhs);
			}
			io::printn(";");
		case EXIT:
			io::printn("exit;");
		case VAR:
			dump_type(stmt.type);
			io::printf(" %s", stmt.name);
			if (stmt.rhs) {
				io::print(" = ");
				dump_expr(stmt.rhs);
			}
			io::printn(";");
	}
}

fn void dump_params(List{ParamDecl} params) {
	io::print("(");
	foreach (i, p : params) {
		if (i > 0) io::print(", ");
		if (p.direction.len) io::printf("%s ", p.direction);
		dump_type(p.type);
		io::printf(" %s", p.name);
	}
	io::print(")");
}

fn void dump_action(ActionDecl action, int indent) {
	pad(indent);
	io::printf("action %s", action.name);
	dump_params(action.params);
	io::printn(" {");
	foreach (s : action.body) dump_stmt(s, indent + 1);
	pad(indent);
	io::printn("}");
}

fn void dump_table(TableDecl table, int indent) {
	pad(indent);
	io::printfn("table %s {", table.name);
	if (table.keys.len()) {
		pad(indent + 1);
		io::printn("key = {");
		foreach (k : table.keys) {
			pad(indent + 2);
			dump_expr(k.expr);
			io::printfn(": %s;", k.match_kind);
		}
		pad(indent + 1);
		io::printn("}");
	}
	if (table.actions.len()) {
		pad(indent + 1);
		io::printn("actions = {");
		foreach (a : table.actions) {
			pad(indent + 2);
			io::print(a.name);
			if (a.has_args) {
				io::print("(");
				foreach (i, arg : a.args) {
					if (i > 0) io::print(", ");
					dump_expr(arg);
				}
				io::print(")");
			}
			io::printn(";");
		}
		pad(indent + 1);
		io::printn("}");
	}
	if (table.size) {
		pad(indent + 1);
		io::print("size = ");
		dump_expr(table.size);
		io::printn(";");
	}
	if (table.has_default) {
		pad(indent + 1);
		io::printf("default_action = %s", table.default_action.name);
		if (table.default_action.has_args) {
			io::print("(");
			foreach (i, arg : table.default_action.args) {
				if (i > 0) io::print(", ");
				dump_expr(arg);
			}
			io::print(")");
		}
		io::printn(";");
	}
	pad(indent);
	io::printn("}");
}

fn void dump_decl(Decl* decl, int indent) {
	pad(indent);
	switch (decl.kind) {
		case HEADER:
			io::printfn("header %s {", decl.name);
			foreach (f : decl.fields) {
				pad(indent + 1);
				dump_type(f.type);
				io::printfn(" %s;", f.name);
			}
			pad(indent);
			io::printn("}");
		case STRUCT:
			io::printfn("struct %s {", decl.name);
			foreach (f : decl.fields) {
				pad(indent + 1);
				dump_type(f.type);
				io::printfn(" %s;", f.name);
			}
			pad(indent);
			io::printn("}");
		case TYPEDEF:
			io::print("typedef ");
			dump_type(decl.type);
			io::printfn(" %s;", decl.name);
		case CONST:
			io::print("const ");
			dump_type(decl.type);
			io::printf(" %s = ", decl.name);
			dump_expr(decl.value);
			io::printn(";");
		case ENUM:
			io::printfn("enum %s {", decl.name);
			foreach (m : decl.enum_members) {
				pad(indent + 1);
				io::printfn("%s,", m);
			}
			pad(indent);
			io::printn("}");
		case PARSER:
			io::printf("parser %s", decl.name);
			dump_params(decl.params);
			io::printn(" {");
			foreach (st : decl.states) {
				pad(indent + 1);
				io::printfn("state %s {", st.name);
				foreach (s : st.body) dump_stmt(s, indent + 2);
				if (st.transition.kind == NAME) {
					pad(indent + 2);
					io::printfn("transition %s;", st.transition.target);
				} else if (st.transition.kind == SELECT) {
					pad(indent + 2);
					io::print("transition select(");
					foreach (i, key : st.transition.select_keys) {
						if (i > 0) io::print(", ");
						dump_expr(key);
					}
					io::printn(") {");
					foreach (c : st.transition.cases) {
						pad(indent + 3);
						if (c.is_default) {
							io::print("default");
						} else {
							foreach (i, key : c.keys) {
								if (i > 0) io::print(", ");
								dump_expr(key);
							}
						}
						io::printfn(": %s;", c.target);
					}
					pad(indent + 2);
					io::printn("}");
				}
				pad(indent + 1);
				io::printn("}");
			}
			pad(indent);
			io::printn("}");
		case CONTROL:
			io::printf("control %s", decl.name);
			dump_params(decl.params);
			io::printn(" {");
			foreach (a : decl.actions) dump_action(a, indent + 1);
			foreach (t : decl.tables) dump_table(t, indent + 1);
			foreach (local : decl.locals) dump_decl(local, indent + 1);
			pad(indent + 1);
			io::printn("apply {");
			foreach (s : decl.apply) dump_stmt(s, indent + 2);
			pad(indent + 1);
			io::printn("}");
			pad(indent);
			io::printn("}");
		case ACTION:
			dump_action(decl.action, indent);
		case TABLE:
			dump_table(decl.table, indent);
	}
}

fn void dump_program(Program* program) {
	foreach (d : program.decls) {
		dump_decl(d, 0);
		io::printn("");
	}
	io::printfn("// %d top-level declaration%s", program.decls.len(),
		program.decls.len() == 1 ? "" : "s");
}
