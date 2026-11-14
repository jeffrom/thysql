// Smoke test for the ANTLR4 MySQL parser. It parses one valid and one invalid
// statement with server version 8.4.0 and checks the syntax error counts. Built
// and run by `zig build test`.

#include <cstdio>
#include <cstdlib>
#include <string>

#include "antlr4-runtime.h"
#include "MySQLLexer.h"
#include "MySQLParser.h"
#include "base/symbol-info.h"

namespace {

constexpr long kServerVersion = 80400; // MySQL 8.4.0.

// Returns the number of syntax errors the parser reports for a single query.
size_t countSyntaxErrors(const std::string &sql) {
  antlr4::ANTLRInputStream input(sql);
  parsers::MySQLLexer lexer(&input);
  lexer.serverVersion = kServerVersion;
  lexer.removeErrorListeners();

  antlr4::CommonTokenStream tokens(&lexer);
  parsers::MySQLParser parser(&tokens);
  parser.serverVersion = kServerVersion;
  parser.removeErrorListeners();

  parser.query();
  return parser.getNumberOfSyntaxErrors();
}

} // namespace

int main() {
  struct Case {
    const char *sql;
    bool valid;
  };
  const Case cases[] = {
    {"SELECT a FROM t WHERE b = 1", true},
    {"SELECT a FROM t WHERE", false},
    {"SELECT 1 AS status", true},   // STATUS is not reserved.
    {"SELECT 1 AS select", false},  // SELECT is reserved.
  };

  int failures = 0;

  // Symbol tables: reserved words are a subset of keywords, and lookups ignore case.
  struct SymbolCase {
    const char *word;
    base::MySQLVersion version;
    bool keyword;
    bool reserved;
  };
  const SymbolCase symbols[] = {
    {"SELECT", base::MySQLVersion::MySQL84, true, true},
    {"select", base::MySQLVersion::MySQL84, true, true},
    {"STATUS", base::MySQLVersion::MySQL84, true, false},
    {"NOSUCHWORD", base::MySQLVersion::MySQL84, false, false},
    {"GROUPS", base::MySQLVersion::MySQL80, true, true},   // Reserved since 8.0.2 (window frames).
    {"GROUPS", base::MySQLVersion::MySQL57, false, false}, // Not a keyword before 8.0.2.
    {"SELECT", base::MySQLVersion::MySQL57, true, true},
  };
  for (const SymbolCase &c : symbols) {
    bool keyword = base::MySQLSymbolInfo::isKeyword(c.word, c.version);
    bool reserved = base::MySQLSymbolInfo::isReservedKeyword(c.word, c.version);
    bool ok = keyword == c.keyword && reserved == c.reserved;
    std::printf("%s symbol %s (keyword %d, reserved %d)\n", ok ? "ok  " : "FAIL", c.word, keyword, reserved);
    if (!ok)
      ++failures;
  }

  // The lexer's isIdentifier(): reserved keywords are not identifiers, other keywords are.
  struct IdentifierCase {
    size_t type;
    const char *name;
    bool identifier;
  };
  const IdentifierCase identifiers[] = {
    {parsers::MySQLLexer::IDENTIFIER, "IDENTIFIER", true},
    {parsers::MySQLLexer::SELECT_SYMBOL, "SELECT", false},
    {parsers::MySQLLexer::STATUS_SYMBOL, "STATUS", true},
  };
  for (const IdentifierCase &c : identifiers) {
    antlr4::ANTLRInputStream input("");
    parsers::MySQLLexer lexer(&input);
    lexer.serverVersion = kServerVersion;
    bool identifier = lexer.isIdentifier(c.type);
    bool ok = identifier == c.identifier;
    std::printf("%s isIdentifier %s (%d)\n", ok ? "ok  " : "FAIL", c.name, identifier);
    if (!ok)
      ++failures;
  }

  for (const Case &c : cases) {
    size_t errors = countSyntaxErrors(c.sql);
    bool ok = c.valid ? errors == 0 : errors > 0;
    std::printf("%s %s (%zu syntax errors)\n", ok ? "ok  " : "FAIL", c.sql, errors);
    if (!ok)
      ++failures;
  }

  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
