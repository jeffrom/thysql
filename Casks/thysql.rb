cask "thysql" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.0"
  # tools/update_cask.sh fills these in from the release's SHA256SUMS.
  sha256 arm:   "0cbbf41822457a5d88342f099deaf8e9c55ceda2bd83a3ce728e0f832c6ddb68",
         intel: "273922820e95f2e8caa2f0caf6a1955b94c3d494339063bb1dbbbb4c71445961"

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
