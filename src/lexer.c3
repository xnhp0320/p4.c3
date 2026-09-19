module p4c3;
import std::io;
import std::collections::list;

excuse { PARSE_FAILED }

enum TokenKind
{
	END,
	IDENT,
	INTEGER,
	STR,
	LBRACE,
	RBRACE,
	LPAREN,
	RPAREN,
	LBRACK,
	RBRACK,
	LT,
	GT,
	SEMI,
	COMMA,
	COLON,
	DOT,
	DOTDOT,
	EQ,
	PLUS,
	MINUS,
	STAR,
	SLASH,
	PERCENT,
	AMP,
	PIPE,
	CARET,
	TILDE,
	BANG,
	QUESTION,
	EQEQ,
	NEQ,
	LE,
	GE,
	ANDAND,
	OROR,
	LSHIFT,
	RSHIFT,
	MASKAND,
	AT,
}

struct Token
{
	TokenKind kind;
	String text;
	uint line;
	uint column;
}

struct Lexer
{
	String source;
	sz pos;
	uint line;
	uint column;
	String error_msg;
	uint error_line;
	uint error_column;
}

fn bool Token.is_kw(self, String name)
{
	return self.kind == IDENT && self.text == name;
}

fn String TokenKind.label(self)
{
	switch (self)
	{
		case END: return "end of file";
		case IDENT: return "identifier";
		case INTEGER: return "integer";
		case STR: return "string";
		case LBRACE: return "'{'";
		case RBRACE: return "'}'";
		case LPAREN: return "'('";
		case RPAREN: return "')'";
		case LBRACK: return "'['";
		case RBRACK: return "']'";
		case LT: return "'<'";
		case GT: return "'>'";
		case SEMI: return "';'";
		case COMMA: return "','";
		case COLON: return "':'";
		case DOT: return "'.'";
		case DOTDOT: return "'..'";
		case EQ: return "'='";
		case PLUS: return "'+'";
		case MINUS: return "'-'";
		case STAR: return "'*'";
		case SLASH: return "'/'";
		case PERCENT: return "'%'";
		case AMP: return "'&'";
		case PIPE: return "'|'";
		case CARET: return "'^'";
		case TILDE: return "'~'";
		case BANG: return "'!'";
		case QUESTION: return "'?'";
		case EQEQ: return "'=='";
		case NEQ: return "'!='";
		case LE: return "'<='";
		case GE: return "'>='";
		case ANDAND: return "'&&'";
		case OROR: return "'||'";
		case LSHIFT: return "'<<'";
		case RSHIFT: return "'>>'";
		case MASKAND: return "'&&&'";
		case AT: return "'@'";
		default: return "token";
	}
}

fn void Lexer.init(&self, String source)
{
	self.source = source;
	self.pos = 0;
	self.line = 1;
	self.column = 1;
}

fn bool Lexer.at_end(&self)
{
	return self.pos >= self.source.len;
}

fn char Lexer.peek(&self)
{
	if (self.at_end()) return 0;
	return self.source[self.pos];
}

fn char Lexer.peek_next(&self)
{
	if (self.pos + 1 >= self.source.len) return 0;
	return self.source[self.pos + 1];
}

fn char Lexer.take(&self)
{
	char c = self.peek();
	if (self.at_end()) return 0;
	self.pos++;
	if (c == '\n')
	{
		self.line++;
		self.column = 1;
	}
	else
	{
		self.column++;
	}
	return c;
}

fn void? Lexer.fail(&self, String msg)
{
	self.error_msg = msg;
	self.error_line = self.line;
	self.error_column = self.column;
	return PARSE_FAILED~;
}

fn void? Lexer.skip_trivia(&self)
{
	while (!self.at_end())
	{
		char c = self.peek();
		if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
		{
			self.take();
			continue;
		}
		if (c == '/' && self.peek_next() == '/')
		{
			self.take();
			self.take();
			while (!self.at_end() && self.peek() != '\n') self.take();
			continue;
		}
		if (c == '/' && self.peek_next() == '*')
		{
			self.take();
			self.take();
			bool closed = false;
			while (!self.at_end())
			{
				if (self.peek() == '*' && self.peek_next() == '/')
				{
					self.take();
					self.take();
					closed = true;
					break;
				}
				self.take();
			}
			if (!closed) self.fail("unterminated block comment")!;
			continue;
		}
		if (c == '#')
		{
			while (!self.at_end() && self.peek() != '\n') self.take();
			continue;
		}
		break;
	}
}

fn Token Lexer.make(&self, TokenKind kind, sz start, uint line, uint column)
{
	Token tok;
	tok.kind = kind;
	tok.text = self.source[start:self.pos - start];
	tok.line = line;
	tok.column = column;
	return tok;
}

fn void Lexer.scan_ident(&self)
{
	while (!self.at_end())
	{
		char c = self.peek();
		if (c.is_alnum() || c == '_')
		{
			self.take();
		}
		else
		{
			break;
		}
	}
}

fn void Lexer.scan_digits(&self)
{
	while (self.peek().is_digit()) self.take();
}

fn void Lexer.scan_hex(&self)
{
	while (self.peek().is_xdigit()) self.take();
}

fn void Lexer.scan_number(&self)
{
	if (self.peek() == '0')
	{
		self.take();
		char b = self.peek();
		if (b == 'x' || b == 'X')
		{
			self.take();
			self.scan_hex();
			return;
		}
		if (b == 'b' || b == 'B')
		{
			self.take();
			while (self.peek() == '0' || self.peek() == '1') self.take();
			return;
		}
		if (b == 'o' || b == 'O')
		{
			self.take();
			while (self.peek().is_odigit()) self.take();
			return;
		}
		self.scan_digits();
	}
	else
	{
		self.scan_digits();
	}
	char w = self.peek();
	if (w == 'w' || w == 'W' || w == 's' || w == 'S')
	{
		self.take();
		if (self.peek() == '0')
		{
			sz saved = self.pos;
			uint saved_col = self.column;
			self.take();
			char b = self.peek();
			if (b == 'x' || b == 'X')
			{
				self.take();
				self.scan_hex();
				return;
			}
			if (b == 'b' || b == 'B')
			{
				self.take();
				while (self.peek() == '0' || self.peek() == '1') self.take();
				return;
			}
			if (b == 'o' || b == 'O')
			{
				self.take();
				while (self.peek().is_odigit()) self.take();
				return;
			}
			self.pos = saved;
			self.column = saved_col;
		}
		self.scan_digits();
	}
}

fn void? Lexer.scan_string(&self)
{
	while (!self.at_end())
	{
		char c = self.peek();
		if (c == '"')
		{
			self.take();
			return;
		}
		if (c == '\n') self.fail("unterminated string")!;
		self.take();
		if (c == '\\' && !self.at_end()) self.take();
	}
	self.fail("unterminated string")!;
	return PARSE_FAILED~;
}

fn Token? Lexer.scan_token(&self)
{
	self.skip_trivia()!;
	if (self.at_end())
	{
		Token end;
		end.kind = END;
		end.text = "";
		end.line = self.line;
		end.column = self.column;
		return end;
	}
	uint line = self.line;
	uint column = self.column;
	sz start = self.pos;
	char c = self.take();
	if (c.is_alpha() || c == '_')
	{
		self.scan_ident();
		return self.make(IDENT, start, line, column);
	}
	if (c.is_digit())
	{
		self.pos = start;
		self.line = line;
		self.column = column;
		self.scan_number();
		return self.make(INTEGER, start, line, column);
	}
	if (c == '"')
	{
		self.scan_string()!;
		return self.make(STR, start, line, column);
	}
	switch (c)
	{
		case '{': return self.make(LBRACE, start, line, column);
		case '}': return self.make(RBRACE, start, line, column);
		case '(': return self.make(LPAREN, start, line, column);
		case ')': return self.make(RPAREN, start, line, column);
		case '[': return self.make(LBRACK, start, line, column);
		case ']': return self.make(RBRACK, start, line, column);
		case ';': return self.make(SEMI, start, line, column);
		case ',': return self.make(COMMA, start, line, column);
		case ':': return self.make(COLON, start, line, column);
		case '+': return self.make(PLUS, start, line, column);
		case '*': return self.make(STAR, start, line, column);
		case '/': return self.make(SLASH, start, line, column);
		case '%': return self.make(PERCENT, start, line, column);
		case '^': return self.make(CARET, start, line, column);
		case '~': return self.make(TILDE, start, line, column);
		case '?': return self.make(QUESTION, start, line, column);
		case '@': return self.make(AT, start, line, column);
		case '-': return self.make(MINUS, start, line, column);
		case '.':
			if (self.peek() == '.')
			{
				self.take();
				return self.make(DOTDOT, start, line, column);
			}
			return self.make(DOT, start, line, column);
		case '=':
			if (self.peek() == '=')
			{
				self.take();
				return self.make(EQEQ, start, line, column);
			}
			return self.make(EQ, start, line, column);
		case '!':
			if (self.peek() == '=')
			{
				self.take();
				return self.make(NEQ, start, line, column);
			}
			return self.make(BANG, start, line, column);
		case '<':
			if (self.peek() == '=')
			{
				self.take();
				return self.make(LE, start, line, column);
			}
			if (self.peek() == '<')
			{
				self.take();
				return self.make(LSHIFT, start, line, column);
			}
			return self.make(LT, start, line, column);
		case '>':
			if (self.peek() == '=')
			{
				self.take();
				return self.make(GE, start, line, column);
			}
			if (self.peek() == '>')
			{
				self.take();
				return self.make(RSHIFT, start, line, column);
			}
			return self.make(GT, start, line, column);
		case '&':
			if (self.peek() == '&')
			{
				self.take();
				if (self.peek() == '&')
				{
					self.take();
					return self.make(MASKAND, start, line, column);
				}
				return self.make(ANDAND, start, line, column);
			}
			return self.make(AMP, start, line, column);
		case '|':
			if (self.peek() == '|')
			{
				self.take();
				return self.make(OROR, start, line, column);
			}
			return self.make(PIPE, start, line, column);
		default:
			self.fail(string::tformat("unexpected character '%c'", c))!;
			return PARSE_FAILED~;
	}
}

fn List{Token}? tokenize(Allocator allocator, String source)
{
	Lexer lexer;
	lexer.init(source);
	List{Token} tokens;
	tokens.init(allocator);
	while (true)
	{
		Token tok = lexer.scan_token()!;
		tokens.push(tok);
		if (tok.kind == END) break;
	}
	return tokens;
}
