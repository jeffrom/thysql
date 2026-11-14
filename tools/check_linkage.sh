#!/bin/sh
# Shows the shared libraries a built binary loads. On macOS, fails if any of
# them is outside /System/ and /usr/lib/, so a release does not depend on Homebrew.
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <binary>" >&2
  exit 2
fi

binary=$1

case "$(uname -s)" in
  Darwin)
    otool -L "$binary"
    # Skip the first line, which names the binary, and the version info after each path.
    outside=$(otool -L "$binary" | tail -n +2 |
      sed -e 's/^[[:space:]]*//' -e 's/ (compatibility.*//' |
      grep -v -E '^(/System/|/usr/lib/)' || true)
    if [ -n "$outside" ]; then
      echo "$binary loads libraries outside /System and /usr/lib:" >&2
      echo "$outside" >&2
      exit 1
    fi
    ;;
  *)
    ldd "$binary" || true
    ;;
esac
