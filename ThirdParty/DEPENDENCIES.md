# Third-party dependencies

## Bundled runtime components

| Component | Version | Licence | Purpose |
| --- | --- | --- | --- |
| FFmpeg | 9.0.2 | GPLv2 or later for this build | Video/audio inspection, conversion and encoded audio output |
| FFprobe | 9.0.2 | GPLv2 or later for this build | Media stream inspection |
| x264 | revision `0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee` | GPLv2 | H.264 video encoding through FFmpeg |
| MPVKit-GPL / libmpv | MPVKit 1.0.0 | GPL-compatible build; MPVKit wrapper LGPLv3 | Embedded playback in the Adjust Clip editor |
| LAME (`lame`) | 3.100 | LGPLv2 | MP3 encoding, ID3v2 tags and embedded cover art |
| opus-tools (`opusenc`) with Opus, libopusenc, opusfile and libogg | 0.2; Opus 1.5.2; libopusenc 0.2.1; opusfile 0.12; libogg 1.3.5 | BSD-style (Xiph.Org) | Opus encoding, Vorbis comments and embedded cover art |

FFmpeg and x264 are statically combined into the bundled `ffmpeg` and `ffprobe` command-line executables. CD Explorer invokes those executables as separate processes.

The executables are universal Mach-O files containing Apple-silicon and Intel slices. They depend only on frameworks and libraries supplied with macOS.

MPVKit-GPL is linked statically into the CD Explorer executable for Apple silicon and Intel. It supplies libmpv and its media libraries, so Adjust Clip playback requires no separately installed player or codec package. The exact package release is pinned by `Package.resolved`.

`lame` and `opusenc` are universal command-line executables built from the official source archives by `Scripts/build_audio_encoders.sh` (checksums in `Scripts/audio_encoder_sources.sha256`), statically linked so they depend only on macOS. CD Explorer invokes them as separate processes.

## External service

CD Explorer optionally queries the MusicBrainz web API for disc metadata, and the Cover Art Archive (coverartarchive.org) for the chosen release's front cover. No MusicBrainz software or database is bundled. MusicBrainz core data is CC0; use of the public API is governed separately by its service policy and rate limits.

## System components

The application uses Apple frameworks and command-line utilities supplied by macOS, including SwiftUI, AppKit, Foundation, OpenGL, `drutil`, `diskutil` and `afinfo`. These are operating-system dependencies and are not redistributed by this repository.

## Build-only tools

Xcode command-line tools, ImageMagick and `create-dmg` are required to create a release. They are not bundled in the application.

