# CollabDesk iOS / Watch / Widgets

This is the generic source-available client for noncommercial use. No personal signing configuration, generated Xcode project, live connection fixture, credentials, or private device data is included.

## Build a simulator

Requires macOS, Xcode with iOS/watchOS SDKs, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cp LocalSigning.xcconfig.example LocalSigning.xcconfig
xcodegen generate
xcodebuild -project CollabDesk.xcodeproj -scheme CollabDesk \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/simulator build CODE_SIGNING_ALLOWED=NO
```

Do not pass a global `-sdk iphonesimulator`: it overrides the embedded Watch target's SDK.

For tests that use the simulator Keychain, use an ad-hoc signed simulator build:

```sh
xcodebuild -project CollabDesk.xcodeproj -scheme CollabDesk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

Choose an installed simulator model name for your local Xcode runtime.

## Personalize before device installation

1. Enter your own Team ID in the ignored `LocalSigning.xcconfig` file.
2. Replace the generic `org.example.collabdesk` namespace consistently in `project.yml`, both `.entitlements` files, and the Swift sources (including `Shared/GlanceSnapshot.swift` and Keychain service names). App, Widget, Watch companion IDs and App Group must agree.
3. Enable App Groups and Push Notifications for your own identifiers and configure your own APNs server/topic. Development Xcode installs use Sandbox APNs.
4. Build the generated Xcode project and install without removing an existing app whose data you want to keep.

The onboarding address defaults to `https://api.example.com`. Users connect to their own HTTPS deployment from Settings; no real service is pre-connected. For the bundled public AI-guide links, set `ConnectionGuide.suggestedAddress` to your public deployment URL or share that deployment's `/guide/` links directly.

## Tests and optional integration checks

All included JSON/text fixtures are synthetic. The default tests use demo state and ephemeral fixture requests. Optional live UI integration checks are skipped unless these environment values are explicitly supplied for a disposable **HTTP loopback** QA server:

- `COLLABDESK_QA_URL`
- `COLLABDESK_QA_ADMIN_TOKEN`
- `COLLABDESK_QA_LEADER_TOKEN`

Do not put tokens in source, generated project files, shared test schemes, or a bundled `qa-connection.json`.

## SMS automation

The manual extraction action and the independent background automatic-ingest action are both included. Auto ingestion requires one explicit opt-in for the current user, workspace and installation; it uses a separate upload-only capability stored in the device-only Keychain. It does not read SMS history, send full SMS bodies, share code values with all workers, or log/cache/retry SMS content. iOS and network scheduling still control whether a particular automation runs under lock screen.

See `ASSETS.md` for icon provenance. The client is covered by the root PolyForm Noncommercial 1.0.0 license; retain LICENSE and NOTICE when distributing.
