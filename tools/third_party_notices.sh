#!/bin/sh
# Prints THIRD_PARTY_NOTICES for a release: each third-party component that thysql
# links or ships, with its license. The GPL-2.0 text is not repeated; it is COPYING.
# Paths are relative to this script, so it runs from any directory.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Prints the header of one component section.
section() {
  printf '\n================================================================\n'
  printf '%s\n' "$1"
  printf 'Upstream: %s\n' "$2"
  printf 'License:  %s\n\n' "$3"
}

printf 'THIRD-PARTY NOTICES for thysql\n'
printf '\n'
printf 'thysql is licensed under GPL-2.0-or-later with an OpenSSL linking exception\n'
printf '(see COPYING). The components below keep their own licenses. The GPL-2.0 text\n'
printf 'is in COPYING, included with this archive.\n'

section "MariaDB Connector/C (libmariadb, statically linked)" \
  "https://github.com/MariaDB/mariadb-connector-c (commit e938a0d6, reports version 3.4.10)" \
  "LGPL-2.1"
printf 'Corresponding source: the source of this release is the thysql source tree at\n'
printf 'the release tag, including the deps/mariadb-connector-c submodule at the commit\n'
printf 'pinned in deps/README.md.\n\n'
cat "$ROOT/deps/mariadb-connector-c/COPYING.LIB"

section "ANTLR4 C++ runtime (statically linked)" \
  "https://github.com/antlr/antlr4 (4.13.2)" \
  "BSD-3-Clause"
cat "$ROOT/deps/antlr4/LICENSE.txt"

section "antlr4-c3 (statically linked)" \
  "https://github.com/mike-lischke/antlr4-c3 (v3.4.3)" \
  "MIT"
cat "$ROOT/deps/antlr4-c3/License.txt"

section "MySQL Workbench grammar and parser support files (statically linked)" \
  "https://github.com/mysql/mysql-workbench (src/sql/grammar, and the lexer, parser and base classes derived from it)" \
  "GPL-2.0-only, with Oracle's permission to link with OpenSSL"
printf 'The files are copyright Oracle and/or its affiliates. The header of\n'
printf 'src/sql/grammar/MySQLParser.g4 reads:\n\n'
# Quoted from src/sql/grammar/MySQLParser.g4, lines 3 to 25 (the license comment).
sed -n '3,25p' "$ROOT/src/sql/grammar/MySQLParser.g4"
printf '\nThe GPL-2.0 text is in COPYING.\n'

section "OpenSSL (statically linked on macOS release builds)" \
  "https://github.com/openssl/openssl (3.5.9)" \
  "Apache-2.0"
cat "$ROOT/licenses/OpenSSL-LICENSE.txt"

section "zstd (statically linked on macOS release builds)" \
  "https://github.com/facebook/zstd (1.5.7)" \
  "BSD-3-Clause"
cat "$ROOT/licenses/zstd-LICENSE.txt"
