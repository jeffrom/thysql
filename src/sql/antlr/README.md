# MySQL parser sources (ANTLR4 C++)

Hand-written glue for the ANTLR4 MySQL parser. The grammar itself is in
`src/sql/grammar`, and the ANTLR output is in `src/sql/generated`.

## Provenance

Copied from MySQL Workbench, `library/parsers` at commit
`dc3590dbfbee29c87e201d4ef53607e5deb0e4f9`, under GPL-2.0 (the copyright
headers in each file are kept):

- `MySQLBaseLexer.{h,cpp}`, `MySQLBaseRecognizer.{h,cpp}`,
  `MySQLRecognizerCommon.{h,cpp}`, `mysql-recognition-types.h`,
  `parsers-common.{h,cpp}`

Grammars in `src/sql/grammar` are from the same tree, `library/parsers/grammars`:
`MySQLLexer.g4`, `MySQLParser.g4`, `predefined.tokens`.

## Local changes

Each modified file says so at the top. In short:

- `MySQLRecognizerCommon.{h,cpp}`: `functionSymbolsForVersion()` is back. It
  returns the function name set of a version (`std::set<std::string>`) instead
  of Workbench's `SymbolTable *`, because `SymbolTable` is not vendored.
- `parsers-common.cpp`: unused `base/string_utilities.h` include removed.
- `base/symbol-info.{h,cpp}`: Workbench's `library/base/symbol-info.{h,cpp}` at
  the same commit, with these changes:
  - `BASELIBRARY_PUBLIC_FUNC` removed.
  - `MySQL84` added to `MySQLVersion`. Server versions 8.4 and up use the MySQL
    8.4 keyword table; 8.0 to 8.3 use the 8.0 table.
  - Reserved keywords were collected into a local set and never stored, so
    `isReservedKeyword()` was always false in Workbench. They are stored now.
  - Lookups upper-case the name. The tables are upper case; Workbench's comment
    says lower case, which did not match the tables.
  - MySQL 8.4 has no system function table here. It uses the 8.0 one.
- `base/keyword_list56.h`, `keyword_list57.h`, `keyword_list80.h`,
  `system-functions.h`: copied verbatim from Workbench's `res/server/`. The
  `keyword_t` typedef moved into `symbol-info.cpp`, because it is defined in
  two of the lists and commented out in the third.
- `base/keyword_list84.h`: not from Workbench. It is generated from
  `src/sql/keywords.zig` (732 entries, 263 reserved, the MySQL 8.4 list), in
  the same format. Regenerate it from that file, do not edit it.

Open issue, not changed here: `MySQLBaseLexer::isIdentifier()` passes the
vocabulary's symbolic name (`SELECT_SYMBOL`) to `isReservedKeyword()`, but the
tables hold plain words (`SELECT`), so that check never matches. Parser
rules still reject reserved words, because `identifierKeyword` leaves them out
of the grammar. `MySQLBaseLexer::keywordFromText()` is kept verbatim. Its symbol
map is keyed by upper-case token names but looked up with lower-case text, so it
does not match anything. Nothing in the grammar calls it.

## Build

`zig build` compiles the ANTLR4 runtime (`deps/antlr4`, C++17), the base
classes and symbol tables above, the generated parser (`src/sql/generated`) and
antlr4-c3 (`deps/antlr4-c3`, C++20) into `libmysql_parser.a`. `zig build test`
runs `smoke_test.cpp` against it; it checks the symbol tables and that
`SELECT 1 AS select` is rejected while `SELECT 1 AS status` is accepted. Nothing in thysql links the library yet.
