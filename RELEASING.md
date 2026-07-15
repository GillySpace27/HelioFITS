# Releasing HelioFITS

Two channels, one source tree. This is the runbook as actually executed for
v1.0 (build 1), submitted 2026-07-14 — not a plan. All one-time setup
(certificates, ASC app record, agreements, app group, App IDs) is DONE; nothing
below repeats it.

**Signing model (the thing that bites):** the project signs **Automatic**
against team UB45PPC2JS — that is what the Mac App Store path needs (Xcode
generates App Store profiles at export). `ship.sh` alone requests **Developer
ID** via command-line overrides. Do not pin the project to either identity;
that's what broke the store path the first time.

## Every release, in order

1. **Clean tree.** Everything committed; tests green
   (`./preflight.sh` does 1–4 and refuses a dirty tree).
2. **Bump the build number** — ASC rejects a duplicate (version, build) pair at
   upload, i.e. *after* you've made the archive:

       xcrun agvtool next-version -all          # bumps CURRENT_PROJECT_VERSION everywhere
       # for a new marketing version too:
       xcrun agvtool new-marketing-version 1.1

3. **Run the tests** (hosted in the GUI app — quit any running HelioFITS first
   or the runner hangs, then run lsclean afterward: `xcodebuild test` registers
   a Debug copy with LaunchServices, which is the recurring thumbnail bug):

       pkill -x HelioFITS; xcodebuild test -project HelioFITS.xcodeproj \
         -scheme HelioFITS -destination 'platform=macOS,arch=arm64' \
         DEVELOPMENT_TEAM=UB45PPC2JS CODE_SIGN_IDENTITY="-" \
         CODE_SIGN_STYLE=Manual AD_HOC_CODE_SIGNING_ALLOWED=YES
       ./lsclean.sh

4. **Commit + tag**: `git tag -a v<VER>-build.<N> -m "..."` and push the tag.
   The tag marks the exact source of the shipped binaries.

### Channel A — Mac App Store

5. Xcode → **Product → Archive** (plain archive is MAS-clean: the legacy
   Spotlight importer is injected only by `embed-importer.sh`, which archiving
   never runs; Quick Actions are separate files).
6. Window → **Organizer** → select the archive → **Validate App** (free dry-run
   of the upload checks) → **Distribute App → App Store Connect → Upload**.
7. In App Store Connect: wait for the build to finish Processing (15–60 min),
   attach it to the version, then **Add for Review** → **Submit to App Review**
   (two separate buttons on two pages).
   - ASC gotchas learned on v1.0: **App Privacy** has its own *Publish* step
     (filling it in is not enough); **Pricing and Availability** is a separate
     sidebar page; attach a **demo FITS file** in App Review Information (a
     reviewer has no FITS files and cannot otherwise exercise the app); never
     click **Expire Build**.
8. Release is **manual**: after approval, the "Release this version" button in
   ASC. Check the live listing before clicking.

### Channel B — Direct notarized download

9. `./ship.sh` — archives with Developer ID, embeds the Spotlight importer,
   notarizes (waits), staples, Gatekeeper-verifies, and produces
   `build/HelioFITS-<VER>-b<N>.zip`.
10. Publish it: the script prints the exact `gh release create` command.
    The Releases page is the update channel for direct-download users (the app's
    Help → "Check for Updates…" points there); don't skip this step.

## If App Review rejects with 4.2 "minimum functionality"

Prepared response (Resolution Center) — cite only what's in the MAS binary (the
legacy Spotlight importer is NOT in the store build; don't mention it):

> HelioFITS is a purpose-built scientific utility for solar-physics FITS data,
> not a generic image viewer. Functionality in this build:
> (1) World-coordinate readout: hovering reports each pixel's helioprojective
> coordinates (Tx, Ty) and distance from disk center, via full spherical
> deprojection (TAN/ARC/SIN/CAR projections, PC/CD matrices, CROTA2), validated
> against the astropy reference implementation in the unit test suite.
> (2) Region measurement: drag-select reports mean/median/σ/sum/min/max and a
> histogram at native resolution.
> (3) Multi-extension navigation: pixel-registered blink between HDUs, running
> difference, per-folder HDU selection shared with the Quick Look extensions.
> (4) Instrument-correct rendering: 73 colormaps from the sunpy standard,
> selected automatically from FITS header metadata, including signed-field
> handling for magnetograms.
> (5) Live percentile/gamma/log stretch, solar-limb overlay, PNG export, and
> generation of Python (sunpy) code for the displayed HDU.
> These functions are used by working heliophysicists on calibrated mission
> data (SDO, SOHO, PUNCH, GOES). A demo FITS file is attached to the
> submission; sample data is freely available at https://sdo.gsfc.nasa.gov/data/.

## Standing reminders

- **EU trader status** (ASC → Business → Trader Status) must be declared before
  the EU storefront will carry the app. Not per-release, but blocks EU users
  (ESA/MPS/ROB — a big slice of the audience) until done.
- The app is **arm64-only** (vendored libcfitsio.a). Intel support is
  [#1](https://github.com/GillySpace27/HelioFITS/issues/1).
- ASC listing text lives in `STORE.md`; screenshots regenerate via
  `make-screenshots.sh` (App Store sizes only accept 1280×800 / 1440×900 /
  2560×1600 / 2880×1800).
- `qlmanage -t` hangs on all FITS — tooling artifact, not a bug. Verify
  thumbnails with Finder.
