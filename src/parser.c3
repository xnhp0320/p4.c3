module p4c3;
import std::io;
import std::io::file;
import std::collections::list;

struct Parser {
	String filename;
	List{Token} tokens;
	sz pos;
	Allocator allocator;
	bool had_error;
	String error_msg;
	Token error_tok;
}

fn Parser parser_create(Allocator allocator, String filename, List{Token} tokens) {
	Parser p;
	p.filename = filename;
	p.tokens = tokens;
	p.pos = 0;
	p.allocator = allocator;
	return p;
}

fn Token Parser.peek(&self) {
	if (self.pos >= self.tokens.len()) return self.tokens[self.tokens.len() - 1];
	return self.tokens[self.pos];
}

fn Token Parser.peek_at(&self, sz offset) {
	sz i = self.pos + offset;
	if (i >= self.tokens.len()) return self.tokens[self.tokens.len() - 1];
	return self.tokens[i];
}

fn Token Parser.advance(&self) {
	Token t = self.peek();
	if (t.kind != END) self.pos++;
	return t;
}

fn bool Parser.check(&self, TokenKind kind) {
	return self.peek().kind == kind;
}

fn bool Parser.check_kw(&self, String name) {
	return self.peek().is_kw(name);
}

fn void? Parser.fail(&self, String msg) {
	if (!self.had_error) {
		self.had_error = true;
		self.error_msg = msg;
		self.error_tok = self.peek();
	}
	return PARSE_FAILED~;
}

fn void Parser.report(&self) {
	Token t = self.error_tok;
	String got = t.kind == END ? "end of file" : (t.text.len ? t.text : t.kind.label());
	io::eprintfn("%s:%d:%d: error: %s (got %s)", self.filename, t.line, t.column, self.error_msg, got);
}

fn void? Parser.expect(&self, TokenKind kind) {
	if (!self.check(kind)) {
		self.fail(string::tformat("expected %s", kind.label()))!;
	}
	self.advance();
}

fn String? Parser.expect_ident(&self) {
	if (!self.check(IDENT)) self.fail("expected identifier")!;
	return self.advance().text;
}

fn Expr* Parser.new_expr(&self, ExprKind kind, Token token) {
	Expr* expr = alloc::new(self.allocator, Expr);
	expr.kind = kind;
	expr.token = token;
	expr.kids.init(self.allocator, 4);
	return expr;
}

fn Stmt* Parser.new_stmt(&self, StmtKind kind) {
	Stmt* stmt = alloc::new(self.allocator, Stmt);
	stmt.kind = kind;
	stmt.kids.init(self.allocator, 4);
	return stmt;
}

fn Decl* Parser.new_decl(&self, DeclKind kind, String name) {
	Decl* decl = alloc::new(self.allocator, Decl);
	decl.kind = kind;
	decl.name = name;
	decl.fields.init(self.allocator);
	decl.params.init(self.allocator);
	decl.states.init(self.allocator);
	decl.actions.init(self.allocator);
	decl.tables.init(self.allocator);
	decl.apply.init(self.allocator);
	decl.enum_members.init(self.allocator);
	decl.locals.init(self.allocator);
	return decl;
}

fn void? Parser.skip_balanced(&self, TokenKind open, TokenKind close) {
	self.expect(open)!;
	int depth = 1;
	while (depth > 0) {
		Token t = self.peek();
		if (t.kind == END) self.fail("unclosed delimiter")!;
		self.advance();
		if (t.kind == open) {
			depth++;
		} else if (t.kind == close) {
			depth--;
		}
	}
}

fn void? Parser.skip_type_args(&self) {
	if (!self.check(LT)) return;
	self.advance();
	int depth = 1;
	while (depth > 0) {
		Token t = self.peek();
		if (t.kind == END) self.fail("unclosed type argument list")!;
		self.advance();
		if (t.kind == LT) {
			depth++;
		} else if (t.kind == GT) {
			depth--;
		} else if (t.kind == RSHIFT) {
			depth -= 2;
			if (depth < 0) self.fail("mismatched '>'")!;
		}
	}
}

fn bool Parser.looks_like_call_type_args(&self) {
	if (!self.check(LT)) return false;
	sz i = 1;
	int depth = 1;
	while (depth > 0 && i < 64) {
		Token t = self.peek_at(i);
		if (t.kind == END) return false;
		if (t.kind == LT) {
			depth++;
		} else if (t.kind == GT) {
			depth--;
		} else if (t.kind == RSHIFT) {
			depth -= 2;
		}
		i++;
	}
	if (depth > 0) return false;
	return self.peek_at(i).kind == LPAREN;
}

fn void? Parser.skip_annotations(&self) {
	while (self.check(AT)) {
		self.advance();
		if (self.check(IDENT)) self.advance();
		if (self.check(LPAREN)) self.skip_balanced(LPAREN, RPAREN)!;
	}
}

fn bool Parser.at_type_name(&self) {
	if (!self.check(IDENT)) return false;
	String s = self.peek().text;
	return s == "bit" || s == "int" || s == "varbit" || s == "bool"
		|| s == "void" || s == "error" || s == "string";
}

fn bool Parser.try_consume_type(&self) {
	if (!self.check(IDENT)) return false;
	String s = self.peek().text;
	self.advance();
	if (s == "bit" || s == "int" || s == "varbit") {
		if (!self.check(LT)) return false;
		self.advance();
		if (!self.check(INTEGER)) return false;
		self.advance();
		if (!self.check(GT)) return false;
		self.advance();
	} else {
		if (self.check(LT)) {
			sz saved = self.pos;
			if (catch self.skip_type_args()) {
				self.pos = saved;
				self.had_error = false;
				return false;
			}
		}
	}
	if (self.check(LBRACK)) {
		self.advance();
		if (!self.check(INTEGER) && !self.check(IDENT)) return false;
		self.advance();
		if (!self.check(RBRACK)) return false;
		self.advance();
	}
	return true;
}

fn bool Parser.looks_like_var_decl(&self) {
	sz saved = self.pos;
	bool ok = self.try_consume_type() && self.check(IDENT);
	self.pos = saved;
	return ok;
}

fn TypeRef? Parser.parse_type(&self) {
	if (!self.check(IDENT)) self.fail("expected type")!;
	Token t = self.advance();
	TypeRef ty;
	ty.name = t.text;
	if (t.text == "bit" || t.text == "int" || t.text == "varbit") {
		if (t.text == "bit") {
			ty.kind = BIT;
		} else if (t.text == "int") {
			ty.kind = INT;
		} else {
			ty.kind = VARBIT;
		}
		self.expect(LT)!;
		if (!self.check(INTEGER)) self.fail("expected bit width")!;
		Token w = self.advance();
		ty.width = w.text.to_uint() ?? 0;
		self.expect(GT)!;
	} else if (t.text == "bool") {
		ty.kind = BOOL;
	} else if (t.text == "void") {
		ty.kind = VOID;
	} else if (t.text == "error") {
		ty.kind = ERROR;
	} else {
		ty.kind = NAME;
		self.skip_type_args()!;
	}
	if (self.check(LBRACK)) {
		self.advance();
		if (!self.check(INTEGER)) self.fail("expected stack size")!;
		Token n = self.advance();
		ty.stack_size = n.text.to_uint() ?? 0;
		self.expect(RBRACK)!;
	}
	return ty;
}

fn Expr*? Parser.parse_args(&self, Expr* call) {
	self.expect(LPAREN)!;
	if (!self.check(RPAREN)) {
		while (true) {
			call.kids.push(self.parse_expr()!);
			if (!self.check(COMMA)) break;
			self.advance();
		}
	}
	self.expect(RPAREN)!;
	return call;
}

fn Expr*? Parser.parse_primary(&self) {
	Token t = self.peek();
	if (t.kind == IDENT) {
		self.advance();
		return self.new_expr(IDENT, t);
	}
	if (t.kind == INTEGER) {
		self.advance();
		return self.new_expr(NUMBER, t);
	}
	if (t.kind == STR) {
		self.advance();
		return self.new_expr(STR, t);
	}
	if (t.kind == LPAREN) {
		self.advance();
		Expr* first = self.parse_expr()!;
		if (self.check(COMMA)) {
			Expr* tuple = self.new_expr(TUPLE, t);
			tuple.kids.push(first);
			while (self.check(COMMA)) {
				self.advance();
				if (self.check(RPAREN)) break;
				tuple.kids.push(self.parse_expr()!);
			}
			self.expect(RPAREN)!;
			return tuple;
		}
		self.expect(RPAREN)!;
		return first;
	}
	self.fail("expected expression")!;
	return PARSE_FAILED~;
}

fn Expr*? Parser.parse_postfix(&self) {
	Expr* expr = self.parse_primary()!;
	while (true) {
		if (self.check(DOT)) {
			self.advance();
			if (!self.check(IDENT)) self.fail("expected member name")!;
			Token name = self.advance();
			Expr* member = self.new_expr(MEMBER, name);
			member.kids.push(expr);
			expr = member;
			continue;
		}
		if (self.check(LBRACK)) {
			Token tok = self.advance();
			Expr* index = self.new_expr(INDEX, tok);
			index.kids.push(expr);
			index.kids.push(self.parse_expr()!);
			self.expect(RBRACK)!;
			expr = index;
			continue;
		}
		if (self.looks_like_call_type_args()) {
			self.skip_type_args()!;
			Expr* call = self.new_expr(CALL, expr.token);
			call.kids.push(expr);
			expr = self.parse_args(call)!;
			continue;
		}
		if (self.check(LPAREN)) {
			Expr* call = self.new_expr(CALL, expr.token);
			call.kids.push(expr);
			expr = self.parse_args(call)!;
			continue;
		}
		break;
	}
	return expr;
}

fn Expr*? Parser.parse_unary(&self) {
	Token t = self.peek();
	if (t.kind == BANG || t.kind == TILDE || t.kind == MINUS || t.kind == PLUS) {
		self.advance();
		Expr* expr = self.new_expr(UNARY, t);
		expr.kids.push(self.parse_unary()!);
		return expr;
	}
	return self.parse_postfix();
}

fn Expr*? Parser.parse_binop(&self, int prec) {
	if (prec == 0) return self.parse_unary();
	Expr* left = self.parse_binop(prec - 1)!;
	while (true) {
		Token op = self.peek();
		int p = -1;
		switch (op.kind) {
			case STAR:
			case SLASH:
			case PERCENT:
				p = 1;
			case PLUS:
			case MINUS:
				p = 2;
			case LSHIFT:
			case RSHIFT:
				p = 3;
			case LT:
			case GT:
			case LE:
			case GE:
				p = 4;
			case EQEQ:
			case NEQ:
				p = 5;
			case AMP:
				p = 6;
			case CARET:
				p = 7;
			case PIPE:
				p = 8;
			case MASKAND:
				p = 9;
			case ANDAND:
				p = 10;
			case OROR:
				p = 11;
			default:
				p = -1;
		}
		if (p != prec) break;
		self.advance();
		Expr* right = self.parse_binop(prec - 1)!;
		Expr* bin = self.new_expr(BINARY, op);
		bin.kids.push(left);
		bin.kids.push(right);
		left = bin;
	}
	return left;
}

fn Expr*? Parser.parse_expr(&self) {
	return self.parse_binop(11);
}

fn ParamDecl? Parser.parse_param(&self) {
	ParamDecl p;
	if (self.check_kw("in") || self.check_kw("out") || self.check_kw("inout")) {
		p.direction = self.advance().text;
	}
	p.type = self.parse_type()!;
	p.name = self.expect_ident()!;
	return p;
}

fn void? Parser.parse_param_list(&self, List{ParamDecl}* params) {
	self.expect(LPAREN)!;
	if (!self.check(RPAREN)) {
		while (true) {
			params.push(self.parse_param()!);
			if (!self.check(COMMA)) break;
			self.advance();
		}
	}
	self.expect(RPAREN)!;
}

fn void? Parser.parse_field_list(&self, List{FieldDecl}* fields) {
	self.expect(LBRACE)!;
	while (!self.check(RBRACE) && !self.check(END)) {
		self.skip_annotations()!;
		if (self.check(RBRACE)) break;
		FieldDecl field;
		field.type = self.parse_type()!;
		field.name = self.expect_ident()!;
		self.expect(SEMI)!;
		fields.push(field);
	}
	self.expect(RBRACE)!;
}

fn Stmt*? Parser.parse_block(&self) {
	Stmt* stmt = self.new_stmt(BLOCK);
	self.expect(LBRACE)!;
	while (!self.check(RBRACE) && !self.check(END)) {
		stmt.kids.push(self.parse_stmt()!);
	}
	self.expect(RBRACE)!;
	return stmt;
}

fn Stmt*? Parser.parse_stmt(&self) {
	self.skip_annotations()!;
	if (self.check(LBRACE)) return self.parse_block();
	if (self.check_kw("if")) {
		self.advance();
		Stmt* stmt = self.new_stmt(IF);
		self.expect(LPAREN)!;
		stmt.cond = self.parse_expr()!;
		self.expect(RPAREN)!;
		stmt.kids.push(self.parse_stmt()!);
		if (self.check_kw("else")) {
			self.advance();
			stmt.kids.push(self.parse_stmt()!);
		}
		return stmt;
	}
	if (self.check_kw("return")) {
		self.advance();
		Stmt* stmt = self.new_stmt(RETURN);
		if (!self.check(SEMI)) stmt.rhs = self.parse_expr()!;
		self.expect(SEMI)!;
		return stmt;
	}
	if (self.check_kw("exit")) {
		self.advance();
		self.expect(SEMI)!;
		return self.new_stmt(EXIT);
	}
	if (self.looks_like_var_decl()) {
		Stmt* stmt = self.new_stmt(VAR);
		stmt.type = self.parse_type()!;
		stmt.name = self.expect_ident()!;
		if (self.check(EQ)) {
			self.advance();
			stmt.rhs = self.parse_expr()!;
		}
		self.expect(SEMI)!;
		return stmt;
	}
	Expr* expr = self.parse_expr()!;
	if (self.check(EQ)) {
		self.advance();
		Stmt* stmt = self.new_stmt(ASSIGN);
		stmt.lhs = expr;
		stmt.rhs = self.parse_expr()!;
		self.expect(SEMI)!;
		return stmt;
	}
	Stmt* stmt = self.new_stmt(EXPR);
	stmt.rhs = expr;
	self.expect(SEMI)!;
	return stmt;
}

fn void? Parser.parse_transition(&self, Transition* trans) {
	self.expect_ident()!; // "transition"
	if (self.check_kw("select")) {
		self.advance();
		trans.kind = SELECT;
		trans.select_keys.init(self.allocator);
		trans.cases.init(self.allocator);
		self.expect(LPAREN)!;
		while (true) {
			trans.select_keys.push(self.parse_expr()!);
			if (!self.check(COMMA)) break;
			self.advance();
		}
		self.expect(RPAREN)!;
		self.expect(LBRACE)!;
		while (!self.check(RBRACE) && !self.check(END)) {
			SelectCase c;
			c.keys.init(self.allocator);
			if (self.check_kw("default")) {
				self.advance();
				c.is_default = true;
			} else {
				c.keys.push(self.parse_expr()!);
				while (self.check(COMMA)) {
					self.advance();
					c.keys.push(self.parse_expr()!);
				}
			}
			self.expect(COLON)!;
			c.target = self.expect_ident()!;
			self.expect(SEMI)!;
			trans.cases.push(c);
		}
		self.expect(RBRACE)!;
		return;
	}
	trans.kind = NAME;
	trans.target = self.expect_ident()!;
	self.expect(SEMI)!;
}

fn ParserState? Parser.parse_state(&self) {
	ParserState state;
	state.body.init(self.allocator);
	self.advance(); // state
	state.name = self.expect_ident()!;
	self.expect(LBRACE)!;
	while (!self.check(RBRACE) && !self.check(END)) {
		self.skip_annotations()!;
		if (self.check_kw("transition")) {
			self.parse_transition(&state.transition)!;
			continue;
		}
		state.body.push(self.parse_stmt()!);
	}
	self.expect(RBRACE)!;
	return state;
}

fn ActionDecl? Parser.parse_action(&self) {
	ActionDecl action;
	action.params.init(self.allocator);
	action.body.init(self.allocator);
	self.advance(); // action
	action.name = self.expect_ident()!;
	self.parse_param_list(&action.params)!;
	Stmt* block = self.parse_block()!;
	foreach (s : block.kids) action.body.push(s);
	return action;
}

fn void? Parser.parse_action_ref(&self, ActionRef* ref) {
	ref.name = self.expect_ident()!;
	ref.args.init(self.allocator);
	if (self.check(LPAREN)) {
		ref.has_args = true;
		self.advance();
		if (!self.check(RPAREN)) {
			while (true) {
				ref.args.push(self.parse_expr()!);
				if (!self.check(COMMA)) break;
				self.advance();
			}
		}
		self.expect(RPAREN)!;
	}
}

fn TableDecl? Parser.parse_table(&self) {
	TableDecl table;
	table.keys.init(self.allocator);
	table.actions.init(self.allocator);
	self.advance(); // table
	table.name = self.expect_ident()!;
	self.expect(LBRACE)!;
	while (!self.check(RBRACE) && !self.check(END)) {
		self.skip_annotations()!;
		if (self.check(RBRACE)) break;
		if (self.check_kw("key")) {
			self.advance();
			self.expect(EQ)!;
			self.expect(LBRACE)!;
			while (!self.check(RBRACE) && !self.check(END)) {
				KeyElem key;
				key.expr = self.parse_expr()!;
				self.expect(COLON)!;
				key.match_kind = self.expect_ident()!;
				self.expect(SEMI)!;
				table.keys.push(key);
			}
			self.expect(RBRACE)!;
			continue;
		}
		if (self.check_kw("actions")) {
			self.advance();
			self.expect(EQ)!;
			self.expect(LBRACE)!;
			while (!self.check(RBRACE) && !self.check(END)) {
				ActionRef ref;
				self.parse_action_ref(&ref)!;
				self.expect(SEMI)!;
				table.actions.push(ref);
			}
			self.expect(RBRACE)!;
			continue;
		}
		if (self.check_kw("size")) {
			self.advance();
			self.expect(EQ)!;
			table.size = self.parse_expr()!;
			self.expect(SEMI)!;
			continue;
		}
		if (self.check_kw("const") && self.peek_at(1).is_kw("default_action")) {
			self.advance();
		}
		if (self.check_kw("default_action")) {
			self.advance();
			self.expect(EQ)!;
			self.parse_action_ref(&table.default_action)!;
			table.has_default = true;
			self.expect(SEMI)!;
			continue;
		}
		if (self.check_kw("const") && self.peek_at(1).is_kw("entries")) {
			self.advance();
		}
		if (self.check_kw("entries")) {
			self.advance();
			self.expect(EQ)!;
			self.skip_balanced(LBRACE, RBRACE)!;
			continue;
		}
		if (self.check(IDENT)) {
			self.advance();
			if (self.check(EQ)) {
				self.advance();
				if (self.check(LBRACE)) {
					self.skip_balanced(LBRACE, RBRACE)!;
				} else {
					while (!self.check(SEMI) && !self.check(END)) {
						if (self.check(LBRACE)) {
							self.skip_balanced(LBRACE, RBRACE)!;
						} else if (self.check(LPAREN)) {
							self.skip_balanced(LPAREN, RPAREN)!;
						} else {
							self.advance();
						}
					}
					self.expect(SEMI)!;
				}
				continue;
			}
		}
		self.fail("unexpected table property")!;
	}
	self.expect(RBRACE)!;
	return table;
}

fn Decl*? Parser.parse_header_like(&self, DeclKind kind) {
	self.advance();
	String name = self.expect_ident()!;
	self.skip_type_args()!;
	Decl* decl = self.new_decl(kind, name);
	self.parse_field_list(&decl.fields)!;
	return decl;
}

fn Decl*? Parser.parse_typedef(&self) {
	self.advance();
	TypeRef ty = self.parse_type()!;
	String name = self.expect_ident()!;
	self.expect(SEMI)!;
	Decl* decl = self.new_decl(TYPEDEF, name);
	decl.type = ty;
	return decl;
}

fn Decl*? Parser.parse_const(&self) {
	self.advance();
	TypeRef ty = self.parse_type()!;
	String name = self.expect_ident()!;
	self.expect(EQ)!;
	Expr* value = self.parse_expr()!;
	self.expect(SEMI)!;
	Decl* decl = self.new_decl(CONST, name);
	decl.type = ty;
	decl.value = value;
	return decl;
}

fn Decl*? Parser.parse_enum(&self) {
	self.advance();
	if (self.at_type_name() || (self.check(IDENT) && self.peek_at(1).kind == LT)) {
		(void)self.parse_type()!;
	}
	String name = self.expect_ident()!;
	Decl* decl = self.new_decl(ENUM, name);
	self.expect(LBRACE)!;
	while (!self.check(RBRACE) && !self.check(END)) {
		String member = self.expect_ident()!;
		if (self.check(EQ)) {
			self.advance();
			(void)self.parse_expr()!;
		}
		decl.enum_members.push(member);
		if (self.check(COMMA)) {
			self.advance();
		} else {
			break;
		}
	}
	self.expect(RBRACE)!;
	if (self.check(SEMI)) self.advance();
	return decl;
}

fn Decl*? Parser.parse_parser_decl(&self) {
	self.advance();
	String name = self.expect_ident()!;
	self.skip_type_args()!;
	Decl* decl = self.new_decl(PARSER, name);
	self.parse_param_list(&decl.params)!;
	if (self.check(LT) || self.check_kw("transition")) {
		// optional constructor / no-op
	}
	self.expect(LBRACE)!;
	while (!self.check(RBRACE) && !self.check(END)) {
		self.skip_annotations()!;
		if (self.check_kw("state")) {
			decl.states.push(self.parse_state()!);
			continue;
		}
		if (self.check_kw("const")) {
			decl.locals.push(self.parse_const()!);
			continue;
		}
		if (self.check_kw("value_set")) {
			while (!self.check(SEMI) && !self.check(END)) self.advance();
			self.expect(SEMI)!;
			continue;
		}
		self.fail("expected parser state")!;
	}
	self.expect(RBRACE)!;
	return decl;
}

fn Decl*? Parser.parse_control_decl(&self) {
	self.advance();
	String name = self.expect_ident()!;
	self.skip_type_args()!;
	Decl* decl = self.new_decl(CONTROL, name);
	self.parse_param_list(&decl.params)!;
	self.expect(LBRACE)!;
	bool saw_apply = false;
	while (!self.check(RBRACE) && !self.check(END)) {
		self.skip_annotations()!;
		if (self.check(RBRACE)) break;
		if (self.check_kw("action")) {
			decl.actions.push(self.parse_action()!);
			continue;
		}
		if (self.check_kw("table")) {
			decl.tables.push(self.parse_table()!);
			continue;
		}
		if (self.check_kw("apply")) {
			if (saw_apply) self.fail("multiple apply blocks")!;
			saw_apply = true;
			self.advance();
			Stmt* block = self.parse_block()!;
			foreach (s : block.kids) decl.apply.push(s);
			continue;
		}
		if (self.check_kw("const")) {
			decl.locals.push(self.parse_const()!);
			continue;
		}
		if (self.check_kw("header")) {
			decl.locals.push(self.parse_header_like(HEADER)!);
			continue;
		}
		if (self.check_kw("struct")) {
			decl.locals.push(self.parse_header_like(STRUCT)!);
			continue;
		}
		if (self.check_kw("typedef") || self.check_kw("type")) {
			decl.locals.push(self.parse_typedef()!);
			continue;
		}
		if (self.check(IDENT) && (self.peek_at(1).kind == LPAREN || self.peek_at(1).kind == LT)) {
			self.advance();
			self.skip_type_args()!;
			self.skip_balanced(LPAREN, RPAREN)!;
			if (self.check(IDENT)) self.advance();
			self.expect(SEMI)!;
			continue;
		}
		self.fail("unexpected item in control")!;
	}
	self.expect(RBRACE)!;
	return decl;
}

fn Decl*? Parser.parse_top_action(&self) {
	ActionDecl action = self.parse_action()!;
	Decl* decl = self.new_decl(ACTION, action.name);
	decl.action = action;
	decl.params = action.params;
	return decl;
}

fn Decl*? Parser.parse_top_table(&self) {
	TableDecl table = self.parse_table()!;
	Decl* decl = self.new_decl(TABLE, table.name);
	decl.table = table;
	return decl;
}

fn void? Parser.skip_extern_or_error(&self) {
	self.advance();
	if (self.check(IDENT)) self.advance();
	self.skip_type_args()!;
	if (self.check(LBRACE)) {
		self.skip_balanced(LBRACE, RBRACE)!;
	} else if (self.check(LPAREN)) {
		self.skip_balanced(LPAREN, RPAREN)!;
		if (self.check(IDENT)) self.advance();
		if (self.check(SEMI)) self.advance();
	} else if (self.check(SEMI)) {
		self.advance();
	}
}

fn Program*? Parser.parse_program(&self) {
	Program* program = alloc::new(self.allocator, Program);
	program.decls.init(self.allocator);
	while (!self.check(END)) {
		self.skip_annotations()!;
		if (self.check(END)) break;
		if (self.check_kw("header") || self.check_kw("header_union")) {
			program.decls.push(self.parse_header_like(HEADER)!);
			continue;
		}
		if (self.check_kw("struct")) {
			program.decls.push(self.parse_header_like(STRUCT)!);
			continue;
		}
		if (self.check_kw("typedef") || self.check_kw("type")) {
			program.decls.push(self.parse_typedef()!);
			continue;
		}
		if (self.check_kw("const")) {
			program.decls.push(self.parse_const()!);
			continue;
		}
		if (self.check_kw("enum")) {
			program.decls.push(self.parse_enum()!);
			continue;
		}
		if (self.check_kw("parser")) {
			program.decls.push(self.parse_parser_decl()!);
			continue;
		}
		if (self.check_kw("control")) {
			program.decls.push(self.parse_control_decl()!);
			continue;
		}
		if (self.check_kw("action")) {
			program.decls.push(self.parse_top_action()!);
			continue;
		}
		if (self.check_kw("table")) {
			program.decls.push(self.parse_top_table()!);
			continue;
		}
		if (self.check_kw("extern") || self.check_kw("error") || self.check_kw("match_kind")
			|| self.check_kw("package")) {
			self.skip_extern_or_error()!;
			continue;
		}
		if (self.check(IDENT)) {
			self.advance();
			self.skip_type_args()!;
			if (self.check(LPAREN)) {
				self.skip_balanced(LPAREN, RPAREN)!;
				if (self.check(IDENT)) self.advance();
				self.expect(SEMI)!;
				continue;
			}
		}
		self.fail("expected declaration")!;
	}
	return program;
}

fn Program*? parse_source(Allocator allocator, String filename, String source) {
	List{Token} tokens = tokenize(allocator, source)!;
	Parser parser = parser_create(allocator, filename, tokens);
	Program*? program = parser.parse_program();
	if (catch err = program) {
		if (parser.had_error) {
			parser.report();
		} else {
			io::eprintfn("%s: error: %s", filename, err);
		}
		return err~;
	}
	return program;
}

fn Program*? parse_file(Allocator allocator, String path) {
	char[]? data = file::load(allocator, path);
	if (catch err = data) {
		io::eprintfn("error: cannot read %s: %s", path, err);
		return err~;
	}
	return parse_source(allocator, path, (String)data);
}
