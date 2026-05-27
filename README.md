# M4BCreater

Native macOS 14+ SwiftUI app for converting scattered audiobook audio files into `.m4b` with a bundled FFmpeg pipeline.

## Current Implementation

- SwiftUI three-column macOS interface.
- Local input and local output task creation.
- Optional WebDAV input/output locations.
- WebDAV credentials stored through Keychain references.
- WebDAV source files use local per-task segmented cache before conversion.
- Final `.m4b` is generated in the task work directory before local copy or WebDAV upload.
- Persistent task state, metadata, cache index, and settings.
- Pause/resume/cancel controls backed by FFmpeg process control.
- Local metadata inspection from folder name, `metadata.json`, `.nfo`, and cover images.
- OpenLibrary scraping for first-pass metadata candidates.

## Build

```sh
swift build
```

## Run

```sh
swift run M4BCreater
```

## Bundled FFmpeg

Place executable binaries here before packaging:

- `Sources/M4BCreater/Resources/FFmpeg/ffmpeg`
- `Sources/M4BCreater/Resources/FFmpeg/ffprobe`

The app starts without them, but conversion jobs fail until `ffmpeg` is present and executable.

The currently bundled binaries are `x86_64`; they run on Apple Silicon through Rosetta. For release packaging, prefer `arm64` or universal binaries.
