Recommended local install flow:

1. In Xcode, open the whisper target → Signing & Capabilities
   - Enable Automatically manage signing
   - Pick your Team (Personal Team is fine for local use)
2. Build a Release app bundle:
`xcodebuild -project whisper.xcodeproj -scheme whisper -configuration Release -derivedDataPath build clean build`
3. Install it by copying the built .app into /Applications:
`cp -R "build/Build/Products/Release/whisper.app" /Applications/`
4. Launch from /Applications (not from DerivedData):
`open /Applications/whisper.app`
5. Grant Mic + Accessibility when prompted.

Why /Applications matters
    - Your new Run on Startup toggle uses `SMAppService.mainApp`; it works most reliably when the app is installed in `/Applications` and properly signed.

If macOS blocks launch
    - Right-click app → Open once, or remove quarantine:
`xattr -dr com.apple.quarantine /Applications/whisper.app`
