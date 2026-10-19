# Contributing

Bug reports and focused pull requests are welcome.

Before submitting a change:

1. Build with `./build.sh` on macOS 13 or later.
2. Confirm the application works on the architecture you can test.
3. Keep physical-disc reads bounded and cancellable.
4. Do not silently substitute damaged audio sectors.
5. Preserve source aspect ratio unless the user explicitly selects an aspect correction.
6. Keep optional online metadata optional.
7. Run `codesign --verify --deep --strict "build/CD Explorer.app"`.
8. Update `CHANGELOG.md` when behaviour visible to users changes.

Contributions are accepted under the repository's GPL-3.0-or-later licence.

