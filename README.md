# Folio: Receipts, Reimagined

**Scan once. Know what you bought, what you spent, and when you can still return it.**

Folio is a privacy-first iOS receipt and purchase manager. It reads paper receipts with on-device OCR and Apple Intelligence, turns them into searchable purchase records, and reminds you before a return or warranty window closes. Everything runs on the iPhone: no accounts, no servers and no analytics.

Built for **40005 Advanced iOS Applications** (Assessment 4 Capstone) at the University of Technology Sydney.

---

## Features

| Area | What it does |
| --- | --- |
| **Scan** | Capture multi-page receipts with the VisionKit document camera |
| **Import** | Pick receipt photos with the system photo picker (no library permission needed) |
| **Share Extension** | Send a receipt image to Folio from Photos, Mail or Files via *Add to Folio* |
| **On-device extraction** | Apple Vision OCR reads the text and Apple Foundation Models proposes products, prices and totals |
| **Verifiable AI** | Every extracted product is checked against the OCR line it came from, printed totals are copied rather than calculated, and quality warnings flag anything suspect |
| **Review and edit** | Check each product and total beside the original scan and OCR text, and correct anything before saving |
| **Manual entry** | Full manual fallback when OCR fails or Apple Intelligence is unavailable |
| **Library** | Search and filter saved receipts by retailer, item, date and profile |
| **Return and warranty reminders** | Retailer-policy based deadlines scheduled as local notifications |
| **Spending insights** | Swift Charts dashboard with period and category breakdowns, plus Personal and Business profiles |
| **AI assistant** | On-device chat that searches your purchases and coaches you on saving goals |
| **Accessibility** | Light and Dark Mode, Dynamic Type and VoiceOver labels |

## Privacy

Receipts never leave the device.

- Scanning, OCR, extraction and the assistant all run on-device.
- Data is stored locally with SwiftData. No CloudKit sync, analytics, advertising or tracking SDKs.
- Draft receipts are excluded from device backups and use iOS file protection.
- The only outside connection is a link that opens a retailer's official policy page in the browser.
- App Privacy answer: **Data Not Collected**.

Please do not commit real receipts or personal data to this repository.

## Tech stack

| Layer | Frameworks and tools |
| --- | --- |
| UI | SwiftUI, Swift Charts |
| Capture | VisionKit (`VNDocumentCameraViewController`), PhotosUI (`PhotosPicker`) |
| Text recognition | Vision |
| AI | Foundation Models (Apple Intelligence), on-device |
| Persistence | SwiftData |
| Notifications | UserNotifications |
| System integration | Share Extension, App Group shared container |
| Testing | Swift Testing |
| Language and tools | Swift 6, Xcode, Git |

There are no third-party Swift packages.

## Architecture

Folio uses **MVVM + Use Cases + Repository**:

```
SwiftUI Views
     |
ViewModels (@Observable, @MainActor)
     |
Use Cases (validation, business rules, domain errors)
     |
Repository protocols (ReceiptRepository, ReminderRepository, ...)
     |
SwiftData / Vision / Foundation Models / UserNotifications
```

- Views never call storage or frameworks directly.
- Use cases contain no UI or database code, so they are tested with mock repositories.
- Dependencies are wired through `DependencyContainer`.

### Receipt flow

```
Scan / Import photo / Share Extension
        -> JPEG pages
        -> ReceiptScannerViewModel.process
           (Vision OCR -> Foundation Models -> evidence verifier -> quality audit)
        -> Review and edit (draft autosaved locally)
        -> Save sheet (duplicate check -> repository -> reminders)
        -> Saved (draft cleared)
```

See [architecture](docs/ARCHITECTURE.md) for details.

## Getting started

**Requirements**

- Xcode 26.2 or later with the matching iOS SDK
- An iPhone or simulator running iOS 26.2 or later
- Apple Intelligence enabled for AI extraction and the assistant (optional; manual entry and OCR recovery work without it)

**Run**

```sh
git clone https://github.com/Divy3122/Folio-iOS.git
cd Folio-iOS
git switch develop
open Folio/Folio.xcodeproj
```

Select the **Folio** scheme and a simulator or device. Running on a physical device or using the Share Extension requires your own signing team and a matching App Group (see below).

**Build and test from the command line**

```sh
xcodebuild -project Folio/Folio.xcodeproj -scheme Folio -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Folio/Folio.xcodeproj -scheme Folio -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FolioTests CODE_SIGNING_ALLOWED=NO test
```

Sources live in `Folio/Folio/`. The project uses filesystem-synchronized folders, so do not add duplicate explicit Compile Sources entries.

### Share Extension setup

1. Enable the **App Groups** capability on both the **Folio** and **FolioShare** targets.
2. Use the same group ID on both (for example `group.uts.edu.Folio`) and set it as `appGroupID` in `SharedReceiptInbox.swift`.
3. Run the **Folio** scheme first, then the **FolioShare** scheme and choose Photos as the host app.

## Permissions

| Permission | Used for | If denied |
| --- | --- | --- |
| Camera (`NSCameraUsageDescription`) | Scanning receipts | Photo import and manual entry still work |
| Notifications (runtime prompt) | Return and warranty reminders | Receipt and reminder are still saved, with a warning |

Photo import uses the system picker and needs no photo library permission.

## Testing

Unit tests use Swift Testing with mock repositories and a captured real-receipt OCR fixture to cover:

- Use cases and validation rules (save, duplicate detection, reminder status)
- Receipt extraction and evidence verification
- Repository error mapping
- Regression tests for OCR to review

## Team

| Member | Role | GitHub |
| --- | --- | --- |
| Divy Patel | Receipt scanner, OCR and Apple Intelligence extraction; slide design | [@Divy3122](https://github.com/Divy3122) |
| Ziyan Nadeem | Database, receipt options and library, AI assistant | [@zoinks-05](https://github.com/zoinks-05) |
| Aaditya Thande | Spending dashboard and profiles | [@athande23](https://github.com/athande23) |
| Brandon Hua | Return reminders and notifications | [@BrandonH-12](https://github.com/BrandonH-12) |
| Thailong Chrin | Architecture, navigation and integration | [@zhaolong093](https://github.com/zhaolong093) |

See [team ownership](docs/TEAM_OWNERSHIP.md) and [contributing](CONTRIBUTING.md) before editing shared interfaces.

## Git workflow

- Branches: `main` (stable), `develop` (integration), and one `feature/*` branch per feature.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `refactor:`, `test:`, `docs:`.
- Every change is reviewed through a pull request and must build and pass tests before merging into `develop`.

## Roadmap

- **Brand Policy Database:** return and warranty policies for major retailers, with a source and last-verified date
- **Automated Claim Generator:** package a receipt, dates and policy into a ready-to-send PDF
- **Product Recall Check:** match saved items against public recall notices

Receipts stay on the device; only public policy and recall information would come in.

## Disclaimers

- Return policies describe retailer change-of-mind terms, not statutory consumer rights.
- Folio does not process refunds or claim any retailer partnerships.
- AI extraction can be wrong. Always check products and totals against the original receipt before saving.
- Folio is a university project and is not affiliated with Apple or any retailer.

## AI tool usage

AI coding assistants were used as engineering aids. The team remains fully accountable for the correctness, architecture and security of all submitted code. See the Required Document, Section 5, for the declaration.

## Licence and acknowledgements

Created for UTS coursework.

Built with Apple's SwiftUI, SwiftData, VisionKit, Vision, Foundation Models, Swift Charts and UserNotifications frameworks.
