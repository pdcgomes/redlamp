cask "redlamp" do
  # version and sha256 are rewritten by .github/workflows/cask.yml on every release.
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/pdcgomes/redlamp/releases/download/v#{version}/Redlamp-#{version}.zip"
  name "Redlamp"
  desc "Native raw photo editor"
  homepage "https://github.com/pdcgomes/redlamp"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

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
