<p align="center">
  <img src="icon.svg" width="96" height="96" alt="Speak11 icon">
</p>

<h1 align="center">Speak11</h1>

<p align="center">
  Select text in any app, press <kbd>⌥</kbd><kbd>⇧</kbd><kbd>/</kbd>, hear it read aloud.<br>
  Cloud TTS via <a href="https://elevenlabs.io">ElevenLabs</a>, or local TTS via <a href="https://github.com/Blaizzy/mlx-audio">Kokoro</a> (Apple Silicon).<br>
  Runs in your menu bar.
</p>

<p align="center">
  <a href="https://unlicense.org"><img src="https://img.shields.io/badge/license-Unlicense-green" alt="License: Unlicense"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey" alt="macOS 13+">
</p>

---

## Requirements

- macOS Ventura (13) or later
- **Cloud TTS:** a free [ElevenLabs account](https://elevenlabs.io) and API key
- **Local TTS:** Apple Silicon (M1 or later) — Python is downloaded automatically if needed

## Installation

1. [Download the latest release](../../releases/latest/download/speak11.zip) and unzip it
2. Double-click **`install.command`**
3. Click **Continue**, then choose your backend: **ElevenLabs Only**, **Both** (recommended), or **Local Only** (Apple Silicon only)
4. Paste your API key if prompted
5. Click **Install** when prompted about the settings app — this adds the menu bar icon and registers `⌥⇧/` as a global hotkey

Choosing **Both** or **Local Only** on Apple Silicon installs mlx-audio + Kokoro for free offline TTS.

> **Getting your API key:** sign in at [elevenlabs.io](https://elevenlabs.io) → click your profile icon → **Profile + API Key** → create or copy a key. The key needs the **Text-to-Speech** and **User Read** permissions enabled (User Read lets the menu bar show your remaining credits).

> **Local TTS note:** if no Python 3.10+ is found on your system, a standalone Python (~17 MB) is downloaded automatically. The Kokoro voice model (~350 MB) is also downloaded during installation.

### First use

Once installed, the **waveform icon** appears in your menu bar. On first launch the app will ask for Accessibility permission — click **Allow** so it can register the global hotkey.

- **Select any text** in any app → press `⌥⇧/` → audio plays
- **Press `⌥⇧/` again** while audio is playing → stops immediately

The waveform icon pulses while audio is being generated and played, so you always know it's working.

Text copied from PDFs, LaTeX documents, and Markdown files is automatically cleaned up before reading -- math equations, SI units, Greek letters, citations, and formatting artifacts are converted to natural spoken language.

Your API key is stored in your macOS Keychain — never written to a file.

## Settings

Click the **waveform icon** in the menu bar. The menu adapts to your setup — you only see settings that apply. Use the **Backend** submenu to switch between **Auto** (cloud + local fallback), **ElevenLabs** (cloud only), and **Local** (offline only).

### ElevenLabs settings

| Setting | Options |
|---------|---------|
| **Voice** | Popular presets or a custom voice ID |
| **Model** | v3 · Flash v2.5 · Turbo v2.5 · Multilingual v2 |
| **Speed** | 0.7× to 1.2× |
| **Stability** | 0.0 (expressive) to 1.0 (steady) — controls pitch and pacing variation |
| **Similarity** | 0.0 (low) to 1.0 (high) — how closely output matches the original voice |
| **Style** | 0.0 (none) to 1.0 (max) — amplifies the voice's characteristic delivery; adds latency |
| **Speaker Boost** | On / Off — subtle enhancement to voice similarity |

### Local (Kokoro) settings

| Setting | Options |
|---------|---------|
| **Voice** | 12 curated English voices (American and British) |
| **Speed** | 0.5× to 2× |

### Playback settings

| Setting | Options |
|---------|---------|
| **Sentence Pause** | Milliseconds of silence between sentences (default 400ms). Scales inversely with speed -- at 2× speed, a 400ms pause becomes 200ms. Click the menu item and type any value; set to 0 for no pause. |

Settings take effect immediately — no restart needed.

### ElevenLabs voices

| Name | Style |
|------|-------|
| Lily | British, raspy |
| Alice | British, confident |
| Rachel | Calm |
| Adam | Deep |
| Domi | Strong |
| Josh | Young, deep |
| Sam | Raspy |

You can also enter any voice ID from the [ElevenLabs Voice Library](https://elevenlabs.io/voice-library) via **Voice → Custom voice ID…** in the menu.

### Kokoro voices

| Name | Style |
|------|-------|
| Lily | British, bright (default) |
| Heart | Warm |
| Bella | Soft |
| Nova | Confident |
| Sarah | Gentle |
| Sky | Bright |
| Adam | Deep |
| Echo | Clear |
| Eric | Steady |
| Michael | Warm |
| Emma | British, warm |
| George | British, deep |

## Uninstall

Double-click **`uninstall.command`** — it removes everything including the Accessibility permission, login item, API key, and app bundle.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `⌥⇧/` does nothing | Grant Accessibility permission when prompted, or check System Settings → Privacy & Security → Accessibility |
| Waveform icon not in menu bar | Open `~/Applications/Speak11.app` manually, or re-run `install.command` |
| HTTP 401 | API key is wrong or expired — run `install.command` again |
| HTTP 429 | Monthly character quota exceeded — if both backends are installed, the app automatically falls back to local TTS. On Apple Silicon with ElevenLabs only, it will offer to install local TTS as a free alternative |
| "python3 not found" | Run `xcode-select --install` in Terminal |
| Settings app fails to compile | Check `~/.local/share/speak11/install.log` for the error. Usually fixed by updating Command Line Tools: `sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install` |
| Local TTS is slow | Check `~/.local/share/speak11/tts.log` for errors. The TTS daemon keeps the model loaded and warmed up in memory so requests are near-instant |
| Audio playback issues | Set `SPEAK11_NO_QUEUE_PLAYER=1` to fall back to afplay (slower but simpler). If that fixes it, the issue is with the audio queue player — re-run `install.command` to rebuild it |

## Cost

**ElevenLabs:** the free tier includes a monthly character allowance — usually sufficient for casual read-aloud use. Paid plans start at $5/month. See [elevenlabs.io/pricing](https://elevenlabs.io/pricing).

**Local (Kokoro):** completely free. Runs on your Mac with no API calls or credits. Requires Apple Silicon and a one-time ~350 MB model download.

## License

[Unlicense](LICENSE) — public domain. Created by [Stefano Martiniani](https://github.com/smcantab).

---

<details>
<summary><strong>Advanced</strong></summary>

### Config file

Settings are saved to `~/.config/speak11/config`. You can edit this file directly:

```bash
TTS_BACKEND="auto"
TTS_BACKENDS_INSTALLED="both"
VOICE_ID="pFZP5JQG7iQjIQuC4Bku"
MODEL_ID="eleven_flash_v2_5"
STABILITY="0.50"
SIMILARITY_BOOST="0.75"
STYLE="0.00"
USE_SPEAKER_BOOST="true"
SPEED="1.00"
LOCAL_VOICE="bf_lily"
LOCAL_SPEED="1.00"
SENTENCE_PAUSE="400"
```

### Environment variables

Environment variables take highest priority and override both the config file and the settings app:

```bash
export ELEVENLABS_API_KEY="your-api-key"       # overrides Keychain
export ELEVENLABS_VOICE_ID="your-voice-id"
export ELEVENLABS_MODEL_ID="eleven_multilingual_v2"
export TTS_BACKEND="local"                     # "auto" (default), "elevenlabs", or "local"
export SPEED="1.10"                            # ElevenLabs speed (0.7 to 1.2)
export STABILITY="0.50"                        # 0.0 (expressive) to 1.0 (steady)
export SIMILARITY_BOOST="0.75"                 # 0.0 to 1.0
export STYLE="0.00"                            # 0.0 to 1.0 (adds latency)
export USE_SPEAKER_BOOST="true"                # "true" or "false"
export LOCAL_VOICE="am_adam"                   # Kokoro voice ID
export LOCAL_SPEED="1.25"                      # 0.5 to 2.0
export SENTENCE_PAUSE="400"                    # inter-sentence pause (ms at 1× speed, default 400)
export SPEAK11_IDLE_TIMEOUT="600"              # daemon idle shutdown (seconds, default 300)
```

Debug variables (not needed for normal use):

```bash
export SPEAK11_TRACE=1                         # print timing trace to stderr
export SPEAK11_NO_QUEUE_PLAYER=1               # fall back to afplay (one process per sentence)
export VENV_PYTHON="/path/to/python3"          # override the default venv Python
```

### Voice IDs

| Name | ID |
|------|----|
| Lily | `pFZP5JQG7iQjIQuC4Bku` |
| Alice | `Xb7hH8MSUJpSbSDYk0k2` |
| Rachel | `21m00Tcm4TlvDq8ikWAM` |
| Adam | `pNInz6obpgDQGcFmaJgB` |
| Domi | `AZnzlk1XvdvUeBnXmlld` |
| Josh | `TxGEqnHWrfWFTfGW9XjX` |
| Sam | `yoZ06aMxZJJ28mfd3POQ` |

### Accessibility permission

The global hotkey requires Accessibility access. The app prompts for this on first launch, but if you need to grant it manually:

**System Settings → Privacy & Security → Accessibility** → enable **Speak11**

The hotkey activates automatically once access is granted.

### Electron apps (Beeper, Slack, VS Code, etc.)

Electron apps intercept keyboard shortcuts before macOS Services sees them. The settings app solves this by registering `⌥⇧/` as a **global hotkey** via CoreGraphics — it works at the system level and cannot be blocked by any app.

The settings app simulates `⌘C` via CGEvent to copy the current selection before calling the TTS script, so the hotkey works everywhere — including apps that don't support macOS Services.

### Optional: Services shortcut

The installer also creates a macOS Services action you can bind to any shortcut. This is optional — `⌥⇧/` already works everywhere — but useful if you prefer a different key combination.

1. System Settings → **Keyboard → Keyboard Shortcuts → Services → Text**
2. Find **Speak Selection** and assign a shortcut — e.g. `⌃⌥S`

> **Speak Selection** not in the list? Log out and back in, or trigger via right-click → **Services**.

### TTS daemon

Local TTS uses a persistent daemon (`tts_server.py`) that keeps the Kokoro model loaded in memory. When the menu bar app is running, it manages the daemon directly -- the daemon stays alive as long as the app is open. If you run `speak.sh` from the terminal without the app, the daemon starts on first request and shuts down after 5 minutes of inactivity.

Logs are written to `~/.local/share/speak11/tts.log`. Installer errors (pip, swiftc) go to `~/.local/share/speak11/install.log`.

### Updating

Re-run `install.command` to update the scripts and app to the latest version.

To update your API key, run `install.command` again — or update it directly:

```bash
security add-generic-password \
  -a "speak11" \
  -s "speak11-api-key" \
  -w "your-new-key" \
  -U
```

</details>
