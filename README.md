# spectacle

Screen and system audio capture from the command line, using native OS APIs. No FFmpeg, no Electron, no external dependencies.

```bash
spectacle record --output demo.mp4              # record screen + audio
spectacle record --app "Chrome" --output t.mp4  # capture a specific app
spectacle record --no-audio --output silent.mp4  # video only
spectacle record --no-cursor --output clean.mp4  # hide cursor
spectacle audio --output meeting.wav             # audio only
spectacle audio --app "Spotify" --output music.wav
spectacle list displays                          # list capture targets
spectacle list windows
spectacle list audio-sources
```

Built in Zig. Currently macOS-only (ScreenCaptureKit + Core Audio Taps). Windows and Linux support planned.

## Install

```bash
brew install georgemandis/tap/spectacle
```

Or build from source:

```bash
zig build -Doptimize=ReleaseFast
```

## Options

| Flag | Description |
|------|-------------|
| `--output FILE` | Output file path (.mp4 or .mov for video, .wav for audio) |
| `--window NAME` | Capture a specific window by title |
| `--pid PID` | Capture a specific window by process ID |
| `--app NAME` | Capture a specific app by name |
| `--display N` | Which display to capture (default: 0) |
| `--region X,Y,W,H` | Capture a screen region |
| `--no-audio` | Video only, suppress audio capture |
| `--no-cursor` | Hide the cursor in the recording |
| `--fps N` | Frame rate (default: 30) |
| `--scale F` | Resolution scale factor (default: 1.0) |
| `--sample-rate N` | Audio sample rate in Hz (default: 48000) |
| `--channels N` | Audio channel count (default: 2) |

## Platform Support

| Platform | Screen | Audio | Encoder |
|----------|--------|-------|---------|
| macOS | ScreenCaptureKit | Core Audio Taps | AVAssetWriter |
| Windows | planned | planned | planned |
| Linux | planned | planned | planned |

## License

MIT
