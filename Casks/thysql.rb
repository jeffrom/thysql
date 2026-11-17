cask "thysql" do
  arch arm: "arm64", intel: "x86_64"

  version "0.4.1"
  # tools/update_cask.sh fills these in from the release's SHA256SUMS.
  sha256 arm:   "9dd367dcadffe3ad8f1ef00c593c5e787ad6aefbddb307a6ee752c66474f7e65",
         intel: "05a31393ad3d8e52d2213f52ca05fc95b9bf22bc98fc0f8787b16a6ffadda7c9"

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
