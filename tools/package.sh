#!/bin/sh
# Builds a release tarball for one platform, dist/thysql-<version>-<os>-<arch>.tar.gz.
# Usage: tools/package.sh <version> <darwin|linux> <arm64|x86_64>
# Runs only on the matching host; there is no cross-compiling. Other files in dist/
# are left alone.
set -eu

usage() {
  echo "usage: $0 <version> <darwin|linux> <arm64|x86_64>" >&2
  exit 2
}

if [ "$#" -ne 3 ]; then
  usage
fi
version=$1
os=$2
arch=$3

# The version becomes part of a path and a tar entry, so keep it to plain characters.
case "$version" in
  '' | *[!0-9A-Za-z._+-]*) usage ;;
esac
case "$os" in
  darwin | linux) ;;
  *) usage ;;
esac
case "$arch" in
  arm64 | x86_64) ;;
  *) usage ;;
esac

host_os=$(uname -s)
case "$host_os" in
  Darwin) host_os=darwin ;;
  Linux) host_os=linux ;;
  *) host_os=unknown ;;
esac
host_arch=$(uname -m)
case "$host_arch" in
  arm64 | aarch64) host_arch=arm64 ;;
  x86_64 | amd64) host_arch=x86_64 ;;
esac
if [ "$host_os" != "$os" ] || [ "$host_arch" != "$arch" ]; then
  echo "package.sh: this host is $host_os $host_arch, not $os $arch. Build on the matching machine." >&2
  exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

name=thysql-$version-$os-$arch
dist=$ROOT/dist
prefix=$dist/build-$name
stage=$dist/$name
tarball=$dist/$name.tar.gz
commit=$(git rev-parse --short HEAD)

# A fresh prefix each time, so no stale binary can be picked up.
rm -rf "$prefix"
if [ "$os" = darwin ]; then
  # Homebrew's OpenSSL and zstd are linked statically, so the binary needs nothing from Homebrew.
  openssl_prefix=${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}
  zstd_prefix=${ZSTD_PREFIX:-$(brew --prefix zstd)}
  for lib in "$openssl_prefix/lib/libssl.a" "$openssl_prefix/lib/libcrypto.a" "$zstd_prefix/lib/libzstd.a"; do
    if [ ! -f "$lib" ]; then
      echo "package.sh: missing static library $lib (set OPENSSL_PREFIX or ZSTD_PREFIX)" >&2
      exit 1
    fi
  done
  zig build -Doptimize=ReleaseSafe -Dversion="$version" -Dcommit="$commit" \
    -Dstatic-deps=true \
    -Dopenssl-lib-dir="$openssl_prefix/lib" \
    -Dzstd-lib-dir="$zstd_prefix/lib" \
    -p "$prefix"
else
  zig build -Doptimize=ReleaseSafe -Dversion="$version" -Dcommit="$commit" -p "$prefix"
fi

# Stage the release directory. The tarball is made from it at the end.
rm -rf "$stage" "$tarball"
mkdir -p "$stage/completions"
cp "$prefix/bin/thysql" "$stage/thysql"
sh "$ROOT/tools/check_linkage.sh" "$stage/thysql"
if [ "$os" = darwin ]; then
  codesign --force -s - "$stage/thysql"
  codesign --verify --verbose=2 "$stage/thysql"
fi

# Smoke tests on the staged binary.
ver=$("$stage/thysql" --version)
case "$ver" in
  "thysql $version"*) ;;
  *)
    echo "package.sh: --version printed '$ver', expected 'thysql $version'" >&2
    exit 1
    ;;
esac
# Generate to a file first: in a pipeline, a failing thysql would not fail the check.
"$stage/thysql" completion bash > "$stage/completions/thysql.bash"
bash -n "$stage/completions/thysql.bash"

cp "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/COPYING" "$stage/"
sh "$ROOT/tools/third_party_notices.sh" > "$stage/THIRD_PARTY_NOTICES"

# COPYFILE_DISABLE keeps macOS tar from adding AppleDouble ._ files.
COPYFILE_DISABLE=1 tar -C "$dist" -czf "$tarball" "$name"
rm -rf "$prefix"

if command -v shasum >/dev/null 2>&1; then
  sha=$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)
else
  sha=$(sha256sum "$tarball" | cut -d ' ' -f 1)
fi
echo "$tarball"
echo "sha256: $sha"
