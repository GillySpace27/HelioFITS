---
name: ship-heliofits
description: Full HelioFITS release pipeline — version bump, conditional libcfitsio.a rebuild, tests on both arches, changelog (two-tier), tag, ship.sh (Developer ID + notarize + GitHub release), and the Mac App Store archive + upload. Use whenever Gilly says "ship a patch/release", "cut a new version", "publish vX.Y.Z", "ship this as build N", or asks to deploy/release HelioFITS. Do NOT use for a single code fix with no release attached, or for other repos.
---

# ship-heliofits

Runs the HelioFITS release pipeline end to end, up to the point that requires
a logged-in web UI. The authoritative runbook is
[RELEASING.md](../../../RELEASING.md) at the repo root — read it if anything
here seems to disagree with it; RELEASING.md wins.

## What this skill can finish unattended

Everything through "build N is uploaded and Processing in App Store Connect."
No password, credential, or GUI click is required for any of it.

## What it cannot finish without Gilly in the loop

Creating the version record, attaching the build, writing What's New, and
confirming screenshots are automatable once an App Store Connect API key
exists (see [references/asc-api.md](references/asc-api.md) if that file is
present; if not, no key has been set up yet and this whole tier is
unavailable — hand off to the manual App Store Connect flow instead).

**Hard gate, independent of what's automated: never call Add for Review,
Submit to Review, or Release This Version without asking Gilly in chat first
and getting an explicit yes, every single time.** This is not a one-time
grant — a "yes" for build N does not cover build N+1. These are the actions
that make a release visible to the public or to Apple's review queue, and
per the standing safety rules for this project they require confirmation
per action, not standing authorization. Preparing everything up to that
point (version record, build, metadata, screenshots) does NOT require
per-step confirmation — only the final publish/submit action does. State
plainly what is about to happen ("this will submit build 8 of 1.3.1 for App
Review") rather than a vague "should I continue?".

If no API key is configured, all of this stays manual: hand off after
upload and say plainly that the release is not live until Gilly creates the
version record and clicks through Submit to Review himself.

## App Store Connect API key: scope and terms

A key is configured (as of 2026-08-22): Key ID `4QPRA2KW39`, Issuer ID
`7b467b82-5579-417f-aa7e-b7d16f47f8d9`, role App Manager, `.p8` at
`~/.claude/secrets/appstoreconnect/AuthKey_4QPRA2KW39.p8` (mode 600, outside
any git-tracked tree). `scripts/asc_api.py` in this skill signs the ES256 JWT
and calls the API — `python3 scripts/asc_api.py GET /v1/apps/6790952544/builds`
etc. GET calls are safe to run freely; anything that mutates ASC state goes
through the confirmation gate below regardless of which script does the
mutating. Verified 2026-08-22: `GET /v1/apps` and `GET .../builds` both work
and correctly resolve to HelioFITS (app id `6790952544`).

If it was issued, it's under Apple's "internal development, testing, and
reporting" terms for a single team. Keep usage inside that scope, always:

- The key and any JWT derived from it go to Apple's App Store Connect API
  endpoints ONLY. Never log it, never include it in a commit, never send it
  or its contents to any other service.
- It is for HelioFITS, under Gilly's own account. Don't reuse it for another
  app or another person's project, and don't treat it as something that can
  be shared outside Gilly's team.
- This does not relax the confirmation gate above. A working API key makes
  more of the pipeline automatable; it does not make Submit to Review or
  Release This Version automatic.

## Steps

1. **Did `fitsshim.c` change since the last release?**
   `git log --oneline -1 -- HelioFITSExtension/cfitsio/fitsshim.c` vs the last
   release tag. If yes:

       ./HelioFITSExtension/cfitsio/build-universal.sh
       lipo -archs HelioFITSExtension/cfitsio/libcfitsio.a   # expect: x86_64 arm64

   This is not optional. `fitsshim.c` is in no Xcode target — it is baked into
   the vendored library, and forgetting this step means editing the shim does
   *nothing* while every test still passes (this shipped silently in 1.3.0).

2. **Clean tree.** `git status --short` — commit or stash anything unexpected
   before touching version numbers.

3. **Bump the version**, all ten targets in one shot:

       sed -i '' 's/MARKETING_VERSION = <OLD>;/MARKETING_VERSION = <NEW>;/g' HelioFITS.xcodeproj/project.pbxproj
       sed -i '' 's/CURRENT_PROJECT_VERSION = <OLDN>;/CURRENT_PROJECT_VERSION = <NEWN>;/g' HelioFITS.xcodeproj/project.pbxproj
       grep -oE "MARKETING_VERSION = [0-9.]+;|CURRENT_PROJECT_VERSION = [0-9]+;" HelioFITS.xcodeproj/project.pbxproj | sort | uniq -c
       # expect: 10 of each, matching the new values

4. **Run the tests.** `pkill -x HelioFITS` first (never `pkill` again while a
   run is in flight — the test host IS the app, and killing it produces a
   misleading "crashed with signal term" that looks like a real failure):

       xcodebuild test -project HelioFITS.xcodeproj -scheme HelioFITS \
         -destination 'platform=macOS,arch=arm64' \
         DEVELOPMENT_TEAM=UB45PPC2JS CODE_SIGN_IDENTITY="-" \
         CODE_SIGN_STYLE=Manual AD_HOC_CODE_SIGNING_ALLOWED=YES
       ./lsclean.sh

   If step 1 rebuilt the library, **also** run on x86_64 (Rosetta) — that
   slice is otherwise never exercised on this Mac:

       xcodebuild test ... -destination 'platform=macOS,arch=x86_64'

5. **Write `CHANGELOG.md`** — new section at the top, Added/Changed/Fixed,
   linked issues, written for the GitHub reader (mechanism, not just
   symptom). See [RELEASING.md](../../../RELEASING.md) step 4 for the
   two-tier convention: the changelog is the long form, the App Store box is
   a separate short pass done later, in App Store Connect, by Gilly.

6. **Commit and tag:**

       git add -A && git commit -m "..."
       git tag -a v<VER>-build.<N> -m "..."
       git push && git push origin v<VER>-build.<N>

7. **Direct-download channel:** `./ship.sh`. The Apple timestamp service
   flakes intermittently — if it fails on `A timestamp was expected but was
   not found`, that is Apple's TSA, not the build. Probe it cheaply before
   blind-retrying:

       clang -o /tmp/tsprobe -x c -; codesign --force --timestamp -o runtime \
         --sign "Developer ID Application: CHRISTOPHER RAYMOND GILBERT (UB45PPC2JS)" /tmp/tsprobe

   If that succeeds, retry `ship.sh`; a short backoff loop (a few attempts,
   tens of seconds apart) is reasonable. If it keeps failing after several
   clean probes, stop and say so rather than looping indefinitely.

8. **Publish the GitHub release**, notes assembled from the CHANGELOG section
   just written plus an install footer (see the pattern in prior releases —
   `gh release view <prior-tag> --json body`):

       gh release create v<VER>-build.<N> build/HelioFITS-<VER>-b<N>.zip \
         --title "HelioFITS <VER> (build <N>)" --notes-file <path>

9. **App Store archive**, straight into the Organizer library so Gilly can
   also drive it by hand if he wants to:

       xcodebuild -project HelioFITS.xcodeproj -scheme HelioFITS \
         -configuration Release -destination 'generic/platform=macOS' \
         -archivePath "$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/HelioFITS <VER> (<N>).xcarchive" archive

   Verify it's universal and MAS-clean (no Spotlight importer under
   `Contents/Library/Spotlight`) before uploading.

10. **Export and upload to App Store Connect** — no password needed, this
    rides on Xcode's already-signed-in account:

        cat > /tmp/exportOptions.plist <<'EOF'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>method</key><string>app-store-connect</string>
            <key>destination</key><string>upload</string>
            <key>teamID</key><string>UB45PPC2JS</string>
            <key>signingStyle</key><string>automatic</string>
        </dict></plist>
        EOF
        xcodebuild -exportArchive -archivePath "<archive path from step 9>" \
          -exportOptionsPlist /tmp/exportOptions.plist -exportPath /tmp/hf-export

    If this fails with an account/team error, that's the Xcode account
    session, not this pipeline — check Xcode ▸ Settings ▸ Accounts. A recent
    Apple ID password change invalidates it; re-add the account (2FA re-auth
    is Gilly's, not automatable).

11. **Hand off.** Tell Gilly plainly: code is shipped, GitHub release is
    live, build N is uploaded and Processing in App Store Connect. He still
    needs to (a) create/select the version record, (b) attach the build once
    Processing finishes, (c) write the short-form What's New, (d) confirm
    screenshots, (e) Add for Review then Submit to Review — two separate
    buttons on two pages. Don't say "shipped" or "live" for the store channel
    until he's done that.

## Things that have actually gone wrong here before

- Editing `fitsshim.c` without rebuilding `libcfitsio.a` — silent no-op,
  shipped in 1.3.0, cost a full extra release to fix (1.3.1).
- `pkill -x HelioFITS` while a test run is in flight — fails the run with a
  misleading crash message.
- Treating one Apple timestamp-server failure as a build problem instead of
  probing the TSA directly first.
- Assuming an Xcode archive is MAS-clean without checking for the Spotlight
  importer — `ship.sh`'s embed step runs on Channel B builds only, so a plain
  Xcode archive for the Store should never have it, but confirm each time.
