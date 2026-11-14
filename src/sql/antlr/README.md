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

- `MySQLRecognizerCommon.{h,cpp}`: `functionSymbolsForVersion()` removed (it
  needs Workbench's symbol tables). The `base/symbol-info.h` include is gone.
- `parsers-common.cpp`: unused `base/string_utilities.h` include removed.
- `base/symbol-info.h` is a local shim, not Workbench's file. It keeps the
  entry points `MySQLBaseLexer.cpp` calls, with two simplifications:
  `isKeyword()` accepts any name and `isReservedKeyword()` reserves nothing.
  Real per-version keyword tables are still to be ported.

`MySQLBaseLexer::keywordFromText()` is kept verbatim. Its symbol map is keyed
by upper-case token names but looked up with lower-case text, so it does not
match anything. Nothing in the grammar calls it.
