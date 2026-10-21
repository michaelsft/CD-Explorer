# Changelog

## 3.2 - 2026-10-21

- Added bundled libmpv playback and direct In/Out-point jump controls to the frame-accurate Adjust Clip editor, including MPEG-2/AC-3 MKV support without external software.
- Added blue selected-state indicators to the Adjust Clip Set In and Set Out buttons.
- Kept paused and frame-stepped Adjust Clip previews on the same libmpv rendering path as playback, preserving identical picture size and proportions.
- Kept loaded-video conversion options open after choosing a destination so settings can be adjusted and another conversion started without reloading the source.
- Standardised the spacing between all creation and processing options in the video-conversion dialog.

## 3.1 - 2026-10-20

- Added optional, metadata-only Rec.709 primaries, transfer, matrix and limited-range replacement in both H.264 VUI and MP4 container metadata for converted videos intended for YouTube.
- Added lossless H.264 video stream copying when Rec.709 tagging is the only requested video change.
- Enlarged the embedded-border adjustment preview, anchored its controls at the bottom and reduced the crop-outline thickness.

## 3.0 - 2026-10-19

- Added secure audio extraction with WAV, AIFF, FLAC, MP3 and AAC output.
- Added CD-Text and selectable MusicBrainz metadata matches.
- Added hidden pre-gap detection and optional separation of audio divided by long silence.
- Added complete Enhanced-CD data-session browsing and extraction.
- Added ISO and raw IMG scanning.
- Added direct audio preview and seeking.
- Added local-video loading and H.264/AAC conversion.
- Added original-size, DVD PAL/NTSC, 720p and 1080p video outputs.
- Added frame-accurate clip ranges, aspect correction, border removal and picture adjustment.
- Added interlace detection, BWDIF deinterlacing and motion-compensated frame-rate conversion.
- Bundled universal FFmpeg and FFprobe executables and their licence information.

