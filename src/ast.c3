module p4c3;
import std::collections::list;

enum TypeKind
{
	BIT,
	INT,
	VARBIT,
	BOOL,
	VOID,
	ERROR,
	NAME,
}

struct TypeRef
{
	TypeKind kind;
	String name;
	uint width;
	uint stack_size;
}

struct ParamDecl
{
	String direction;
	TypeRef type;
	String name;
}

struct FieldDecl
{
	TypeRef type;
	String name;
}

enum ExprKind
{
	IDENT,
	NUMBER,
	STR,
	MEMBER,
	INDEX,
	CALL,
	UNARY,
	BINARY,
	TUPLE,
}

struct Expr
{
	ExprKind kind;
	Token token;
	List{Expr*} kids;
}

enum StmtKind
{
	BLOCK,
	ASSIGN,
	EXPR,
	IF,
	RETURN,
	EXIT,
	VAR,
}

struct Stmt
{
	StmtKind kind;
	TypeRef type;
	String name;
	Expr* cond;
	Expr* lhs;
	Expr* rhs;
	List{Stmt*} kids;
}

enum TransitionKind
{
	NONE,
	NAME,
	SELECT,
}

struct SelectCase
{
	bool is_default;
	List{Expr*} keys;
	String target;
}

struct Transition
{
	TransitionKind kind;
	String target;
	List{Expr*} select_keys;
	List{SelectCase} cases;
}

struct ParserState
{
	String name;
	List{Stmt*} body;
	Transition transition;
}

struct KeyElem
{
	Expr* expr;
	String match_kind;
}

struct ActionRef
{
	String name;
	List{Expr*} args;
	bool has_args;
}

struct TableDecl
{
	String name;
	List{KeyElem} keys;
	List{ActionRef} actions;
	Expr* size;
	ActionRef default_action;
	bool has_default;
}

struct ActionDecl
{
	String name;
	List{ParamDecl} params;
	List{Stmt*} body;
}

enum DeclKind
{
	HEADER,
	STRUCT,
	TYPEDEF,
	CONST,
	ENUM,
	PARSER,
	CONTROL,
	ACTION,
	TABLE,
}

struct Decl
{
	DeclKind kind;
	String name;
	TypeRef type;
	Expr* value;
	List{FieldDecl} fields;
	List{ParamDecl} params;
	List{ParserState} states;
	List{ActionDecl} actions;
	List{TableDecl} tables;
	TableDecl table;
	ActionDecl action;
	List{Stmt*} apply;
	List{String} enum_members;
	List{Decl*} locals;
}

struct Program
{
	List{Decl*} decls;
}
