# 🎙️ Whisper-Me

A lightweight, native macOS menu bar application written in **Swift** for global voice dictation. Powered by **Google Gemini** (real-time streaming) and **OpenRouter** (Whisper models).

Works everywhere across macOS: Terminal, Cursor, VS Code, Slack, Telegram, browsers, and notes.

---

## ✨ Features

- **Global Voice Dictation:** Place cursor in any text field, press your shortcut, speak, and the transcribed text is typed right into the focused app.
- **Two Transcription Providers:**
  - **Google Gemini:** Real-time streaming via Bidirectional Live API (text flows as you speak) with batch fallback.
  - **OpenRouter:** Batch audio transcription (`/audio/transcriptions`) with automatically fetched model options (e.g. `openai/whisper-large-v3-turbo`).
- **Interactive Shortcut Recorder:** Press any key combination to record your hotkey (⌘, ⌥, ⌃, or standalone Function keys like F8). Reset to default (⌘⇧D) or clear anytime.
- **Multilingual In-App Interface:** Automatically adapts to your macOS system language (English / Russian) or can be switched manually in Settings.
- **Pure Native Swift:** No Electron, no Python, no Node.js. Instant startup, minimal memory and CPU footprint.
- **Universal Binary:** Single build supporting both Apple Silicon (arm64) and Intel (x86_64) on macOS 13 (Ventura) and later.
- **Custom Technical Vocabulary:** Provide domain terms and names to enhance recognition accuracy (Gemini).
- **Speech Cleanup:** Smart model/API cleanup by default, with optional conservative local filtering of isolated hesitation sounds or verbatim recognition.
- **Sound Signals & Autostart:** Subtle audio cues on record start/stop, optional launch at system login (`SMAppService`).

---

## 🚀 Quick Start

### Build & Run from Source

**Prerequisites:** macOS 13.0+ and Xcode Command Line Tools:
```bash
xcode-select --install
```

**Build:**
```bash
# Build universal binary (both Apple Silicon & Intel)
./build.sh

# Or build for specific architecture
./build.sh arm64      # Apple Silicon (M1/M2/M3/M4)
./build.sh intel      # Intel x86_64
```

**Launch:**
```bash
open build/WhisperMe.app
# Or via CLI symlink:
./whisper-me-bin
```

When launched, a 🎙️ icon appears in your macOS menu bar.

---

## 🛡️ macOS Security & Gatekeeper Approval

When opening an app downloaded from GitHub or built without an Apple Developer certificate ($99/yr), macOS Gatekeeper may show a warning:
> *"WhisperMe is damaged and can't be opened"* or *"macOS cannot verify the developer"*.

This is standard macOS protection for non-notarized software. You can approve the app using any of the following methods:

### Method 1: Right-Click "Open" (No Terminal Needed)
1. In **Finder**, locate `WhisperMe.app`.
2. **Right-click** (or Control-click) on the app and select **Open** from the menu.
3. In the confirmation dialog, click **Open**.
4. macOS will remember your approval; subsequent launches will open directly.

### Method 2: System Settings Approval
1. Open **System Settings** (or System Preferences).
2. Navigate to **Privacy & Security** → scroll down to the **Security** section.
3. Under *"Allow applications downloaded from"*, locate the message *"WhisperMe was blocked from opening"*.
4. Click **Open Anyway** and enter your Mac password if prompted.

### Method 3: Terminal Command (Remove Quarantine Attribute)
Run this command in Terminal:
```bash
xattr -cr /Applications/WhisperMe.app
# Or if running from the project build folder:
xattr -cr build/WhisperMe.app
```
This clears the `com.apple.quarantine` extended attribute set by macOS during download or extraction.

---

## 🎙️ How to Use

1. Click into **any text input field** in any app.
2. Press **Cmd + Shift + D** (or your custom shortcut). The menu bar icon changes to 🔴 (recording).
3. Speak your phrase or sentence.
4. Press the shortcut again to stop.
5. Transcribed text is automatically inserted into your active input field.

---

## ⚙️ Configuration

Click the menu bar icon 🎙️ → **Settings…**:

- **Provider:** Switch between Gemini and OpenRouter. Keys and models are isolated per provider.
- **API Key:** UI keys are stored in macOS Keychain, not preferences. Existing preference keys migrate only after a successful Keychain write. Alternatively use `.env` (see below); only edited keys are saved, and explicitly deleting an existing key overrides `.env`. Saving unrelated settings does not create an empty-key override.
- **Model:** Select recognition model (built-in for Gemini, dynamically fetched for OpenRouter).
- **Hotkey:** Click the shortcut box and press your preferred keys (e.g. `⌥Space` or `⌘⇧D`).
- **Text Insertion Mode:** Real-time streaming (words inserted as you speak) or all-at-once after recording stops.
- **Language:** Choose between System (Auto), English, or Russian.
- **Vocabulary:** Enter specialized terminology or proper nouns (comma-separated).
- **Clean Speech:** Select speech cleanup mode:
  - **Smart Mode (Model / API):** Recommended default. Uses native model capabilities (Gemini `SMART` transcription mode in Live and Interactions API, prompt instructions in Flash, and forwarded `provider.options` in OpenRouter for Google, OpenAI, Groq).
  - **Manual Filter (Regex):** Post-processing regex filter removing isolated hesitation sounds ("ээ", "мм", "а-а", "um", "uh") with punctuation and casing repair.
  - **Disabled (Verbatim):** Verbatim recognition preserving all spoken sounds and disfluencies.
- **Accessibility:** Ensure Accessibility permissions are granted so the app can insert text.

Provider-specific key/model drafts survive switching providers. Save applies them; Cancel or closing the window discards edits (including the language preview and launch-at-login checkbox).

On Live connection failure the complete backup WAV is transcribed instead of reconnecting across a gap. If streaming text has already been submitted for insertion, the recovered full text is saved to History without inserting it again. Otherwise it is inserted normally. Insertion jobs are serialized; a successful or ambiguous/timed-out AX write is never retried with Cmd+V. Clipboard fallback restores prior contents only if the clipboard has not since changed. Known secure text fields are excluded from both AX and clipboard insertion.

The manual filter removes isolated sounds, not meaningful words such as Russian `а`, `ну`, or `вот`. It preserves ordinary words, directly quoted sound literals, numeric `мм` measurements and paragraph breaks.

In manual mode with streaming, the app holds the last incomplete token until another word or the final event arrives, so a partial `э` is not discarded before it becomes `экран`. In Smart mode, the model itself performs disfluency removal and smart formatting upstream without crude regular expression replacements.

For OpenRouter, provider-specific options (`transcription_config` for Google AI Studio, `prompt` for OpenAI/Groq) are forwarded via `provider.options` according to OpenRouter STT documentation. No second LLM call is added.

For comparison, [Codex CLI v0.105.0 source](https://github.com/openai/codex/blob/rust-v0.105.0/codex-rs/tui/src/voice.rs) sends recorded WAV to `gpt-4o-transcribe` with API-key auth, or to ChatGPT's `/backend-api/transcribe` with ChatGPT auth. That client returns server text without a local filler-removal pass; this does not reveal the desktop app's implementation or the server's internal cleanup. [OpenAI's archived Whisper prompting guide](https://developers.openai.com/cookbook/examples/whisper_prompting_guide) explains that Whisper imitates prompt style rather than following imperative instructions, so a prompt alone is not a reliable removal guarantee.

### Environment Variables (`.env`)

You can create a `.env` file in the project root instead of entering keys in the GUI:

```bash
cp .env.example .env
```

Edit `.env`:
```env
# Google Gemini API Key (https://aistudio.google.com/apikey)
GEMINI_API_KEY=your_gemini_api_key

# OpenRouter API Key (https://openrouter.ai/settings/keys)
OPENROUTER_API_KEY=sk-or-your_openrouter_key
```

> **Note:** `.env` is ignored by Git (`.gitignore`) and keys are never committed.

---

## 🌐 Providers Comparison

| Feature | **Google Gemini** | **OpenRouter** |
|---|---|---|
| Key in `.env` | `GEMINI_API_KEY` | `OPENROUTER_API_KEY` |
| Streaming (Live API) | ✅ Yes (words stream as you speak) | ❌ Batch only |
| Models list | Built-in (`gemini-3.5-transcribe`, `gemini-3.1-flash-lite`) | Dynamically fetched from `/models` |
| Custom Vocabulary | ✅ Yes (`prompt` support) | ❌ Not supported by STT API |

---

## 🧪 Tests

The runner checks pure domain logic, Gemini HTTP handling with a stubbed `URLProtocol`, and Live lifecycle behavior with an in-memory WebSocket. No microphone, API credentials or real network requests are needed:

```bash
./tests/run.sh
```

Tests cover Live API WebSocket URL construction, delta text generation, transcript segment management, hotkey formatting, validation, language resolution, OpenRouter payload/response parsing, Gemini HTTP/transport errors, malformed responses, multipart text, auth headers, model fallback, credential draft persistence, AX retry decisions, Live stop without `turnComplete`, coalescing final segments, incomplete-final timeout recovery, audio-drain ordering, stale callbacks after restart, and failed-start cleanup.

Manual checks still required with macOS permissions and real providers: microphone start failure, Live stop/final timing and disconnection recovery, rapid streaming insertion in AX editors and terminals, clipboard preservation, secure fields, Keychain migration/denied access, and Settings Save/Cancel/close.

---

## 📂 Project Structure

```
whisper-me/
├── AppDelegate.swift           # Menu bar item, lifecycle, recording workflow
├── AudioRecorder.swift         # AVFoundation microphone recording (WAV)
├── GeminiTranscriber.swift     # Google Gemini batch STT client
├── HotKeyManager.swift         # Carbon global hotkey registration
├── LiveDebug.swift             # CLI diagnostic tool for audio and Live API
├── Log.swift                   # File & console logging
├── Logic.swift                 # Pure business logic, KeyCombo model, API payloads, AppLanguage
├── OpenRouterTranscriber.swift # OpenRouter STT client and model catalog
├── SettingsManager.swift       # UserDefaults, L10n utility, and .env configuration
├── SettingsWindow.swift        # AppKit Settings GUI and ShortcutRecorderControl
├── StreamingTranscriber.swift  # Gemini Live bidirectional WebSocket client
├── TextInjector.swift          # CGEvent simulated keyboard paste / injection
├── TranscriptionService.swift  # Provider abstraction protocol
├── main.swift                  # App entry point (NSApplication.shared)
├── build.sh                    # Build script (swiftc + lipo for Universal App)
├── tests/
│   ├── Tests.swift             # Unit test suite
│   └── run.sh                  # Test execution script
└── .github/workflows/
    └── build-and-release.yml   # GitHub Actions CI for tests & releases
```

---

## 📄 License

MIT
