cask "thysql" do
  arch arm: "arm64", intel: "x86_64"

  version "0.4.5"
  # tools/update_cask.sh fills these in from the release's SHA256SUMS.
  sha256 arm:   "5adba6b737c00bdcfb77e7da1a8182e88db884cd4149595f930e042d8ac1441c",
         intel: "814ce326de6abd3e9a804866d53baf26b20deaecc2a7d02ad42e7677e5433ef0"

  url "https://github.com/jeffrom/thysql/releases/download/v#{version}/thysql-#{version}-darwin-#{arch}.tar.gz"
  name "thysql"
  desc "MySQL/MariaDB command-line client"
  homepage "https://github.com/jeffrom/thysql"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  binary "thysql-#{version}-darwin-#{arch}/thysql"
  bash_completion "thysql-#{version}-darwin-#{arch}/completions/thysql.bash"

  # Not notarized: remove the quarantine bit so Gatekeeper doesn't block it.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-d", "com.apple.quarantine", "thysql"],
        chdir:          "thysql-#{version}-darwin-#{arch}",
        writable_paths: ["thysql-#{version}-darwin-#{arch}/thysql"],
        must_succeed:   false
  end

  zap trash: [
    "~/.config/thysql",
    "~/.local/state/thysql",
  ]
end
