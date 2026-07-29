# Releasing HelioFITS

Two channels, one source tree. This is the runbook as actually executed —
v1.0 (build 1) submitted 2026‑07‑14, **v1.2 (build 6) live on the Mac App Store
2026‑07‑28**. All one‑time setup (certificates, ASC app record, agreements, app
group, App IDs) is DONE; nothing below repeats it.

- **App Store listing:** <https://apps.apple.com/app/id6790952544> (Apple ID `6790952544`)
- **Shareable link:** <https://gilly.space/heliofits> → landing page whose CTA is the store
- **The App Store is the one official channel.** Channel B below is a fallback,
  not a per‑release obligation — see "Which channels to cut".

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
       xcrun agvtool new-marketing-version 1.3

   (Both fields live in `project.pbxproj`, repeated across all 10 targets —
   `agvtool` keeps them in sync; hand-editing one target desynchronises the
   extensions from the app and the upload fails.)

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

### Channel A — Mac App Store (default)

5. Xcode → **Product → Archive** (plain archive is MAS-clean: the legacy
   Spotlight importer is injected only by `embed-importer.sh`, which archiving
   never runs; Quick Actions are separate files).
6. Window → **Organizer** → select the archive → **Validate App** (free dry-run
   of the upload checks) → **Distribute App → App Store Connect → Upload**.
7. In App Store Connect: wait for the build to finish Processing (15–60 min),
   then click **+** beside "macOS App" to create the new version record, attach
   the build, write **What's New in This Version**, then **Add for Review** →
   **Submit to App Review** (two separate buttons on two pages).
   - ASC gotchas learned on v1.0: **App Privacy** has its own *Publish* step
     (filling it in is not enough); **Pricing and Availability** is a separate
     sidebar page; attach a **demo FITS file** in App Review Information (a
     reviewer has no FITS files and cannot otherwise exercise the app); never
     click **Expire Build**.
8. Release is **manual**: after approval, the "Release this version" button in
   ASC. Check the live listing before clicking.

### Channel B — Direct notarized download (fallback)

9. `./ship.sh` — archives with Developer ID, embeds the Spotlight importer,
   notarizes (waits), staples, Gatekeeper-verifies, and produces
   `build/HelioFITS-<VER>-b<N>.zip`.
10. Publish it: the script prints the exact `gh release create` command.

## How much review to expect

**Every binary update goes through review.** But the first submission is the
expensive one:

| | Observed |
|---|---|
| First submission | v1.0 sat **Waiting for Review a full week** before anyone looked |
| Metadata-only resubmit | Rejected 07‑27 → fixed → **approved next day** |
| Routine updates | Usually **< 24 h**, often hours |

**Editable with no review at all:** the **promotional text** (170 chars) —
changes go live immediately. Everything else (binary, description, screenshots,
subtitle, keywords) rides along with a new version submission.

Also available: **phased release** (7‑day gradual rollout to existing users) and
**expedited review** (critical fixes only — it loses its power if overused).

## Which channels to cut

Default to **App Store only**. Run `ship.sh` when there's a reason:

- someone on a managed/institutional Mac that blocks the App Store needs it
- you want an archival artifact tied to a paper or a talk
- you need to hand a colleague a build without waiting on review

If you cut both for one release, keep the version **and** build numbers
identical across channels so a bug report identifies the binary unambiguously.

## Rejections seen so far

**5.2.5 Legal — Intellectual Property (v1.2 build 6, 2026‑07‑27).** The subtitle
read *"Solar FITS previews in Finder"*. Apple does not allow its trademarks
(Finder, Quick Look, Spotlight, Mac …) in the **app name or subtitle** — that is
branding real estate. Referential use in the **description body** ("teaches
Finder to read…") was *not* flagged and is normal practice. Fix was metadata
only: new subtitle, resubmit, same build, no re-upload, no rename, bundle ID
untouched. See `STORE.md`.

**If App Review rejects with 4.2 "minimum functionality"** — prepared response
(Resolution Center), citing only what's in the MAS binary (the legacy Spotlight
importer is NOT in the store build; don't mention it):

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

- **EU trader status** — declared **non-trader** 2026‑07‑15. Done; not
  per-release, but it blocks the EU storefront (ESA/MPS/ROB — a big slice of the
  audience) until it is.
- The app is **universal** (arm64 + x86_64) as of v1.1.1 build 3. The vendored
  `libcfitsio.a` is a fat lib — regenerate it with
  `HelioFITSExtension/cfitsio/build-universal.sh` if CFITSIO is ever updated.
  Verify with `lipo -archs`.
- ASC listing text lives in `STORE.md`; screenshots regenerate via
  `make-screenshots.sh` (App Store sizes only accept 1280×800 / 1440×900 /
  2560×1600 / 2880×1800). **Re-shoot screenshots whenever the UI changes** —
  the v1.0 set showed the pre-redesign window and had to be replaced.
- **Reinstalling a locally re-signed build churns TCC**: the code signature
  changes, so macOS re-prompts for file access every time. Notarization
  (Gatekeeper) and the file-access prompt (TCC) are unrelated systems. Install
  the *notarized* build if you want the grant to stick.
- Quick Look caches aggressively: `qlmanage -r && qlmanage -r cache` is often
  not enough for a stale **Get Info** preview — `killall Finder` busts it. The
  installed bundle's appex is what runs, not your Xcode build.
- `qlmanage -t` hangs on all FITS — tooling artifact, not a bug. Verify
  thumbnails with Finder.
