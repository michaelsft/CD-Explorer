# Public release checklist

## One-time repository setup

1. Create a public GitHub repository named `CD-Explorer`.
2. Set the repository licence to GPL-3.0-or-later.
3. Add the description: `Preserve audio CDs, Enhanced CDs and their data files on modern macOS.`
4. Add topics such as `macos`, `swift`, `swiftui`, `audio-cd`, `enhanced-cd`, `cd-ripper`, `ffmpeg` and `musicbrainz`.
5. Confirm the MusicBrainz User-Agent identifies the current version and repository URL.

## Before each release

1. Update `CFBundleShortVersionString` in `Info.plist` and update `CHANGELOG.md`.
2. Confirm `ThirdParty/DEPENDENCIES.md` matches the bundled binaries.
3. Commit and tag the exact release source, for example `v3.0`.
4. Run `bash Scripts/build_release.sh 3.0`.
5. Run `bash Scripts/verify_release.sh 3.0`.

## GitHub Release assets

Upload all three files from `dist/` to the same release:

- `CD-Explorer-3.0.dmg`
- `CD-Explorer-3.0-Third-Party-Source.tar.gz`
- `SHA256SUMS-3.0.txt`

Do not upload the DMG without its corresponding third-party source archive and checksum file.

## Final checks

- Test the DMG from a clean macOS account or another Mac.
- Confirm the app reports the intended version without a duplicate build number.
- Confirm both Intel and Apple-silicon slices are present.
- Confirm the app bundle and DMG contain the licence and third-party notices.
- Confirm the icon in the packaged app matches `CD Explorer Icon.png`.
- Confirm the release tag points to the exact commit used for the build.
- Download all release assets and verify `SHA256SUMS-X.Y.txt`.
- If distributing broadly, Developer ID sign, enable hardened runtime, notarise and staple the DMG.

