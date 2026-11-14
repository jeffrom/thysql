#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <source-dir> <build-dir> [cmake-option...]" >&2
  exit 2
fi

source_dir=$1
build_dir=$2
shift 2

# Options after the directories come from build.zig, such as the OpenSSL root.
cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGIT_EXECUTABLE=GIT_EXECUTABLE-NOTFOUND \
  -DWITH_MYSQLCOMPAT=ON \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_DYNCOL=OFF \
  -DWITH_CURL=OFF \
  -DWITH_SSL=OPENSSL \
  -DWITH_EXTERNAL_ZLIB=OFF \
  -DPLUGIN_CACHING_SHA2_PASSWORD=STATIC \
  -DPLUGIN_SHA256_PASSWORD=STATIC \
  -DPLUGIN_DIALOG=STATIC \
  -DPLUGIN_CLIENT_ED25519=STATIC \
  -DPLUGIN_PARSEC=STATIC \
  -DPLUGIN_AUTH_GSSAPI_CLIENT=STATIC \
  -DPLUGIN_MYSQL_CLEAR_PASSWORD=STATIC \
  -DPLUGIN_ZSTD=STATIC \
  "$@"

cmake --build "$build_dir" --target mariadbclient
ln -sf libmariadbclient.a "$build_dir/libmariadb/libmysqlclient.a"
