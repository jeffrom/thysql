cask "thysql" do
  arch arm: "arm64", intel: "x86_64"

  version "0.4.3"
  # tools/update_cask.sh fills these in from the release's SHA256SUMS.
  sha256 arm:   "49954cefaa143e2906d24eab1edd8341966e0500e9229df78dbd0a80f4506f19",
         intel: "67c831e19e9de9819baaddd368bb10c96cbe976cd045c72d66b0825c41480bc0"

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
