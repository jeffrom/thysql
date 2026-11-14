// Smoke test for the ANTLR4 MySQL parser. It parses one valid and one invalid
// statement with server version 8.4.0 and checks the syntax error counts. Built
// and run by `zig build test`.

#include <cstdio>
#include <cstdlib>
#include <string>

#include "antlr4-runtime.h"
#include "MySQLLexer.h"
#include "MySQLParser.h"

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
  };

  int failures = 0;
  for (const Case &c : cases) {
    size_t errors = countSyntaxErrors(c.sql);
    bool ok = c.valid ? errors == 0 : errors > 0;
    std::printf("%s %s (%zu syntax errors)\n", ok ? "ok  " : "FAIL", c.sql, errors);
    if (!ok)
      ++failures;
  }

  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
