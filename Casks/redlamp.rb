cask "redlamp" do
  # version and sha256 are rewritten by .github/workflows/cask.yml on every release.
  version "0.3.5-alpha"
  sha256 "8cc803e4d9258c0fe4c384b3f7b0f7a978f17e07f356c8ce76b0069c29a81f92"

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
