cask "thysql" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.0"
  # tools/update_cask.sh fills these in from the release's SHA256SUMS.
  sha256 arm:   "82fbae279e8f3a02353ee655b39185484d20ecaa3efaec76e1967d5a1d42bbaf",
         intel: "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/jeffrom/thysql/releases/download/v#{version}/thysql-#{version}-darwin-#{arch}.tar.gz"
  name "thysql"
  desc "MySQL/MariaDB command-line client"
  homepage "https://github.com/jeffrom/thysql"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

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
