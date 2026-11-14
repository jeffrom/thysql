/*
 * C interface to the ANTLR4 MySQL parser (see src/sql/antlr/README.md). Syntax checks and
 * completion candidates for one SQL statement, with byte offsets into the UTF-8 input.
 *
 * Every C++ exception is caught inside the library, so no C++ type crosses this boundary.
 * The library is not thread-safe per parser object; use one object per thread.
 */

#ifndef THYSQL_SQL_ANTLR_SHIM_H
#define THYSQL_SQL_ANTLR_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque parser. Owns the parse state and the buffers returned by the functions below. */
typedef struct mysql_parser mysql_parser;

/* SQL mode flags for mysql_parser_new() and mysql_parser_set_sql_mode(). Same bits as
 * parsers::MySQLRecognizerCommon::SqlMode. */
enum mysql_sql_mode {
  MYSQL_MODE_NONE = 0,
  MYSQL_MODE_ANSI_QUOTES = 1 << 0,
  MYSQL_MODE_HIGH_NOT_PRECEDENCE = 1 << 1,
  MYSQL_MODE_PIPES_AS_CONCAT = 1 << 2,
  MYSQL_MODE_IGNORE_SPACE = 1 << 3,
  MYSQL_MODE_NO_BACKSLASH_ESCAPES = 1 << 4
};

/* Server version as major * 10000 + minor * 100 + patch, e.g. 80400 for 8.4.0 or 50700 for 5.7.0. */
mysql_parser *mysql_parser_new(unsigned server_version, unsigned sql_mode_flags);
void mysql_parser_free(mysql_parser *parser);

void mysql_parser_set_version(mysql_parser *parser, unsigned server_version);
void mysql_parser_set_sql_mode(mysql_parser *parser, unsigned sql_mode_flags);

/* A syntax or lexer error. `start` and `end` are byte offsets into the input (end exclusive);
 * `line` is 1-based and `column` is 0-based, both counted in code points. `message` is a
 * NUL-terminated UTF-8 string. All pointers stay valid until the next call that takes `parser`. */
typedef struct {
  size_t start;
  size_t end;
  unsigned line;
  unsigned column;
  const char *message;
} mysql_parse_error;

/* Parses one statement (the grammar's `query` rule: one statement, optionally followed by a
 * semicolon) and returns the number of errors. The errors are readable through
 * mysql_parser_error() until the next call that takes `parser`. Errors are in input order. */
size_t mysql_parser_check(mysql_parser *parser, const char *sql, size_t len);
const mysql_parse_error *mysql_parser_error(mysql_parser *parser, size_t index);

/* A completion candidate. `kind` is MYSQL_CANDIDATE_TOKEN or MYSQL_CANDIDATE_RULE. For a token,
 * `text` is the keyword in upper case. For a rule, `id` is one of the MYSQL_RULE_* values below
 * and `text` is the rule name. */
enum mysql_candidate_kind {
  MYSQL_CANDIDATE_TOKEN = 0,
  MYSQL_CANDIDATE_RULE = 1
};

typedef struct {
  int kind;
  int id;
  const char *text;
} mysql_candidate;

/* Returns the number of candidates for the caret at byte offset `caret` (clamped to `len`).
 * The candidates are readable through mysql_parser_candidate() until the next call that takes
 * `parser`. A caret inside or right after a word completes that word, so the word is not
 * part of the input for the candidates. The list is not filtered by the typed prefix: the
 * caller keeps the candidates that start with it. */
size_t mysql_parser_candidates(mysql_parser *parser, const char *sql, size_t len, size_t caret);
const mysql_candidate *mysql_parser_candidate(mysql_parser *parser, size_t index);

/* Parser rule ids reported in candidates. Values match parsers::MySQLParser::Rule* in the
 * generated parser; shim.cpp checks them at compile time. */
enum mysql_rule {
  MYSQL_RULE_QUERY = 0,
  MYSQL_RULE_COLUMN_INTERNAL_REF = 521,
  MYSQL_RULE_COLUMN_REF = 523,
  MYSQL_RULE_TABLE_WILD = 527,
  MYSQL_RULE_SCHEMA_REF = 529,
  MYSQL_RULE_PROCEDURE_REF = 531,
  MYSQL_RULE_FUNCTION_REF = 533,
  MYSQL_RULE_TRIGGER_REF = 535,
  MYSQL_RULE_VIEW_REF = 537,
  MYSQL_RULE_TABLESPACE_REF = 539,
  MYSQL_RULE_LOGFILE_GROUP_REF = 541,
  MYSQL_RULE_EVENT_REF = 543,
  MYSQL_RULE_ENGINE_REF = 547,
  MYSQL_RULE_SERVER_REF = 546,
  MYSQL_RULE_FILTER_TABLE_REF = 549,
  MYSQL_RULE_TABLE_REF_WITH_WILDCARD = 550,
  MYSQL_RULE_TABLE_REF = 551,
  MYSQL_RULE_LABEL_REF = 556,
  MYSQL_RULE_CHARSET_NAME = 468,
  MYSQL_RULE_COLLATION_NAME = 469,
  MYSQL_RULE_USER = 513,
  MYSQL_RULE_USER_VARIABLE = 371,
  MYSQL_RULE_SYSTEM_VARIABLE = 372,
  MYSQL_RULE_SET_SYSTEM_VARIABLE = 295
};

#ifdef __cplusplus
}
#endif

#endif /* THYSQL_SQL_ANTLR_SHIM_H */
