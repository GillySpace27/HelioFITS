# Releasing HelioFITS

Two channels, one source tree. This is the runbook as actually executed. For the
live state of a release (tagged, uploaded, in review, live), run
`python3 .claude/skills/ship-heliofits/scripts/release_status.py <VER> <BUILD>`
rather than trusting a version named in this file; it checks git, `gh` and the
App Store Connect API, and says UNCHECKED when it cannot verify. History: v1.0
(build 1) submitted 2026-07-14; v1.2 (build 6) went live on the Mac App Store
2026-07-28. All one-time setup (certificates, ASC app record, agreements, app
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

**Release gates (SU-3):** `preflight.sh` and `ship.sh` run `./release-gates.sh`,
which refuses an unpushed HEAD, a HEAD that is not an ancestor of `origin/main`,
disagreeing versions, a U+2014 in `CHANGELOG.md`, or a Friday from 12:00 local.
Each refusal names its override (`ALLOW_FRIDAY=yes-gilly` and so on); set one
only on Gilly's yes for that release. Rolling back: "Rolling back" below, and
`python3 ~/.claude/skills/runbook-drift/scripts/rollback_plan.py heliofits`
prints the commands without running them (that script is SU-3 Task 9, on
Gilly's machine, not in this repository).

## Every release, in order

0. **Did you touch `fitsshim.c`? Rebuild the library.** `fitsshim.c` is in NO
   Xcode target. It is baked into the vendored `libcfitsio.a` inside
   `HelioFITSCore/CFITSIO.xcframework` (the HelioFITSCore package links it) by
   `HelioFITSExtension/cfitsio/build-universal.sh`, so editing the `.c` and
   rebuilding the app changes **nothing**:

       ./HelioFITSExtension/cfitsio/build-universal.sh
       lipo -archs HelioFITSCore/CFITSIO.xcframework/macos-arm64_x86_64/libcfitsio.a   # expect: x86_64 arm64

   This is not hypothetical. `FILTER`/`FILTNAM1`/`CONTENT` were added to the
   source on 2026‑08‑20 against a library last built 2026‑07‑15, so the whole
   Proba‑3/ASPIICS colormap branch shipped in **1.3.0 unable to fire**, while
   its unit tests passed the entire time. `HeaderKeyContractTests` now reads the
   BUILT library rather than the source, so `xcodebuild test` fails loudly with
   the remedy in the message — but only if you actually run the suite.

1. **Clean tree.** Everything committed; tests green
   (`./preflight.sh` checks the tree, runs the tests and lsclean; it does not
   bump, commit or tag).
2. **Bump the version and build number** with one command. Both live once, in
   `Config/Version.xcconfig`, which every mac target inherits (the iOS project
   keeps its own pair until Gilly decides). ASC rejects a duplicate (version,
   build) pair at upload, after the archive is made, so the script refuses a
   build number that is not above the newest `v*-build.N` tag:

       scripts/bump-version.sh 1.4.1 11
       # prints "ok   <target> <config>: 1.4.1 11" for the five mac targets in
       # Debug and Release. Exit 3 means a target-level setting in
       # project.pbxproj overrides the xcconfig: remove it there, then rerun.

   `agvtool` is not used (its `-all` flag errors on this project), and nothing
   edits version numbers in `project.pbxproj` any more: `scripts/check.sh`
   fails if one appears there.

3. **Run the tests.** First the core package, headless, in seconds (no app
   launch, nothing registered with LaunchServices):

       swift test --package-path HelioFITSCore

   Then the rest (hosted in the GUI app - quit any running HelioFITS first
   or the runner hangs, and do NOT `pkill HelioFITS` while a run is in flight:
   the test host IS the app, so killing it fails the run with "crashed with
   signal term before establishing connection", which looks like a real failure
   and is not. Run lsclean afterward: `xcodebuild test` registers a Debug copy
   with LaunchServices, which is the recurring thumbnail bug):

       pkill -x HelioFITS; xcodebuild test -project HelioFITS.xcodeproj \
         -scheme HelioFITS -destination 'platform=macOS,arch=arm64' \
         DEVELOPMENT_TEAM=UB45PPC2JS CODE_SIGN_IDENTITY="-" \
         CODE_SIGN_STYLE=Manual AD_HOC_CODE_SIGNING_ALLOWED=YES
       ./lsclean.sh

   If `libcfitsio.a` changed, run the suite on **both** arches — the Intel
   slice is built separately and is otherwise never exercised on this Mac:

       xcodebuild test ... -destination 'platform=macOS,arch=x86_64'   # Rosetta

4. **Update `CHANGELOG.md`.** Keep a Changelog format, newest section first,
   grouped Added / Changed / Fixed by what a user would notice rather than by
   commit. Link the issues. The GitHub release notes are drawn from this, so
   write it once here rather than twice.

   **Two tiers, not one.** The changelog entry is the long form: it explains
   *why* a bug mattered and what was actually wrong, because a GitHub reader
   is often the person who reported it and wants the mechanism, not just the
   symptom. The App Store **What's New** box is a separate, short pass:
   one line per fix, no root cause, no issue links — a store visitor wants
   "is my bug fixed," not why. Write the changelog entry first, then compress
   each Fixed bullet to a single headline sentence for What's New. Do not
   paste the changelog into the store box or vice versa.
5. **Commit + tag**: `git tag -a v<VER>-build.<N> -m "..."` and push the tag.
   The tag marks the exact source of the shipped binaries.

### Channel A — Mac App Store (default)

6. Xcode → **Product → Archive** (plain archive is MAS-clean: the legacy
   Spotlight importer is injected only by `embed-importer.sh`, which archiving
   never runs; Quick Actions are separate files).
7. Window → **Organizer** → select the archive → **Validate App** (free dry-run
   of the upload checks) → **Distribute App → App Store Connect → Upload**.
8. In App Store Connect: wait for the build to finish Processing (15–60 min),
   then click **+** beside "macOS App" to create the new version record, attach
   the build, write **What's New in This Version**, then **Add for Review** →
   **Submit to App Review** (two separate buttons on two pages).
   - ASC gotchas learned on v1.0: **App Privacy** has its own *Publish* step
     (filling it in is not enough); **Pricing and Availability** is a separate
     sidebar page; attach a **demo FITS file** in App Review Information (a
     reviewer has no FITS files and cannot otherwise exercise the app); never
     click **Expire Build**.
9. Release is **manual**: after approval, the "Release this version" button in
   ASC. Check the live listing before clicking.

### Channel B — Direct notarized download (fallback)

10. `./ship.sh` — archives with Developer ID, embeds the Spotlight importer,
   notarizes (waits), staples, Gatekeeper-verifies, and produces
   `build/HelioFITS-<VER>-b<N>.zip`.
11. Publish it: the script prints the exact `gh release create` command.

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

## Rolling back

The App Store cannot re-serve an old binary, so rolling back means shipping the
last good source again as a new build. Nothing is deleted on the way: no tag,
no release, no GitHub zip, no App Store version.

1. **Pause a phased release** if one is running (App Store Connect, on the
   version's page). Outward: only with Gilly's yes for this release.
2. **Prepare the rebuild:** `scripts/rollback.sh <good-tag>`, for example
   `scripts/rollback.sh v1.4.0-build.10`. It adds a worktree at
   `.claude/worktrees/rollback-<good-tag>` (git-ignored), prints the next free
   build number, a suggested marketing version one patch above the newest tag
   (the store expects a version above the last approved one; confirm on the
   first real rollback), and the bump and release commands. It pushes,
   uploads, tags and submits nothing.
3. **Ship it like any release** from the worktree: "Every release, in order"
   steps 2 to 5 (the CHANGELOG entry names the tag it restores), then
   Channel A. Upload, submit and release stay gated on Gilly, one yes per
   action.
4. **Expedited review** only for a critical regression; it loses its power if
   overused (see "How much review to expect").
5. **Direct channel:** the previous zip stays on its GitHub release, which is
   never deleted. Point people at the `/releases` index, never
   `/releases/latest`.
6. Leave the worktree in place afterwards; `git worktree list` shows it.

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
  `libcfitsio.a` (in `HelioFITSCore/CFITSIO.xcframework`) is a fat lib — regenerate it with
  `HelioFITSExtension/cfitsio/build-universal.sh` if CFITSIO is ever updated.
  Verify with `lipo -archs`.
- ASC listing text lives in `STORE.md`; screenshots regenerate via
  `make-screenshots.sh` (App Store sizes only accept 1280×800 / 1440×900 /
  2560×1600 / 2880×1800). It captures a live window *or* composites an image you
  already have (`--compose`), and puts a **caption** on each — a bare window
  screenshot sells nothing. The set that shipped with 1.2:

      # start a new version folder: shots land in screenshots/<VER>/, kept per version and never wiped; to redo a set, VER=<VER>-retake
      CAPTIONS="Finder learns to read solar FITS files" ./make-screenshots.sh   # app window, "How it works" expanded
      CAPTIONS="Image, full header, and a ready-to-run sunpy snippet" ./make-screenshots.sh sun.fits
      ./make-screenshots.sh --compose docs/before-after.png       "From grey icons to the Sun"
      ./make-screenshots.sh --compose docs/colormaps.png          "Your data folder, in the right instrument colors"
      ./make-screenshots.sh --compose docs/spotlight-metadata.png "Telescope, instrument, wavelength — searchable"

  For the onboarding shot, expand the "How it works" disclosure first — it
  collapses after first run, and collapsed it hides the whole capability list:
  `defaults write "$HOME/Library/Group Containers/UB45PPC2JS.com.gillyspace27.fits/Library/Preferences/UB45PPC2JS.com.gillyspace27.fits" howItWorks -bool true`
- **Re-shoot screenshots whenever the UI changes** — the v1.0 set showed the
  pre-redesign window and had to be replaced wholesale before 1.2 went out.
- **Reinstalling a locally re-signed build churns TCC**: the code signature
  changes, so macOS re-prompts for file access every time. Notarization
  (Gatekeeper) and the file-access prompt (TCC) are unrelated systems. Install
  the *notarized* build if you want the grant to stick.
- Quick Look caches aggressively: `qlmanage -r && qlmanage -r cache` is often
  not enough for a stale **Get Info** preview — `killall Finder` busts it. The
  installed bundle's appex is what runs, not your Xcode build.
- `qlmanage -t` hangs on all FITS — tooling artifact, not a bug. Verify
  thumbnails with Finder.

## Family release feed

After App Store Connect reports `READY_FOR_SALE` for the release (never before), record it:

    SITE=~/vscode/Website python3 .claude/skills/ship-heliofits/scripts/release_status.py <version> <build> --record

It appends one record to `heliosoftware/feed/heliofits.json` in the Website checkout (channel `mac-app-store`,
no assets, the changelog's intro paragraph as the notes) and regenerates `feed.xml` and the What's new page.
It prints `record: skipped, App Store state is ...` while the release is not live, and writes nothing then.
The date is the day the record is written (UTC). Committing and pushing the Website is a separate yes from Gilly.
