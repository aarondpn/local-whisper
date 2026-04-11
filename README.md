<h1 align="center">LocalWhisper</h1>

<p align="center">
  A menu-bar speech-to-text app for macOS.<br/>
  Hold a hotkey, talk, let go, and your words show up wherever the cursor is.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/SwiftUI-MenuBarExtra-007AFF?style=for-the-badge&logo=swift&logoColor=white" alt="SwiftUI">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge&logo=opensourceinitiative&logoColor=white" alt="License">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OpenAI-Whisper-412991?style=for-the-badge&logo=openai&logoColor=white" alt="OpenAI Whisper">
  <img src="https://img.shields.io/badge/Groq-Whisper-F55036?style=for-the-badge&logo=groq&logoColor=white" alt="Groq">
  <img src="https://img.shields.io/badge/WhisperKit-Local-34C759?style=for-the-badge&logo=apple&logoColor=white" alt="WhisperKit">
</p>

---

## Why

macOS already has dictation built in. In practice it wants the cloud, it fights global hotkeys, and it only really plays nice inside Apple's own apps. LocalWhisper is what I built instead.

- Push-to-talk from any app. Hold the hotkey, speak, release, and the transcript lands at the cursor.
- Pick the engine you want: OpenAI Whisper, Groq Whisper when you want it fast, or a fully local [WhisperKit](https://github.com/argmaxinc/WhisperKit) model that never touches the network.
- Each app can carry its own profile (language, provider, prompt). LocalWhisper swaps to it when focus changes.
- It lives in the menu bar, not the dock. Nothing leaves your machine unless you pick a cloud provider.

## Features

| | |
|---|---|
| **Push-to-talk hotkey** | Hold any key or chord to record. Release to transcribe. |
| **Three providers** | OpenAI Whisper, Groq Whisper, or on-device WhisperKit. |
| **Per-app profiles** | Bind a language, provider, and custom prompt to each bundle ID. |
| **Dynamic context** | Feeds the focused window title (and selected text) into the prompt so jargon, names, and identifiers survive the round trip. |
| **Customizable HUD** | Floating overlay with waveform, timer, theme, and screen position. |
| **Auto-paste** | Drops the transcript at the cursor. Optional Enter afterward for chat apps. |
| **Audio hygiene** | Silence trim, minimum-duration filter, input-level boost, optional system-audio mute while recording. |
| **Offline mode** | Local models (tiny → large-v3_turbo) download once, then run with the network off. |
| **Statistics and history** | Running totals and recent transcripts, stored locally. |

## Installation

### Homebrew (recommended)

```bash
brew tap aarondpn/tap
brew install --cask local-whisper
```

The cask is bumped automatically on every release.

### Manual download

Grab the latest signed build from [GitHub Releases](https://github.com/aarondpn/local-whisper/releases/latest), drag `LocalWhisper.app` to `/Applications`, and launch it.

On first launch macOS will ask for two permissions: microphone access, so it can actually hear you, and accessibility access, so the hotkey works in any app and the transcript can be pasted into the focused field.

### Build from source

Requires Xcode 15+ on macOS 14+.

```bash
git clone https://github.com/aarondpn/local-whisper.git
cd local-whisper
open local-whisper.xcodeproj
```

Or from the CLI:

```bash
xcodebuild -project local-whisper.xcodeproj \
           -scheme local-whisper \
           -configuration Release \
           -derivedDataPath build \
           build
```

## Getting started

1. Open the menu-bar popover, then *Settings…* → *Shortcut*, and record any key or chord.
2. Under *Settings… → API Keys*, paste an OpenAI or Groq key. Or, under *General*, download a local WhisperKit model instead.
3. In any app, hold the shortcut, speak, release. The transcript is pasted at the cursor.

## Providers

| Provider | Runs | Good for | Setup |
|---|---|---|---|
| **Groq Whisper** | Cloud | Very fast, cheap per minute | Paste a Groq API key |
| **OpenAI Whisper** | Cloud | Best on accented and non-English audio | Paste an OpenAI API key |
| **Local (WhisperKit)** | On-device, Apple Silicon | Works offline, no per-minute cost | Pick a model in *Settings → General*; the first run downloads it |

You can switch the active provider from the menu bar at any time, or pin one per app via profiles.

## Per-app profiles

Profiles bind to an app's bundle ID and override the language, provider, and prompt while that app is frontmost. For example: a Slack profile using Groq, English, and a prompt listing teammate names. LocalWhisper switches to it when Slack takes focus.

Turn on **Dynamic Context** (in Settings, under Context) and LocalWhisper will also feed the focused window title, and the current text selection when macOS exposes it, into the prompt. That is usually enough to get project names, colleagues, and internal jargon right, so you do not have to keep a glossary in sync by hand.

## Privacy

LocalWhisper records audio only while you are holding the hotkey. If you picked the Local provider, that audio never leaves the machine at all. If you picked OpenAI or Groq, it is sent to that provider's transcription endpoint and nowhere else. Statistics and history live in `UserDefaults` on your Mac. There is no analytics backend and no crash reporter.

## License

[MIT](LICENSE) © 2026 aarondpn
