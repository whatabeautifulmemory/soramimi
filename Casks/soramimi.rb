cask "soramimi" do
  version "1.0.0"
  sha256 "62469c3463ea87dced136ef981b45afc3fa6b86befb61f99e7962abce7a93092"

  url "https://github.com/whatabeautifulmemory/soramimi/releases/download/v#{version}/Soramimi-#{version}.zip"
  name "Soramimi"
  desc "Keeps Bluetooth speakers awake and blocks Apple Music/iTunes launches"
  homepage "https://github.com/whatabeautifulmemory/soramimi"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "Soramimi-#{version}/Soramimi.app"

  # Ad-hoc signed (no Developer ID): Homebrew strips quarantines on install, but
  # the extracted app can still carry one. Remove it so the first launch does not
  # hit Gatekeeper's "cannot verify" dialog, same as the Vineyard cask.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Soramimi.app"], must_succeed: false
  end

  uninstall quit: "local.soramimi"

  zap trash: [
    "~/Library/Preferences/local.soramimi.plist",
    "~/Library/Saved Application State/local.soramimi.savedState",
  ]

  caveats <<~EOS
    Disable "Launch at Login" before uninstalling so the login item is removed.
  EOS
end
