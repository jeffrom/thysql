# Plan: release pipeline and Homebrew cask

Tagging `vX.Y.Z` builds thysql for macOS and Linux, attaches tarballs to a GitHub
release, and a cask in this repo (`Casks/thysql.rb`) installs the macOS build:

```sh
brew tap jeffrom/thysql https://github.com/jeffrom/thysql
brew install --cask thysql
```

## Decisions

| Topic | Decision |
|---|---|
| Signing | No Apple Developer ID. Binaries are ad-hoc signed (Zig's linker already does this on arm64; `codesign -s -` makes it explicit for both arches). The cask's `postflight` removes `com.apple.quarantine`. Notarization can be added later without changing the layout. |
| Platforms | `darwin-arm64`, `darwin-x86_64`, `linux-x86_64`, `linux-arm64`. One tarball each; no universal binary. |
| Tap | `Casks/` in this repo. No second repo. |
| Version source | `build.zig.zon` `.version` is the single source. The tag must match it; CI fails if not. |
| macOS linkage | Release builds link OpenSSL and zstd **statically**, so the binary needs nothing from Homebrew. Only `/System/...` and `/usr/lib/...` may appear in `otool -L`. Kerberos stays the system framework. |
| Linux linkage | Dynamic (OpenSSL, zstd, krb5). Built on `ubuntu-22.04` runners for an older glibc baseline. The release notes list the runtime packages (`libssl3 libzstd1 libkrb5-3 libgssapi-krb5-2`). The Docker image remains the zero-dependency Linux option. |
| License | Decided: thysql's own code is GPL-2.0-or-later with an OpenSSL linking exception (`LICENSE`, full text in `COPYING`). The Oracle grammar files are GPL-2.0-only, so binaries ship under GPLv2. Step 3 writes `THIRD_PARTY_NOTICES` from the submodules' license files plus OpenSSL's and zstd's. |
| Cask updates | Done locally, not by CI, so CI never commits to `main` (main is local-first; pushing stays your call). |

## Open questions

1. **Minimum macOS.** Homebrew's static `libssl.a` is built for the runner's macOS
   version, so the binary's floor is the runner's (macOS 14 on `macos-14`). Good
   enough, or build OpenSSL from source with a lower `MACOSX_DEPLOYMENT_TARGET`?
2. **Intel runner.** `macos-13` is retired; use `macos-15-intel` while GitHub
   still offers it. Alternative: cross-compile x86_64 on arm64 — fails today
   because the MariaDB cmake step and Homebrew static libs are host-arch.

## Steps

Each step is one or more commits on `main` with `zig build test` green.

### 1. Version plumbing

- `build.zig`: read `.version` from `build.zig.zon` (`@import("build.zig.zon")`
  works in Zig 0.17) and allow override with `-Dversion=...`. Expose it through
  `b.addOptions()` as `build_options.version`, plus `-Dcommit=<sha>` (optional).
- `src/root.zig` `renderVersion`: print
  `thysql <version> (<commit>), client library <x>`.
- Bump `build.zig.zon` to `0.1.0`.
- Unit test that `--version` output starts with `thysql 0.1.0`.

### 2. Static macOS build option

- `build.zig`: `-Dstatic-deps=true` makes `linkMariaDbSystemLibraries` link
  `ssl`, `crypto`, `zstd` with `.preferred_link_mode = .static` (and passes the
  matching OpenSSL root to `tools/build_mariadb_static.sh` so cmake finds the same
  OpenSSL; add `-DOPENSSL_USE_STATIC_LIBS=ON`).
- Replace the hardcoded `/opt/homebrew/lib` default with
  `$(brew --prefix openssl@3)/lib` semantics: keep `-Dopenssl-lib-dir`, add
  `-Dzstd-lib-dir`, and have CI pass both explicitly. (Locally you have
  `openssl@4`; CI pins `openssl@3`, the LTS line.)
- `tools/check_linkage.sh <binary>`: on macOS, fail if `otool -L` lists anything
  outside `/System/` and `/usr/lib/`; on Linux, print `ldd` for the release notes.

### 3. Packaging script

`tools/package.sh <version> <os> <arch>` builds with
`-Doptimize=ReleaseSafe -Dstatic-deps=<mac only>`, runs `check_linkage.sh`,
ad-hoc signs on macOS (`codesign --force -s - thysql`), and writes:

```
dist/thysql-<version>-<os>-<arch>.tar.gz
  thysql-<version>-<os>-<arch>/
    thysql
    completions/thysql.bash      # from `thysql completion bash`
    README.md
    LICENSE
    COPYING
    THIRD_PARTY_NOTICES
```

ReleaseSafe rather than ReleaseFast: keeps safety checks in a tool that parses
untrusted server output; the speed difference is irrelevant for a REPL.

### 4. CI workflow (`.github/workflows/ci.yml`)

On push and pull request: checkout with `submodules: recursive`,
`mlugg/setup-zig@v2` pinned to `0.17.1`, then `zig build test` on `macos-14` and
`ubuntu-22.04`. `zig build e2e` on Ubuntu only (Docker is available there, not on
macOS runners). Gives the release workflow a known-good baseline.

### 5. Release workflow (`.github/workflows/release.yml`)

Trigger: `push: tags: ['v*']` (plus `workflow_dispatch` for dry runs that skip
publishing).

1. **verify** job: fail if the tag (minus `v`) ≠ `build.zig.zon` version.
2. **build** matrix:

   | os | arch | runner | deps |
   |---|---|---|---|
   | darwin | arm64 | `macos-14` | `brew install openssl@3 zstd cmake` |
   | darwin | x86_64 | `macos-15-intel` | same |
   | linux | x86_64 | `ubuntu-22.04` | `apt install cmake libssl-dev libzstd-dev libkrb5-dev` |
   | linux | arm64 | `ubuntu-22.04-arm` | same |

   Each runs `zig build test`, then `tools/package.sh`, then a smoke test
   (`./thysql --version`, and `thysql completion bash | bash -n`). Upload the
   tarball as an artifact.
3. **release** job: download artifacts, write `SHA256SUMS`, and
   `gh release create "$TAG" dist/* --generate-notes --draft`. Draft so you can
   eyeball it before publishing; drop `--draft` once the pipeline is trusted.

Permissions: `contents: write` on the release job only. No secrets needed beyond
`GITHUB_TOKEN`.

### 6. Cask (`Casks/thysql.rb`)

```ruby
cask "thysql" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.0"
  sha256 arm:   "<from SHA256SUMS>",
         intel: "<from SHA256SUMS>"

  url "https://github.com/jeffrom/thysql/releases/download/v#{version}/thysql-#{version}-darwin-#{arch}.tar.gz"
  name "thysql"
  desc "MySQL/MariaDB command-line client"
  homepage "https://github.com/jeffrom/thysql"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  binary "thysql-#{version}-darwin-#{arch}/thysql"
  bash_completion "thysql-#{version}-darwin-#{arch}/completions/thysql.bash"

  # Not notarized: remove the quarantine bit so Gatekeeper doesn't block it.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-d", "com.apple.quarantine",
                          "#{staged_path}/thysql-#{version}-darwin-#{arch}/thysql"],
                   must_succeed: false
  end

  zap trash: "~/.config/thysql"
end
```

`zap` only runs on `brew uninstall --zap`; it removes saved connections, so
keep it or drop it per taste.

### 7. Release scripts

- `tools/release.sh <version>`: require a clean tree on `main`, set
  `build.zig.zon` version, commit `release: v<version>`, create the annotated
  tag. Prints the push command; it does **not** push.
- `tools/update_cask.sh <version>`: `gh release download v<version> -p SHA256SUMS`,
  rewrite `version` and both `sha256` lines in `Casks/thysql.rb`,
  `brew style --fix Casks/thysql.rb`, `brew audit --cask --strict thysql`,
  commit `cask: thysql <version>`.

Release flow:

```sh
tools/release.sh 0.1.0
git push origin main v0.1.0         # you run this
# wait for the release workflow, publish the draft
tools/update_cask.sh 0.1.0
git push origin main                # you run this
```

### 8. Verify end to end, then document

- On a clean-ish Mac (or after `brew uninstall`): `brew tap jeffrom/thysql
  https://github.com/jeffrom/thysql && brew install --cask thysql`, then
  `thysql --version`, `xattr -l $(which thysql)` shows no quarantine,
  `otool -L $(which thysql)` shows only system libs, connect to the e2e MySQL
  container.
- On Ubuntu 22.04 and 24.04 containers: untar, install the runtime packages,
  `thysql --version`.
- README: an "install" section (cask, Linux tarball + packages, Docker) and a
  short "releasing" section pointing at step 7.

## Risks

- **Quarantine workaround.** Homebrew removed `--no-quarantine`, and the
  postflight `xattr` is a known pattern for personal taps but is unofficial. If a
  future Homebrew blocks it, the fix is notarization (step 3 adds
  `codesign --options runtime` with a Developer ID + `notarytool submit --wait`;
  the cask drops the postflight).
- **Static OpenSSL on macOS.** If MariaDB's cmake insists on the dylib, point it
  at a directory with only the `.a` files (copy them to a temp dir in
  `package.sh`).
- **Intel runner availability.** If `macos-15-intel` goes away, drop
  `darwin-x86_64` and the cask's `arch` stanza becomes arm-only
  (`depends_on arch: :arm64`).
