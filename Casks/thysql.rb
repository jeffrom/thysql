cask "thysql" do
  arch arm: "arm64", intel: "x86_64"

  version "0.4.2"
  # tools/update_cask.sh fills these in from the release's SHA256SUMS.
  sha256 arm:   "86b8ebca230975d60d1299eb23772896326f809f49978c6a5ee489ddbe35b1da",
         intel: "0313acde9d85c20db74a1665a862e25d4046f6dc8d9bb2f4fb5fc9168da39be1"

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
