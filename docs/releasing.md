# Releasing

The checklist for cutting a thysql release. The scripts never push and never touch GitHub:
`tools/release.sh` and `tools/update_cask.sh` change local files and commit or tag them. You run
the pushes. `X.Y.Z` below stands for the version, which must match `.version` in
`build.zig.zon`.

## Before the first release

Do these once, before the first tag.

1. Push `main`. GitHub only runs a workflow by hand once its file is on the default branch.

   ```sh
   git push origin main
   ```

2. Run the release workflow as a dry run. In the GitHub UI: Actions, then `release`, then
   Run workflow, on `main`, with `version` set to the version in `build.zig.zon` (`0.1.0` for
   the first release). Or from a shell: `gh workflow run release.yml -f version=0.1.0`.

3. Check that all four build jobs pass: darwin arm64 (`macos-15`), darwin x86_64
   (`macos-15-intel`), linux x86_64 and linux arm64 (`ubuntu-22.04-arm`). The `release` job is
   skipped on a manual run by design, so no draft is created.

4. Check that the CI workflow passed on the same push: `test` (macOS and Ubuntu), `e2e`, and
   `static-macos`.

5. If `macos-15-intel` is not offered, follow [the Intel runner troubleshooting](#macos-15-intel-is-unavailable)
   before you tag.

## Each release

1. Preview the release. This needs a clean tree on `main`, and it changes nothing.

   ```sh
   tools/release.sh X.Y.Z --dry-run
   ```

2. Cut the release. If `build.zig.zon` already says `X.Y.Z`, as for the first release, no commit
   is made and the tag goes on `HEAD`. Otherwise the script sets `.version`, runs `zig build test`,
   commits `release: vX.Y.Z`, and creates the annotated tag.

   ```sh
   tools/release.sh X.Y.Z
   ```

3. Push `main` and the tag. The tag push starts `.github/workflows/release.yml`.

   ```sh
   git push origin main vX.Y.Z
   ```

4. Wait for the release workflow: `verify`, then the four `build` jobs, then `release`. The
   `release` job creates a draft with the four tarballs and `SHA256SUMS`.

5. Review the draft on GitHub. Check that all four tarballs and `SHA256SUMS` are attached, the
   version is right, and the notes are correct. Then publish it: Releases, then Edit, then
   Publish release.

6. Point the cask at the release. This downloads `SHA256SUMS` from the published release, sets
   the version and both sha256 values in `Casks/thysql.rb`, runs `brew style`, and commits
   `cask: thysql X.Y.Z`.

   ```sh
   tools/update_cask.sh X.Y.Z
   ```

7. Push `main`.

   ```sh
   git push origin main
   ```

## After the first published release

Run these once, after the first release is published. They use the real tap and the real
release assets, so they cannot run before then. The steps are the end-to-end check from the
plan's step 8.

### macOS

Start from a clean state. `brew uninstall --cask thysql` leaves saved connections alone. Do
not use `--zap` here, because it deletes `~/.config/thysql`.

```sh
brew uninstall --cask thysql 2>/dev/null || true
brew untap jeffrom/thysql 2>/dev/null || true
brew tap jeffrom/thysql https://github.com/jeffrom/thysql
brew install --cask thysql
thysql --version                                              # starts with "thysql 0.1.0"
xattr -l "$(readlink -f "$(which thysql)")"                   # no com.apple.quarantine line
sh tools/check_linkage.sh "$(readlink -f "$(which thysql)")"  # exits 0; only /System and /usr/lib
```

Then connect to the e2e MySQL 8.4 container. Start the e2e containers and keep them. The suite
runs in full, and `-- -k select` narrows it:

```sh
THYSQL_E2E_KEEP=1 zig build e2e
port=$(docker port thysql-e2e-mysql-keep 3306/tcp | sed 's/.*://')
printf 'select version();\n' | MYSQL_PWD=e2e-root-pw thysql -h 127.0.0.1 -P "$port" -u root
```

The query should print an `8.4.x` version. The password is the throwaway `ROOT_PASSWORD` in
`tests/e2e/harness.py`. When you are done, remove the containers:

```sh
docker rm -f -v $(docker ps -aq --filter label=thysql-e2e=1)
```

### Linux

Run this in fresh Ubuntu 22.04 and 24.04 containers. It downloads the
tarball, checks it against `SHA256SUMS`, installs the runtime packages, and runs `--version`.

```sh
V=X.Y.Z
for rel in 22.04 24.04; do
  docker run --rm --platform linux/amd64 -e V="$V" "ubuntu:$rel" sh -c '
    set -eu
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null
    apt-get install -y -qq --no-install-recommends libssl3 libzstd1 libkrb5-3 libgssapi-krb5-2 >/dev/null
    cd /tmp
    base=https://github.com/jeffrom/thysql/releases/download/v$V
    curl -fsSLO "$base/thysql-$V-linux-x86_64.tar.gz"
    curl -fsSLO "$base/SHA256SUMS"
    sha256sum --ignore-missing -c SHA256SUMS
    tar -xzf "thysql-$V-linux-x86_64.tar.gz"
    "thysql-$V-linux-x86_64/thysql" --version
  '
done
```

For arm64, use `linux-arm64` in the file names and `--platform linux/arm64`.

## Troubleshooting

### macos-15-intel is unavailable

Symptom: the `darwin x86_64` build job stays queued, or GitHub reports that the runner label
does not exist. The `release` job needs all four build jobs, so one missing job blocks the whole
release. The plan's Risks section has the fallback: drop Intel and ship arm64 only.

1. Remove the `darwin` / `x86_64` row from the `build` matrix in `.github/workflows/release.yml`.
2. In `tools/update_cask.sh`, stop requiring the `darwin-x86_64` entry in `SHA256SUMS`. The
   script currently fails without it.
3. In `Casks/thysql.rb`, drop the `arch` stanza and the `intel:` sha256, use `arm64` in place
   of `#{arch}` in the url, `binary`, `bash_completion` and `postflight` lines, and add
   `depends_on arch: :arm64`.
4. Update the README's install section, which says the cask covers Intel.

### Gatekeeper still blocks the binary

Check what macOS thinks of it:

```sh
spctl --assess --type execute -v "$(readlink -f "$(which thysql)")"
```

Quick fix on one machine: remove the quarantine bit yourself.

```sh
xattr -d com.apple.quarantine "$(readlink -f "$(which thysql)")"
```

Real fix: notarize, as the plan's Risks section describes. This needs an Apple Developer ID
certificate and an App Store Connect API key or app-specific password for `notarytool`.

1. Sign with the hardened runtime in `tools/package.sh`, in place of `codesign -s -`:
   `codesign --force --options runtime --timestamp -s "Developer ID Application: <name> (<team>)" thysql`.
2. Zip the binary and submit it: `xcrun notarytool submit thysql.zip --keychain-profile <profile> --wait`.
3. Expect no stapling. A bare binary cannot be stapled, so Gatekeeper checks Apple's service
   online at first run.
4. Remove the `postflight_steps` block from `Casks/thysql.rb`.
5. Add the certificate and notary credentials to the release workflow as secrets.

### update_cask.sh cannot download SHA256SUMS

The error reads `could not download SHA256SUMS for vX.Y.Z (publish the release first, or pass
--sums FILE)`. `gh release download` does not see drafts, so the release must be published first.

- Publish the draft, then run `tools/update_cask.sh X.Y.Z` again.
- Or download `SHA256SUMS` from the draft's page in the browser (signed in, with write access),
  then run `tools/update_cask.sh X.Y.Z --sums ~/Downloads/SHA256SUMS`.

If the script says `has no single entry for ...`, the file lacks a line for one of the two
darwin tarballs. Check the file names in the draft.

Check `gh auth status` if the download fails for any other reason.

### A build job failed

Re-run the failed job from the Actions run for the tag. The `release` job runs only on a tag push,
so a manual run never creates a draft.
