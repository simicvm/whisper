# Whisper

A macOS menu bar app for on-device speech-to-text. Hold a hotkey, speak, release — transcribed text is pasted into the active application automatically.

All processing runs locally using [Qwen3 ASR](https://huggingface.co/collections/mlx-community/qwen3-audio-6848a88a82aeef3874bf1543) models via Apple's MLX framework. No audio leaves your machine.

## Features

- **Push-to-talk hotkey** — configurable two-modifier combinations (e.g. Left Cmd + Left Ctrl) detected via a global CGEvent tap
- **Multiple model options** — Qwen3 ASR 0.6B (8-bit), 1.7B (8-bit), and 1.7B (4-bit) with on-demand downloading and per-model cache management
- **Smart paste** — transcribed text is written to the pasteboard, Cmd+V is simulated via Accessibility, and the original clipboard contents are restored afterward; a space is prepended when the cursor follows non-whitespace
- **Visual feedback** — animated floating overlay with a MeshGradient whose speed responds to real-time audio level
- **Menu bar UI** — model selector with download/delete controls, permission status indicators, hotkey preset picker, and run-on-startup toggle
- **Privacy-first** — fully offline inference, no network calls after model download

## Requirements

- macOS (Apple Silicon recommended for MLX performance)
- Xcode (for building from source)
- Microphone permission
- Accessibility permission (for simulating paste keystrokes and detecting cursor context)

## Installation

1. Open `whisper.xcodeproj` in Xcode. Go to the **whisper** target, then **Signing & Capabilities**, enable **Automatically manage signing**, and select your Team (Personal Team works for local use).

2. Build a Release app bundle:
   ```
   xcodebuild -project whisper.xcodeproj -scheme whisper -configuration Release -derivedDataPath build clean build
   ```

3. Copy the built `.app` into `/Applications`:
   ```
   cp -R "build/Build/Products/Release/whisper.app" /Applications/
   ```

4. Launch from `/Applications` (not from DerivedData):
   ```
   open /Applications/whisper.app
   ```

5. Grant **Microphone** and **Accessibility** permissions when prompted.

> **Why `/Applications` matters** — the Run on Startup toggle uses `SMAppService.mainApp`, which works most reliably when the app is installed in `/Applications` and properly signed.

> **If macOS blocks launch** — right-click the app and choose Open, or remove quarantine:
> ```
> xattr -dr com.apple.quarantine /Applications/whisper.app
> ```

## How It Works

1. A global CGEvent tap listens for a specific modifier-key combination (left/right aware).
2. On key-down, `AVAudioEngine` begins capturing microphone input at the native sample rate.
3. On key-up, recording stops. Audio is resampled to 16 kHz and passed to the Qwen3 ASR model running on-device via MLX.
4. The transcribed text is placed on the pasteboard, a Cmd+V keystroke is simulated through the Accessibility API, and the original pasteboard contents are restored.

## Architecture

```
whisperApp.swift          App entry point, hotkey wiring, lifecycle
AppState.swift            Observable state machine (idle/recording/transcribing/pasting/error)

Services/
  TranscriptionService    Actor-isolated ML inference, model download & cache
  AudioRecorder           AVAudioEngine capture, RMS level, 16 kHz resampling
  PasteController         Pasteboard snapshot/restore, Cmd+V simulation

Views/
  MenuBarView             Dropdown menu (models, permissions, settings)
  RecordingOverlay        Animated MeshGradient circle
  OverlayManager          Overlay lifecycle
  OverlayPanel            Non-activating transparent NSPanel

Models/
  STTModelDefinition      Model registry (name, HuggingFace repo, quantization)

Hotkey/
  HotkeyDefinitions       CGEvent tap, modifier presets, UserDefaults persistence
```

## Dependencies

| Package | Purpose |
|---------|---------|
| [mlx-audio-swift](https://github.com/jkrukowski/mlx-audio-swift) | MLX-based audio STT inference (MLXAudioSTT, MLXAudioCore) |
| [MLX](https://github.com/ml-explore/mlx-swift) | Apple's ML array framework |
| [HuggingFace Swift client](https://github.com/huggingface/swift-transformers) | Model downloading and hub integration |

## License

See [LICENSE](LICENSE) for details.
