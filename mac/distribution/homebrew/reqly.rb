# The Homebrew cask for Reqly. It lives in a tap, a repository named homebrew-<name>, until
# Reqly is well known enough for Homebrew's own list.
# Each release changes the version and the checksum, from the .sha256 file next to the zip.
cask "reqly" do
  version "1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/parsamlm/reqly/releases/download/v#{version}/Reqly-#{version}.zip"
  name "Reqly"
  desc "Inspect and debug the network traffic of your apps and devices"
  homepage "https://reqly.net/"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Reqly installs its own updates, with Sparkle, so Homebrew leaves them to it.
  auto_updates true
  depends_on macos: :tahoe

  app "Reqly.app"

  # The helper sets the Mac's proxy while Reqly captures.
  uninstall quit:      "net.reqly.Reqly",
            launchctl: "net.reqly.Reqly.Helper"

  zap trash: [
    "~/Library/Application Support/Reqly",
    "~/Library/Caches/net.reqly.Reqly",
    "~/Library/HTTPStorages/net.reqly.Reqly",
    "~/Library/Preferences/net.reqly.Reqly.plist",
    "~/Library/Saved Application State/net.reqly.Reqly.savedState",
  ]
end
