cask "thysql" do
  arch arm: "arm64", intel: "x86_64"

  version "0.2.0"
  # tools/update_cask.sh fills these in from the release's SHA256SUMS.
  sha256 arm:   "c5bee6b6d1c0cfae78544b18cd4cbeecbf96bb300cb88d9f655b5f76aa747c55",
         intel: "04cd3dad64d5ee1189e7ce70e3665326ac32f7eabd6c239ca6f2c54fe9759061"

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
