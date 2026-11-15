#!/bin/sh
# Points Casks/thysql.rb at a published release: version and both sha256 values come from the
# release's SHA256SUMS. Commits "cask: thysql <version>" and never pushes.
# Usage: tools/update_cask.sh <version> [--sums FILE]
# Without --sums, the file is downloaded with gh from the published release v<version>.
set -eu

usage() {
  echo "usage: $0 <version> [--sums FILE]" >&2
  exit 2
}

die() {
  echo "update_cask: $*" >&2
  exit 1
}

if [ "$#" -lt 1 ]; then
  usage
fi
version=$1
shift
sums=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sums)
      [ "$#" -ge 2 ] || usage
      sums=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
  die "invalid version '$version': want X.Y.Z or X.Y.Z-prerelease"
fi

cd "$(git rev-parse --show-toplevel)"

branch=$(git symbolic-ref -q --short HEAD || true)
if [ "$branch" != main ]; then
  die "must be on main (currently ${branch:-a detached HEAD})"
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "tracked files have uncommitted changes; commit or stash them first"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "$sums" ]; then
  [ -r "$sums" ] || die "cannot read $sums"
  sums_file=$sums
else
  # Works once the release is published; a draft is not visible to this download.
  if ! gh release download "v$version" -p SHA256SUMS -D "$tmp" >/dev/null 2>&1; then
    die "could not download SHA256SUMS for v$version (publish the release first, or pass --sums FILE)"
  fi
  sums_file=$tmp/SHA256SUMS
fi

# Prints the sha256 of one tarball from SHA256SUMS. Fails unless exactly one line names it.
sha_for() {
  awk -v name="$1" '
    {
      f = $2
      sub(/^\*/, "", f)
      sub(/.*\//, "", f)
      if (f == name) { sha = $1; n++ }
    }
    END { if (n == 1) print sha; else exit 1 }
  ' "$sums_file"
}

arm_name="thysql-$version-darwin-arm64.tar.gz"
intel_name="thysql-$version-darwin-x86_64.tar.gz"
arm_sha=$(sha_for "$arm_name") || die "$sums_file has no single entry for $arm_name"
intel_sha=$(sha_for "$intel_name") || die "$sums_file has no single entry for $intel_name"
for sha in "$arm_sha" "$intel_sha"; do
  if ! printf '%s\n' "$sha" | grep -Eq '^[0-9a-f]{64}$'; then
    die "malformed sha256 in $sums_file: $sha"
  fi
done

cask=Casks/thysql.rb
sed -i.bak \
  -e "s/^\(  version \"\)[^\"]*\"/\1$version\"/" \
  -e "s/\(arm: *\"\)[0-9a-f]*\"/\1$arm_sha\"/" \
  -e "s/\(intel: *\"\)[0-9a-f]*\"/\1$intel_sha\"/" \
  "$cask"
rm -f "$cask.bak"

if ! grep -Eq "^  version \"$version\"\$" "$cask" ||
  ! grep -Fq "\"$arm_sha\"" "$cask" || ! grep -Fq "\"$intel_sha\"" "$cask"; then
  git checkout -- "$cask"
  die "could not update $cask; file restored"
fi

# Homebrew's style check; --fix first, then a check that must pass with no offenses.
HOMEBREW_NO_AUTO_UPDATE=1 brew style --fix "$cask"
HOMEBREW_NO_AUTO_UPDATE=1 brew style "$cask"

if git diff --quiet -- "$cask"; then
  echo "update_cask: $cask already has $version and these sha256 values; nothing to commit"
  exit 0
fi

git add "$cask"
git commit -q -m "cask: thysql $version"
echo "update_cask: committed $(git rev-parse --short HEAD) for $version; nothing was pushed"
echo "update_cask: to publish, run: git push origin main"
