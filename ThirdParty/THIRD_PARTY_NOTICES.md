# Third-party notices

## FFmpeg and FFprobe

CD Explorer bundles FFmpeg and FFprobe 9.0.2 from the FFmpeg project.

This build was configured with `--enable-gpl` and `--enable-libx264`, so the bundled FFmpeg executables are distributed under the GNU General Public License version 2 or later.

- Project: https://ffmpeg.org/
- Exact source: `ffmpeg-9.0.2.tar.xz`
- SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`

The full GPLv2 text and detailed configure information are included under `BundledTools/` and inside the built application.

## x264

The FFmpeg executables include the x264 encoder at revision `0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee`.

- Project: https://code.videolan.org/videolan/x264
- Exact source archive: `x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz`
- SHA-256: `d0967a1348c85dfde363bb52610403be898171493100561efa0dd05d5fd1ae50`
- Licence: GNU General Public License version 2

## MusicBrainz

CD Explorer optionally retrieves disc metadata from MusicBrainz. MusicBrainz is not bundled and is not affiliated with this project. MusicBrainz core data is made available under CC0.

MusicBrainz documentation and service terms: https://musicbrainz.org/doc/MusicBrainz_API

## MPVKit and libmpv

CD Explorer links the `MPVKit-GPL` product from MPVKit 1.0.0 into the application to provide embedded video and audio playback in Adjust Clip. The package contains libmpv and its required media libraries for Apple silicon and Intel Macs; users do not need to install mpv separately.

- MPVKit project: https://github.com/mpvkit/MPVKit
- Exact release: https://github.com/mpvkit/MPVKit/releases/tag/1.0.0
- mpv project: https://mpv.io/
- Package licence file: GNU Lesser General Public License version 3

The complete MPVKit licence text is included as `ThirdParty/MPVKit-LICENSE.txt` and inside the built application. CD Explorer itself is distributed under GPLv3 or later, which is compatible with the bundled GPL build.

## LAME

CD Explorer bundles the LAME 3.100 command-line encoder for MP3 output. The executable is built from the official source and distributed under the GNU Library General Public License version 2.

- Project: https://lame.sourceforge.io/
- Exact source archive: `lame-3.100.tar.gz`
- SHA-256: `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`

The complete licence text is included as `BundledTools/COPYING.LAME` and inside the built application.

## Opus encoding components

CD Explorer bundles `opusenc` from opus-tools 0.2, statically linked with Opus 1.5.2, libopusenc 0.2.1, opusfile 0.12 and libogg 1.3.5. These components use their respective Xiph.Org BSD-style licences; the combined licence material is included as `BundledTools/COPYING.Opus` and inside the built application. Exact source checksums are recorded in `Scripts/audio_encoder_sources.sha256`.

## Cover Art Archive

When a MusicBrainz release is selected, CD Explorer can retrieve its front-cover image from the Cover Art Archive. The service and images are not bundled with the application.

