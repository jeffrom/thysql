#!/bin/sh
# Cuts a release: sets build.zig.zon's .version, runs the tests, commits "release: v<version>"
# and creates the annotated tag v<version>. Never pushes; it prints the push command.
# Usage: tools/release.sh <version> [--dry-run]
# When build.zig.zon already has <version>, no commit is made and the tag goes on HEAD.
set -eu

usage() {
  echo "usage: $0 <version> [--dry-run]" >&2
  exit 2
}

die() {
  echo "release: $*" >&2
  exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
fi
version=$1
dry_run=0
if [ "$#" -eq 2 ]; then
  [ "$2" = --dry-run ] || usage
  dry_run=1
fi

# X.Y.Z with an optional -prerelease. Build metadata is not accepted.
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
  die "invalid version '$version': want X.Y.Z or X.Y.Z-prerelease"
fi

cd "$(git rev-parse --show-toplevel)"

branch=$(git symbolic-ref -q --short HEAD || true)
if [ "$branch" != main ]; then
  die "must be on main (currently ${branch:-a detached HEAD})"
fi

# Untracked files are ignored; only changes to tracked files would end up in the wrong commit.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "tracked files have uncommitted changes; commit or stash them first"
fi

tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  die "tag $tag already exists"
fi

current=$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon)
if [ -z "$current" ]; then
  die "could not read .version from build.zig.zon"
fi
push_cmd="git push origin main $tag"

if [ "$dry_run" -eq 1 ]; then
  if [ "$current" != "$version" ]; then
    echo "dry-run: set build.zig.zon .version $current -> $version"
  else
    echo "dry-run: build.zig.zon is already $version, so no release commit; $tag goes on HEAD"
  fi
  echo "dry-run: zig build test"
  if [ "$current" != "$version" ]; then
    echo "dry-run: commit 'release: $tag' with build.zig.zon only"
  fi
  echo "dry-run: create annotated tag $tag (message 'thysql $version')"
  echo "dry-run: nothing changed. To publish: $push_cmd"
  exit 0
fi

if [ "$current" != "$version" ]; then
  sed -i.bak "s/^\([[:space:]]*\.version[[:space:]]*=[[:space:]]*\)\"[^\"]*\"/\1\"$version\"/" build.zig.zon
  rm -f build.zig.zon.bak
  if ! grep -Eq "^[[:space:]]*\.version[[:space:]]*=[[:space:]]*\"$version\"" build.zig.zon; then
    git checkout -- build.zig.zon
    die "could not set .version in build.zig.zon; file restored"
  fi
  echo "release: build.zig.zon .version $current -> $version"
fi

echo "release: running zig build test"
if ! zig build test; then
  git checkout -- build.zig.zon
  die "zig build test failed; build.zig.zon restored"
fi

if [ "$current" != "$version" ]; then
  git add build.zig.zon
  git commit -q -m "release: $tag"
fi
git tag -a "$tag" -m "thysql $version"

echo "release: tagged $(git rev-parse --short HEAD) as $tag; nothing was pushed"
echo "release: to publish, run: $push_cmd"
