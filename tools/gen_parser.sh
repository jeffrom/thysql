#!/bin/sh
# Regenerates the C++ lexer and parser in src/sql/generated from the MySQL
# grammar in src/sql/grammar. Needs Java. The ANTLR tool jar is downloaded once
# into a cache directory (not part of the repository) and checked against a
# pinned SHA-256 before use. Normal builds do not run this script: the generated
# sources are committed.
set -eu

ANTLR_VERSION=4.13.2
ANTLR_SHA256=eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${THYSQL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/thysql}
JAR=$CACHE/antlr-$ANTLR_VERSION-complete.jar
URL=https://www.antlr.org/download/antlr-$ANTLR_VERSION-complete.jar

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

if [ ! -f "$JAR" ] || [ "$(sha256 "$JAR")" != "$ANTLR_SHA256" ]; then
  mkdir -p "$CACHE"
  tmp=$JAR.part
  curl -fsSL -o "$tmp" "$URL"
  if [ "$(sha256 "$tmp")" != "$ANTLR_SHA256" ]; then
    rm -f "$tmp"
    echo "gen_parser: checksum mismatch for $URL" >&2
    exit 1
  fi
  mv "$tmp" "$JAR"
fi

GRAMMAR=$ROOT/src/sql/grammar
OUT=$ROOT/src/sql/generated
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -lib lets the grammars find predefined.tokens, which MySQLLexer.g4 imports.
cd "$GRAMMAR"
java -jar "$JAR" -Dlanguage=Cpp -listener -visitor -package parsers \
  -lib "$GRAMMAR" -o "$TMP" MySQLLexer.g4 MySQLParser.g4

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$TMP"/*.h "$TMP"/*.cpp "$OUT"/
echo "gen_parser: wrote $(ls "$OUT" | wc -l | tr -d ' ') files to src/sql/generated"
