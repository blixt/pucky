# Pucky

Offline vibe coder for your iPhone using Gemma 4 and Oxc.

Describe an app in chat, watch Gemma 4 edit a single TSX or TS file on-device, and see the result render live in an embedded WKWebView — no network, no Metro, no Expo, no laptop.

## What's inside

- **Native SwiftUI host** — three tabs (Code, Chat, Preview), dark theme, iPhone 17 Pro only.
- **Gemma 4 E2B** via [Gemma4SwiftCore](https://github.com/yejingyang8963-byte/Swift-gemma4-core) on an MLX GPU backend. Streaming tool calls drive a `edit_code` / `replace_code` loop against one editable file.
- **Oxc in Rust** (`rust/oxc-bridge`) — a `staticlib` shipped as `OxcBridge.xcframework` that parses, type-strips, and transforms TS/TSX to ES modules at keystroke speed.
- **In-app preview runtime** — a hand-rolled React / React Native shim (View, Text, Pressable, ScrollView, TextInput, StyleSheet, Flexbox, hooks) plus a Three.js template, both loaded into WKWebView via import maps. Zero Node, zero bundler.

## Templates

- **App (React Native)** — imports from `react` / `react-native`, default-exports a root component.
- **3D (Three.js)** — imports `three`, default-exports `setup(canvas)` with a teardown callback.

Both templates expose exactly one editable file to the model, so Gemma 4 never has to invent paths or juggle a filesystem.

## Build

```bash
xcodegen generate
xcodebuild -project Pucky.xcodeproj -scheme Pucky \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Requires Xcode 26.4 and the iOS 26.0 SDK. The Rust bridge is rebuilt with `rust/oxc-bridge/build-ios.sh`.
