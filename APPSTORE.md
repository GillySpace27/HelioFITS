# HelioFITS — release runbook

Two channels. Direct (Developer ID) is ready today; Mac App Store needs three
one-time steps only you can do (Apple-account actions I can't perform for you).

## Channel 1 — Direct notarized download (READY)

    ./ship.sh          # archive → notarize → staple → verify → HelioFITS.zip

One-time first: the keychain profile was renamed with the app —

    xcrun notarytool store-credentials HelioFITS-notary \
      --apple-id <your-apple-id> --team-id UB45PPC2JS \
      --password <app-specific password from account.apple.com>

Distribute `build/HelioFITS.zip` (GitHub release / website). Gatekeeper-clean on
any Apple-silicon Mac (app is arm64-only; vendored libcfitsio.a has no x86_64).

## Channel 2 — Mac App Store

**Your three one-time steps:**
1. **Apple Distribution certificate** — Xcode → Settings → Accounts →
   Manage Certificates → “+” → Apple Distribution. (You currently have only
   Developer ID Application + Apple Development; MAS uploads need this.)
2. **App Store Connect record** — appstoreconnect.apple.com → My Apps → “+” →
   New App: platform macOS, name **HelioFITS** (verified available 2026-07-12),
   bundle ID `com.gillyspace27.HelioFITS` (register it at
   developer.apple.com/account/resources/identifiers first, with the
   App Groups capability), SKU e.g. `heliofits-1`.
3. **Agreements/Tax/Banking** — accept the Paid/Free Apps agreement in ASC
   (needed even for a free app).

**Then the mechanical part (I can prep/verify any of it):**
4. Archive in Xcode (Product → Archive) → Organizer → Distribute App →
   App Store Connect → Upload (Xcode manages the MAS signing + provisioning;
   the team-prefixed app group `UB45PPC2JS.com.gillyspace27.fits` is valid for
   MAS without extra approval).
5. In ASC: screenshots (1280×800 or 2560×1600 — use gallery view full of
   AIA/HMI/LASCO color thumbnails + the blink preview), description from
   STORE.md, category **Developer Tools** or **Utilities**, privacy label
   “Data Not Collected”, price Free.
6. Submit for review.

**Payload questions — SETTLED by the pre-submission review (2026-07-14):**
- The legacy Spotlight importer is **not in the Xcode project** — it's injected
  only by `embed-importer.sh` (run from `ship.sh`) *after* archiving. So a plain
  **Product → Archive already produces an importer-free, MAS-clean bundle.**
  Do NOT run `ship.sh`/`embed-importer.sh` for the MAS build; there is nothing
  to `rm`. The Info-panel metadata stays a Channel-1 perk.
- The Automator Quick Actions (`QuickAction/*.workflow`) are standalone shell
  scripts installed to `~/Library/Services`; they are not referenced by the app
  and a sandboxed MAS app can't install them anyway. Ship them via Channel 1 or
  a separate download. Nothing to do for MAS.
- App name must render as “HelioFITS” only — no “Quick Look” in the marketing
  name (Apple trademark screening).

**Verified ready (review + tests, 2026-07-14):**
- App icon populated (Assets.car has all 10 mac sizes + 1024 — was empty; would
  have failed ITMS-90236).
- Helioprojective coordinates correct for wide-field data (PUNCH), pinned to
  astropy by `HelioFITSTests/WCSTests.swift`.
- Malformed-FITS crash and HDU-switch race fixed (`HeaderViewer.swift`), fuzzed
  by `HelioFITSTests/FITSHeaderTests.swift`. `xcodebuild test` = 13 passing
  (quit any running HelioFITS first — the unit tests are hosted in the app, and
  a stale instance hangs the test runner).

## Recommendation
Launch Channel 1 now (plus open-sourcing the repo when ready); start Channel 2
in parallel — its review cycle is days-to-weeks and the importer question is
answerable either way.
