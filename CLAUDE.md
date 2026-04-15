# Product constraints
- Target only iPhone 17 Pro.
- Minimum OS is iOS 26.0 (simulator has 26.2; device target is 26.4+).
- No backward-compatibility code paths.
- Host app is native SwiftUI.
- React Native is used only for the Preview runtime.
- Use current bare React Native with Hermes V1 and New Architecture.
- On-device model is Gemma 4 E2B via LiteRT-LM GPU backend.
- On-device TS/TSX transform is Oxc in Rust.
- Never add tsserver, tsgo, Monaco, Expo, Metro, or Node to the iOS runtime.
- The Code screen is read-only syntax-highlighted source; the user is not the primary coder.
- Generated TS may import only from react, react-native, and @app/*.

# Native capability rules
- All powerful device features must come through shipped TurboModules/Fabric components.
- Every interactive UI element must have a stable accessibility identifier.
- Every screen must expose a deterministic smoke-test path.

# Build & test
- Use Xcode 26.4 with iOS 26.0+ SDK.
- XcodeGen generates the project from project.yml.
- Build: `xcodebuild -project Pucky.xcodeproj -scheme Pucky -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Test: `xcodebuild -project Pucky.xcodeproj -scheme Pucky -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`

# Required completion loop
- Build after every substantial change.
- Treat warnings as failures unless explicitly waived.
- Run UI smoke tests after every task.
- Launch Simulator and verify the changed path.
- Capture at least one screenshot for UI-affecting changes.
- Summarize files changed, tests run, warnings fixed, and remaining blockers.
