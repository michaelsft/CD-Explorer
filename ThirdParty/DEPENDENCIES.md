# Third-party dependencies

## Bundled runtime components

| Component | Version | Licence | Purpose |
| --- | --- | --- | --- |
| FFmpeg | 9.0.2 | GPLv2 or later for this build | Video/audio inspection, conversion and encoded audio output |
| FFprobe | 9.0.2 | GPLv2 or later for this build | Media stream inspection |
| x264 | revision `0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee` | GPLv2 | H.264 video encoding through FFmpeg |

FFmpeg and x264 are statically combined into the bundled `ffmpeg` and `ffprobe` command-line executables. CD Explorer invokes those executables as separate processes.

The executables are universal Mach-O files containing Apple-silicon and Intel slices. They depend only on frameworks and libraries supplied with macOS.

## External service

CD Explorer optionally queries the MusicBrainz web API for disc metadata. No MusicBrainz software or database is bundled. MusicBrainz core data is CC0; use of the public API is governed separately by its service policy and rate limits.

## System components

The application uses Apple frameworks and command-line utilities supplied by macOS, including SwiftUI, AppKit, AVFoundation, Foundation, `drutil`, `diskutil` and `afinfo`. These are operating-system dependencies and are not redistributed by this repository.

## Build-only tools

Xcode command-line tools, ImageMagick and `create-dmg` are required to create a release. They are not bundled in the application.

