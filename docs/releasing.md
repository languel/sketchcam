# Publishing a release

CI artifacts and GitHub Releases serve different purposes. The current
[workflow](../.github/workflows/ci.yml) builds/tests branches and produces a
signed/notarized artifact for successful `main` runs. It does **not** publish a
release or run specially when a tag is pushed. The artifact is retained for
14 days. A release is a deliberate, versioned publication with its own assets.

## Prerelease or stable?

- **Prerelease:** publish a milestone for testing and feedback. Set the GitHub
  prerelease flag; for example, `v0.1.0` is an early prerelease.
- **Stable release:** publish a version considered ready for general use. Leave
  the prerelease flag off and write release notes describing changes/limits.

A tag such as `v0.1.0` identifies the source commit. It does not by itself make
the version stable; the GitHub Release's prerelease flag records that distinction.

## Procedure

1. Update `CFBundleShortVersionString` in both app and camera-extension Info.plists.
   Keep their `CFBundleVersion` values aligned and increase the build number
   from the previous distributed build. Do not change the bundle identifiers.
2. Update the user documentation/release notes and icon assets as needed.
3. Commit and push to `main`. Wait for **Build and Test**, including the signed
   and notarized distribution job, to succeed for that exact commit.
4. Download its artifact. Verify the checksum and inspect the app's version,
   bundled icon, signatures and stapled ticket. Check which architectures the
   main executable includes. Do not substitute an older artifact for a newly
   tagged version.
5. Create an annotated `v…` tag on the tested commit and push it. Create a draft
   GitHub Release for that tag, attach the already-built ZIP/checksum, and mark
   it as a prerelease if appropriate.
6. Publish after the assets and notes are ready. Verify the published release's
   flag, tag/commit, download assets and checksums. The tested ZIP is promoted
   unchanged; it is not rebuilt or re-signed for publication.

Release notes should include minimum macOS version, supported architectures,
installation/extension activation, notable features, and material limitations
(for example, the virtual camera is video-only). Link to
[getting started](getting-started.md) for full instructions.

New `main` commits after publication keep generating development artifacts and
do not modify the published release. Further releases require another explicit
publication. No automatic-update feed is currently published by this workflow.
