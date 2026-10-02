# HelioFITS: notes for agents

<!-- heliosoftware-preamble: SU-6 inserts the v1 block here -->

HelioFITS teaches Finder and Quick Look to read solar FITS files: a Quick Look preview
extension, a thumbnail extension and a viewer app, with an iPhone and iPad port in
`HelioFITS-iOS/`. Shared, AppKit-free code is the Swift package `HelioFITSCore/`.
The owner is Gilly; call him Gilly.

## Build and test

- Start from `origin/main`, never the local `main` of Gilly's checkout (stale since
  2026-08-23). One branch per change: `git fetch origin && git switch -c <branch> origin/main`.
- Fast static checks, read-only, no build: `bash scripts/check.sh` (exit 0 when all pass;
  `CHECK_BASE` defaults to `origin/main`).
- App build (README "Building from source"):
  `xcodebuild -project HelioFITS.xcodeproj -scheme HelioFITS -configuration Release -destination 'platform=macOS,arch=arm64' build`.
  Always pass `-project`: the iOS project also has a scheme named HelioFITS.
- Core tests, headless (no app launch, nothing registered with LaunchServices):
  `swift test --package-path HelioFITSCore`. Tests of `HelioFITSCore` code go in
  `HelioFITSCore/Tests/HelioFITSCoreTests/` and find repository files through `RepoPaths`;
  `HelioFITSTests/` keeps only tests that need the app module.
- Callbacks: a new `var on<Name>` on `FITSImageCanvas` or `CanvasScrollView` is assigned in
  every host, or gets an entry with a reason in `CallbackSubscriberTests.allowlist`.
- Hosted tests (RELEASING.md step 3), then the LaunchServices clean:
  `pkill -x HelioFITS; xcodebuild test -project HelioFITS.xcodeproj -scheme HelioFITS -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=UB45PPC2JS CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual AD_HOC_CODE_SIGNING_ALLOWED=YES`
  then `./lsclean.sh`. When `libcfitsio.a` changed, also run with
  `-destination 'platform=macOS,arch=x86_64'` (Rosetta).
- iOS (not built by CI yet):
  `xcodebuild -project HelioFITS-iOS/HelioFITS-iOS.xcodeproj -scheme HelioFITS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- After any edit to `HelioFITSExtension/cfitsio/fitsshim.c` or `fitsshim.h`, run
  `./HelioFITSExtension/cfitsio/build-universal.sh`, then
  `lipo -archs HelioFITSCore/CFITSIO.xcframework/macos-arm64_x86_64/libcfitsio.a`
  (expect `x86_64 arm64`). The shim is in no Xcode target: without the rebuild the
  edit does nothing while tests still pass (shipped dead in 1.3.0; RELEASING.md step 0).

## Must-nots

- Delete nothing. No `rm` of a tracked file, no `git rm`, no force-push, no history
  rewrite, no deleting a branch, tag or GitHub release (testers' links and managed Macs
  depend on the releases). Retire code by moving it under `attic/` with a line in
  `attic/README.md`; retire a branch with an annotated tag `archive/<branch>` and leave it.
- Never `pkill -x HelioFITS` while a test run is in flight: the test host is the app, and
  the run fails with "crashed with signal term" (RELEASING.md step 3).
- Never launch a test or Debug build to look at it, never `open heliofits://choose?...`, and
  never trigger a dialog whose default button writes the shared app-group settings
  (`UB45PPC2JS.com.gillyspace27.fits`): a Debug build once opened Gilly's real files and a
  test wrote a real folder rule (SKILL.md incident 2026-09-24). Run `./lsclean.sh` after
  anything that builds or launches the app.
- A Mac App Store archive must not contain `Contents/Library/Spotlight` (the legacy
  importer); only `ship.sh` embeds it (RELEASING.md step 6; SKILL.md step 9).
- No network entitlement in any target (README "Privacy").
- Do not pin the Xcode project to one signing identity: it signs Automatic for the store and
  `ship.sh` overrides to Developer ID (RELEASING.md "Signing model").
- Never touch the worktree `.claude/worktrees/increase-max-layers-limit-569ab2`: it hosts
  another session's branch (`claude/ios-memory`). No rename, prune or checkout there.
- `ship.sh` (`rm -rf build`) and `lsclean.sh` (removes `build/HelioFITS.xcarchive`) delete
  build output by design; copy what you need out of `build/` first.
- `./preflight.sh` checks the tree, runs the hosted tests (it runs `pkill -x HelioFITS` first,
  so never while another test run is in flight) and `./lsclean.sh`; it bumps, commits and
  tags nothing.
- Hand out `https://github.com/GillySpace27/HelioFITS/releases`, never `/releases/latest`.
- Data contracts, append-only: bundle id `com.gillyspace27.HelioFITS`, the app group above,
  defaults keys `dirHDU` and `defaultHDU`, tags `v<VER>-build.<N>`, release zip names.

## Human gates

Each needs Gilly's explicit yes in the current conversation, for that one action; a yes for
one build does not cover the next (SKILL.md "What it cannot finish without Gilly in the loop"):

- Add for Review, Submit to App Review, Release This Version (RELEASING.md steps 8 and 9).
- Any `git push` (branches or tags), merging a pull request, `gh release create`, an App
  Store Connect upload, or any ASC API call that changes state (GET calls are free).
- Cutting the direct-download zip with `./ship.sh`: only when there is a reason
  (RELEASING.md "Which channels to cut").
- Moving anything in the parent folder `/Users/gilly/vscode/HelioFITS/` (plan in
  `ATTIC-PLAN.txt` there).

## In flight

Update this list when a branch merges or parks.

- PR #35 claude/ios-memory (8a26d00): open, waiting on Gilly's merge-or-park decision. It adds `fitsshim_read_image_max`, rebuilds `HelioFITSCore/CFITSIO.xcframework` and adds `lowMemory:` to `FITSRenderer.render`; do not start work on the shim, the xcframework or `FITSRenderer.render` until it settles.
- PR #34 claude/rhef-ties: merged as 2c12f45 on 2026-09-29.

## Release

- `RELEASING.md` is authoritative; `.claude/skills/ship-heliofits/SKILL.md` is the agent
  runbook, and RELEASING.md wins where they disagree.
- Live state: `python3 .claude/skills/ship-heliofits/scripts/release_status.py <VER> <BUILD>`
  checks git, `gh` and the App Store Connect API and says UNCHECKED when it cannot verify.
  Never quote a version from a doc as live.
- The Mac App Store is the one official channel; the notarized GitHub zip is a fallback.
- The mac version lives once, in `Config/Version.xcconfig`; change it only with
  `scripts/bump-version.sh <VER> <BUILD>` (refuses a build not above the newest
  `v*-build.N` tag; exit 3 if a target resolves other values). The iOS project keeps its
  own pair, 6 times each, until Gilly decides. `scripts/check.sh` fails on a version line
  in the mac `project.pbxproj` and on a newest tag that is off the branch or ahead of the
  xcconfig.
- The incident log at the end of SKILL.md is append-only ("Append, never delete").

## Style

- No em dashes (U+2014) in anything you add: code, comments, UI strings, docs, commit
  messages. `scripts/check.sh` checks added lines; existing ones stay unless a task says so.
- Swift: 4-space indent, 120-column soft limit (`.swift-format`, `.editorconfig`). Format
  only files your change already touches. Never reformat the vendored CFITSIO in
  `HelioFITSExtension/cfitsio/` or `HelioFITSCore/CFITSIO.xcframework/`;
  `HelioFITSCore/Sources/HelioFITSCore/FITSColormaps.swift` is generated (no hand edits).
- Commit messages `<type>: <what>`; write UNCHECKED when a step could not be verified.
- Standard library first; no speculative abstractions.
- Scientific claims (WCS, instruments, RHEF) need a source. RHEF output is visualization,
  not a calibrated radiance. Do not claim ASPIICS colours are correct until Nawin verifies.
