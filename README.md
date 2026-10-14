# Folio

An offline-first SwiftUI receipt organiser for the UTS Advanced iOS Development team.
The shared foundation is implemented; scanner, library, dashboard and reminder screens remain feature work.

## Run

Use Xcode 26.2 or later with the iOS 26.2 SDK and simulator runtime. The existing minimum deployment target is iOS 26.2.

```sh
git clone https://github.com/Divy3122/Folio-iOS.git
cd Folio-iOS
git switch develop
open Folio/Folio.xcodeproj
```

Select the Folio scheme and an iOS simulator. Physical-device builds require your own signing team.

```sh
xcodebuild -project Folio/Folio.xcodeproj -scheme Folio -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Folio/Folio.xcodeproj -scheme Folio -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FolioTests CODE_SIGNING_ALLOWED=NO test
```

Sources live under `Folio/Folio/`. Xcode uses filesystem-synchronized folders: do not add duplicate explicit Compile Sources entries.

Read [architecture](docs/ARCHITECTURE.md), [contributing](CONTRIBUTING.md) and [team ownership](docs/TEAM_OWNERSHIP.md) before editing shared interfaces.

## Current scope

Includes domain models, validated receipt saving, receipt fetching, currency-separated spending totals, retailer-policy reminder creation, local SwiftData repositories, dependency injection and Swift Testing tests.

VisionKit capture, Vision OCR, Foundation Models extraction, Charts dashboard and UserNotifications scheduling are integration work assigned to feature owners. Service protocols exist; no working scanner or AI integration is claimed. Apple Intelligence must remain optional, with Vision OCR and manual review available as fallbacks.

Receipts stay in local SwiftData storage; no CloudKit sync or analytics is configured. Do not commit real receipts or personal data. Return policies describe retailer change-of-mind terms, not statutory consumer rights. Folio does not process refunds or claim retailer partnerships.

This is a tested foundation, not a completed App Store release. App icon artwork, device accessibility testing, privacy disclosures, permission copy, retention/deletion controls and full feature acceptance testing remain release work.
