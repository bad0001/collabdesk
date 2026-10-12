# iOS assets provenance

The iPhone and Apple Watch app icons are original Core Graphics geometry rendered by `tools/make-icon.swift`. The source generator reproduced both 1024×1024 PNG files byte-for-byte during the source-publication audit. No photographs, Tempo screenshots, fonts, or copied third-party artwork are included.

Regenerate on macOS:

```sh
swift tools/make-icon.swift CollabDesk/Assets.xcassets/AppIcon.appiconset/AppIcon.png
swift tools/make-icon.swift CollabDeskWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

SwiftUI SF Symbols are referenced by system symbol names in the application source. Their glyph files are not distributed in this repository; use remains subject to Apple's terms.

The original icon PNG files and generator are covered by the root PolyForm Noncommercial License 1.0.0. Retain the root LICENSE and NOTICE when distributing; this document grants no separate commercial-use license.
