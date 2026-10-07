cask "redlamp" do
  # version and sha256 are rewritten by .github/workflows/cask.yml on every release.
  version "0.2.5-prealpha"
  sha256 "92440c0df3734596ffe3e5de358ad9b2e30127b565a9b582df1d5fe16b25844a"

  url "https://github.com/pdcgomes/redlamp/releases/download/v#{version}/Redlamp-#{version}.zip"
  name "Redlamp"
  desc "Native raw photo editor"
  homepage "https://github.com/pdcgomes/redlamp"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Redlamp.app"
  binary "#{appdir}/Redlamp.app/Contents/Helpers/redlamp"

  zap trash: [
    "~/Library/Application Support/Redlamp",
    "~/Library/Caches/app.redlamp.mac",
    "~/Library/HTTPStorages/app.redlamp.mac",
    "~/Library/Preferences/app.redlamp.mac.plist",
    "~/Library/Saved Application State/app.redlamp.mac.savedState",
  ]
end
