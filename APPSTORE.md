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

**Review-risk flags (decide before submitting):**
- The legacy Spotlight importer (`Contents/Library/Spotlight/*.mdimporter`,
  CFPlugIn) is an uncommon payload for MAS; review may question it, and under
  MAS rules every binary must be sandboxed. If it's rejected, Plan B: strip the
  importer from the MAS build (one `rm -rf` before export — Info-panel metadata
  then only ships in the direct build) and keep full functionality in Channel 1.
- App name must render as “HelioFITS” only — no “Quick Look” in the marketing
  name (Apple trademark screening).

## Recommendation
Launch Channel 1 now (plus open-sourcing the repo when ready); start Channel 2
in parallel — its review cycle is days-to-weeks and the importer question is
answerable either way.
