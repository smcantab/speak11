# Speak11 — Developer Documentation

> Select text in any macOS app, press `⌥⇧/`, hear it read aloud.
> Cloud TTS via **ElevenLabs**, or local/offline TTS via **Kokoro** (Apple Silicon).

This document explains how Speak11 works internally: its architecture, the
runtime data flow, every major component, the build/install process, and the
concurrency and reliability invariants that hold the whole thing together.

For the *why* behind specific design decisions, see [`PRINCIPLES.md`](PRINCIPLES.md).
For end-user instructions, see [`README.md`](README.md).

---

## Table of contents

1. [What Speak11 is](#1-what-speak11-is)
2. [Component map](#2-component-map)
3. [The end-to-end runtime flow](#3-the-end-to-end-runtime-flow)
4. [The menu bar app — `Speak11.swift`](#4-the-menu-bar-app--speak11swift)
5. [The orchestrator — `speak.sh`](#5-the-orchestrator--speaksh)
6. [The text normalizer — `normalize.py`](#6-the-text-normalizer--normalizepy)
7. [The TTS daemon — `tts_server.py`](#7-the-tts-daemon--tts_serverpy)
8. [The audio utility — `speak11-audio.swift`](#8-the-audio-utility--speak11-audioswift)
9. [Installation & build — `install.command` / `install-local.sh`](#9-installation--build)
10. [Configuration & file locations](#10-configuration--file-locations)
11. [Concurrency, signals & state machines](#11-concurrency-signals--state-machines)
12. [Testing & profiling](#12-testing--profiling)
13. [Release process — `release.sh`](#13-release-process--releasesh)
14. [Key invariants & gotchas](#14-key-invariants--gotchas)

---

## 1. What Speak11 is

Speak11 is **not** a single binary. It is a small constellation of cooperating
processes glued together by a bash orchestrator. The design splits cleanly into
three concerns:

| Concern | Implemented in | Language |
|---|---|---|
| **UI / hotkey / settings** | `Speak11.swift` → `~/Applications/Speak11.app` | Swift (Cocoa) |
| **Orchestration / TTS pipeline** | `speak.sh` | bash 3.2 |
| **Text cleanup** | `normalize.py` | Python |
| **Local TTS model serving** | `tts_server.py` | Python (mlx-audio) |
| **Gapless playback + mute check** | `speak11-audio.swift` → `speak11-audio` | Swift (AVFoundation/CoreAudio) |

Everything is compiled and assembled **on the user's machine at install time** —
there is no pre-built app bundle shipped. The release artifact is just a zip of
the source files; `install.command` does the rest (see [§9](#9-installation--build)).

There are **three TTS backends** the user can choose between:

- `elevenlabs` — cloud API, requires an API key, billed per character.
- `local` — Kokoro model via mlx-audio, free, Apple-Silicon only.
- `auto` — try ElevenLabs first, silently fall back to local on quota/network failure.

---

## 2. Component map

```
                          ┌──────────────────────────────────────┐
   ⌥⇧/  (global hotkey)   │     Speak11.app  (Speak11.swift)      │
 ───────────────────────► │  • CGEventTap captures ⌥⇧/           │
                          │  • Simulates ⌘C to copy selection     │
                          │  • Menu bar UI / settings / Keychain  │
                          │  • Manages TTS daemon (managed mode)   │
                          └───────────────┬──────────────────────┘
                                          │ spawns  /bin/bash speak.sh
                                          │ (stdin = optional text override)
                                          ▼
              ┌────────────────────────────────────────────────────────┐
              │                  speak.sh  (orchestrator)               │
              │                                                          │
              │  1. resolve config (env > config file > defaults)        │
              │  2. read clipboard (pbpaste) or stdin                    │
              │  3. iconv UTF-8 sanitize                                 │
              │  4. normalize ──────────────►  normalize.py (venv py)    │
              │  5. mute check ─────────────►  speak11-audio is-muted    │
              │  6. split into sentences ───►  pysbd (venv py)           │
              │  7. for each sentence:                                   │
              │       generate audio  ──┬──► curl → ElevenLabs API       │
              │                         └──► tts_server.py (Unix socket) │
              │       play audio  ──────────► speak11-audio play-queue   │
              └────────────────────────────────────────────────────────┘
                                          │ keeps model warm
                                          ▼
              ┌────────────────────────────────────────────────────────┐
              │            tts_server.py  (persistent daemon)           │
              │  • Kokoro model resident in memory + warmed pipeline    │
              │  • Unix socket  ~/.local/share/speak11/tts.sock         │
              │  • flock single-instance, idle/parent watchdog          │
              └────────────────────────────────────────────────────────┘
```

The orchestrator is the heart. The Swift app is mostly a *launcher + UI*; almost
all of the actual speaking logic lives in `speak.sh`. This is deliberate —
`speak.sh` can be run standalone from a terminal or bound to a macOS Services
shortcut, completely independent of the app.

---

## 3. The end-to-end runtime flow

This is what happens from keypress to sound, step by step.

### 3.1 Trigger

The user presses `⌥⇧/` (Option+Shift+forward-slash, keycode 44). The
`CGEventTap` installed by `Speak11.swift` (`hotkeyCallback`, `Speak11.swift:210`)
sees the keydown, matches the exact modifier set `[.maskAlternate, .maskShift]`,
**consumes** the event (returns `nil`), and dispatches `handleHotkey()` on a
background queue so the event tap never blocks.

> A CGEventTap works at the system level and cannot be intercepted by Electron
> apps (Slack, VS Code, Beeper) the way macOS Services can — this is why the
> global hotkey path exists in addition to the Services workflow.

### 3.2 Toggle vs. speak

`handleHotkey()` (`Speak11.swift:336`) checks `isSpeakingFlag`:

- **Already speaking** → call `stopSpeaking()` (kills the running `speak.sh` and its children). The same key both starts and stops.
- **Not speaking** → simulate `⌘C` via `CGEvent` (virtual key 8 with `.maskCommand`) to copy the current selection, sleep **200 ms** to let the clipboard settle, then `runSpeak()`.

### 3.3 Spawning the orchestrator

`runSpeak()` (`Speak11.swift:400`):

1. Does an **in-process mute check** via CoreAudio (`isOutputMuted()`); if muted, shows an "Unmute & Play" alert. It sets `SPEAK11_MUTE_CHECKED=1` in the child env so `speak.sh` skips its own (slower) mute check.
2. Bumps a **generation counter** and sets `isSpeakingFlag = true` (see [§11.3](#113-the-isspeakingflag-state-machine)).
3. Launches `/bin/bash ~/.local/bin/speak.sh` as a `Process`. If a text override was provided (used by *respeak*), it's piped in via stdin; otherwise stdin is `/dev/null` so `speak.sh` falls back to `pbpaste`.
4. Waits for the process to exit, then clears the flag — **but only if the generation still matches**, so a stale completion can't reset the icon for a newer request.

### 3.4 Inside `speak.sh`

1. **Config resolution** (`speak.sh:13-58`): save env vars, source `~/.config/speak11/config`, then apply priority `env var > config file > hardcoded default`. Numeric values are regex-validated.
2. **Auto-mode resolution** (`speak.sh:60-69`): if backend is `auto`, force `TTS_BACKENDS_INSTALLED=both`; if there's no API key, resolve straight to `local`.
3. **Toggle guard** (`speak.sh:71-94`): if a previous `speak.sh` PID is alive, kill it (children first, then the process, then `kill -9` if needed) and `exit 0`. This is the *terminal/Services* equivalent of the app's toggle.
4. **Read text** (`speak.sh:96-112`): from stdin if piped, else `pbpaste`. Empty → exit. Then `iconv -f UTF-8 -t UTF-8//IGNORE` strips invalid Unicode (unpaired surrogates from PDFs).
5. **Normalize** (`speak.sh:114-129`): pipe through `normalize.py` using the venv Python. Falls back to a `sed` one-liner (rejoin hyphenated line breaks) if Python is unavailable.
6. **Mute check** (`speak.sh:135-153`): skipped if `SPEAK11_MUTE_CHECKED=1`. Standalone, uses `speak11-audio is-muted` (≈35 ms) or `osascript` fallback.
7. **Write `TEXT_FILE`** (`speak.sh:156`): the normalized text is saved to `$TMPDIR/speak11_text` for *respeak* (position-aware resumption).
8. **Split into sentences** (`speak.sh:504`): `split_sentences()` uses `pysbd` (or a regex fallback that protects abbreviations). Output is TSV: `offset<TAB>length<TAB>sentence`.
9. **Start the audio queue player** (`speak.sh:511-522`): launches `speak11-audio play-queue` connected via two FIFOs (FD 7 = write paths, FD 8 = read duration/DONE). Falls back to per-sentence `afplay` if the tool is missing or `SPEAK11_NO_QUEUE_PLAYER=1`.
10. **The pipeline loop** (`speak.sh:532-588`): for each sentence, generate the *next* one while the current one plays (overlap). See [§3.5](#35-the-overlapping-pipeline).

### 3.5 The overlapping pipeline

The core trick that makes playback feel instant:

```
sentence 1:  [ generate ]                [ play ........ ]
sentence 2:               [ generate ]                   [ play ........ ]
sentence 3:                            [ generate ]                       [ play ... ]
                          └── overlap ──┘
```

Per iteration (`speak.sh:538-562` for local, `570-587` for cloud):

1. Generate the current sentence's audio (`run_local_tts` or `run_elevenlabs_tts`).
2. `wait_audio` — block until the *previously* queued sentence finishes playing.
3. Free the previous temp file.
4. `play_audio` — enqueue the new file. With the queue player this is near-instant: it writes a tab-separated line to FD 7 and reads back the clip duration from FD 8 (≈1 ms). The clip starts playing in the background while the loop generates the next sentence.

The first sentence gets a `0 ms` inter-sentence pause; subsequent ones use
`_PAUSE_MS`, computed as `SENTENCE_PAUSE / effective_speed` (`speak.sh:524-530`)
so a 400 ms pause becomes 200 ms at 2× speed.

### 3.6 Generation paths

**Local** (`run_local_tts`, `speak.sh:332-398`):
1. Try the existing daemon socket via `tts_daemon_request` (run in background so SIGTERM can interrupt the `wait`).
2. If that fails, `start_tts_daemon` and retry.
3. If the daemon is still unavailable, fall back to a **direct** cold invocation of `python -m mlx_audio.tts.generate` (slow, but reliable).

**Cloud** (`run_elevenlabs_tts`, `speak.sh:462-498`): POSTs a single sentence to
`/v1/text-to-speech/{voice}/stream` with `curl`, writing audio to a temp file and
the HTTP code to `${TMP_FILE}.code`. `curl` runs in the background so the `wait`
is signal-interruptible (bash 3.2 can't catch signals during a foreground `$()`).

### 3.7 Cloud error handling

If the **first** sentence fails, `speak.sh:591-647` handles it:
- **Network failure** (curl error / HTTP 000) → if both backends installed, fall back to local; else show a dialog.
- **HTTP 429** (quota) → fall back to local if installed; on Apple Silicon with ElevenLabs-only, *offer to install local TTS* inline via `install-local.sh`.
- **Other non-200** → show the (sanitized) API error message.

---

## 4. The menu bar app — `Speak11.swift`

A single-file Cocoa app (~1340 lines), compiled to `~/Applications/Speak11.app`.
It runs as an **accessory** (`LSUIElement` / `.accessory` activation policy) — no
Dock icon, just the menu bar waveform.

### Responsibilities

- **Global hotkey** via `CGEvent.tapCreate` (`installHotkey`, `Speak11.swift:360`). Requires Accessibility permission; polls for it with `startAccessibilityPolling` and auto-installs the tap once granted.
- **Menu bar UI** (`rebuildMenu`, `Speak11.swift:700`): the menu *adapts* to the active backend — ElevenLabs settings (voice/model/speed/stability/similarity/style/speaker-boost) show only when ElevenLabs is active; Kokoro settings (voice/speed) show only when local is active; both sections show with headers in `auto` mode. Re-read on every `menuWillOpen` so changes made by `speak.sh` (e.g. the 429 handler installing local TTS) appear.
- **Config model** (`Config` struct, `Speak11.swift:13-91`): load/save the `~/.config/speak11/config` file. Every settings change calls `config.save()` then `scheduleRespeak()`.
- **Speak process management** (`runSpeak`/`killCurrentProcess`, `Speak11.swift:400-491`): spawns/kills `speak.sh`, with the generation-counter state machine.
- **Respeak / live preview** (`calculateRemainingText`/`respeak`/`scheduleRespeak`, `Speak11.swift:560-659`): when a setting changes mid-playback, estimate the current position from `STATUS_FILE` (start epoch + duration + char offsets) and restart `speak.sh` from the nearest sentence boundary, debounced by 0.5 s.
- **TTS daemon lifecycle** (managed mode) (`Speak11.swift:493-550`): when local TTS is active, the app starts `tts_server.py --managed` and keeps it alive for the app's lifetime (no idle timeout). Stops it when the backend changes away from local or on app quit.
- **Keychain** (`readAPIKey`/`saveAPIKey`/`deleteAPIKey`, `Speak11.swift:663-696`): shells out to `/usr/bin/security`. The key is **never** written to a file.
- **Credits display** (`fetchCredits`, `Speak11.swift:1169`): calls `/v1/user/subscription`, caches for 60 s, shows "Credits: remaining / limit".
- **API-key validation** (`validateAPIKey`, `Speak11.swift:1218`): distinguishes 200 / 401 / 403 / network so the dialog can give a precise error.
- **Waveform animation** (`setSpeaking`/`waveformFrame`, `Speak11.swift:288-332`): draws 5 sine-driven bars at 10 fps while speaking.

### Backend-switch guided setup

`pickBackend` (`Speak11.swift:974`) is the most intricate UI path — switching to
`elevenlabs` requires a key, switching to `local` may trigger a background
`install-local.sh` run, and `auto` ensures at least one backend is usable,
degrading gracefully if the user skips both.

---

## 5. The orchestrator — `speak.sh`

The largest single piece of logic (~650 lines of **bash 3.2**-compatible shell —
the system bash on macOS). It is intentionally written to run standalone.

### Notable internal helpers

| Function | Lines | Purpose |
|---|---|---|
| `_validate_num` | 49 | Regex-guard numeric config values |
| `normalize_text` | 119 | Pipe text through `normalize.py`, sed fallback |
| `split_sentences` | 216 | pysbd-based sentence splitter, regex fallback, TSV output |
| `start_tts_daemon` | 260 | Launch daemon, wait for socket, handle flock conflict |
| `tts_daemon_request` | 292 | Send JSON over Unix socket via a python one-liner |
| `run_local_tts` | 332 | Daemon → retry → direct cold fallback |
| `play_audio` / `wait_audio` | 403 / 424 | Queue-player or afplay playback |
| `json_encode` | 436 | Pure-bash JSON string escaping (no fork) |
| `wav_duration` | 448 | WAV duration from file size, no `afinfo`/`bc` fork |
| `run_elevenlabs_tts` | 462 | Single-sentence cloud request via curl |

### Performance-driven design

`speak.sh` is full of micro-optimizations that exist because profiling
(`tests/profile.sh`) found real bottlenecks:

- **No O(n²) bash substitutions** — whitespace detection uses `[[ =~ ]]` regex instead of `${TEXT//[[:space:]]/}` (`speak.sh:102`).
- **Zero-fork epoch** — `_BASE_EPOCH` is computed once with perl, then incremented with `$SECONDS` arithmetic per sentence instead of forking perl each time (`speak.sh:404-405, 508-509`).
- **`json_encode` in pure bash** — avoids a Python fork per sentence.
- **`wav_duration` from `stat -f%z`** — Kokoro emits 24 kHz mono 16-bit WAV (48000 bytes/sec), so duration is just arithmetic — no `afinfo` fork.
- **Background curl/daemon + `wait`** — the only way to make a blocking generation interruptible by SIGTERM under bash 3.2.

### Cleanup discipline

A `trap cleanup EXIT` plus `INT`/`TERM` handlers (`speak.sh:201-205`) kill all
children (curl, python, afplay, the queue player), close FDs 7/8, and remove temp
files — but **only the PID file if it still belongs to this process** (a newer
instance may have overwritten it). `STATUS_FILE` and `TEXT_FILE` deliberately
*persist* across runs so the app can compute respeak position.

---

## 6. The text normalizer — `normalize.py`

A ~1220-line, dependency-light Python preprocessor that turns messy
copy-pasted text (PDFs, LaTeX, Markdown) into clean, *speakable* prose. It reads
stdin, writes stdout, and logs the detected front-end to stderr.

### Architecture: front-end → shared back-end

```
stdin ──► source detection ──► front-end (format-specific) ──► back-end (shared) ──► stdout
              │
              ├─ _is_latex()    (score-based, negative signals for PDF/Markdown)
              ├─ _is_markdown()  (score-based)
              └─ else → PDF
```

The **front-end** knows the source format and converts it to clean prose. The
**back-end never knows the source** — it applies universal normalization.

### Front-ends

- **PDF** (`_frontend_pdf`, line 804): `ftfy` mojibake repair, ligature expansion (ﬁ→fi), rejoin mid-word hyphenated line breaks (preserving genuine compound hyphens via `_COMPOUND_PREFIXES`), strip superscript citations, scientific/isotope/exponent notation, bullet/list markers.
- **LaTeX** (`_frontend_latex`, line 480, phases L1–L6): strip preamble/comments, expand custom `\newcommand`/`\def` macros (with an optional cache at `~/.config/speak11/latex_macros.tex`), handle environments (equation/align/matrix/cases/theorem/figure/table/itemize), convert math to spoken English via `_math_to_speech`, then `pylatexenc` for accents.
- **Markdown** (`_frontend_markdown`, line 134, phases M1–M10): strip YAML front-matter and Obsidian comments, code blocks → "Code block omitted", headings → "Title/Section/Subsection:", links/wikilinks/images, bold/italic/strikethrough/inline-code, footnotes/tags, math (`$...$`), tables/callouts/blockquotes/lists, HTML tags.

### `_math_to_speech` (line 305)

The workhorse for LaTeX/Markdown math: fractions → "a over b", `\sqrt` → "square
root of", integrals/sums/limits with bounds, superscripts → "squared"/"cubed"/"to
the n", subscripts → "sub n", Greek letters, ~80 math symbols, matrices, function
application `f(x)` → "f of x".

### Shared back-end (phases 0, A, B, C, D)

| Phase | Function | Does |
|---|---|---|
| 0 | `_phase0` (891) | Typographic normalization (smart quotes, minus sign, ellipsis, exotic whitespace) |
| A | `_phaseA` (902) | Noise removal: chemical formulas → names, **bare URLs verbalized** ("go dot nature dot com slash..."), DOIs, citation references |
| B | `_phaseB` (936) | Punctuation, abbreviations (`e.g.`→"for example"), Miller indices, currency (`$1.5M`→"1.5 million dollars"), numeric ranges, math operators, percentages |
| C | `_phaseC` (1050) | Scientific symbols (±, ×, ∞), SI units (`kg/m³`, `kPa`, `°C`), micro prefix, Greek via `unicodedata`, Roman numerals |
| D | `_phaseD` (1183) | Final whitespace/punctuation cleanup |

The bare-URL verbalization (Phase A) is specifically for **local** TTS — Kokoro
otherwise reads dots and slashes incorrectly.

Required deps: `ftfy` (mandatory). Optional: `pylatexenc` (LaTeX accents),
`pysbd` (used by `speak.sh` for sentence splitting, not by `normalize.py` itself).

---

## 7. The TTS daemon — `tts_server.py`

A persistent Python process that keeps the Kokoro model resident in memory and
serves generation requests over a Unix domain socket — this is what makes local
TTS feel near-instant instead of paying a 5–30 s model load on every request.

### Two modes

- **Default (on-demand)**: started by `speak.sh` when needed. Auto-shuts down after `SPEAK11_IDLE_TIMEOUT` (default 300 s) of inactivity via `idle_watchdog`.
- **`--managed`**: started by `Speak11.app`. No idle timeout; instead a `parent_watchdog` shuts it down if the parent app dies (detects reparenting to PID 1).

### Lifecycle (`main`, line 288)

1. Acquire an exclusive `flock` on `tts_server.lock` (line 298–303) — **single-instance guarantee**. A second daemon exits cleanly with code 0; `speak.sh` then waits for the first daemon's socket.
2. Write PID file, clean stale socket and orphaned temp dirs.
3. Install SIGTERM/SIGINT handlers.
4. `load_tts_model()` (Kokoro-82M-bf16), then `warmup_pipeline()` (a one-char generation that pre-initializes the phonemizer/espeak-ng pipeline, saving ~400 ms on the first real request).
5. Bind the socket — **its appearance is the readiness signal** `speak.sh` polls for.
6. Accept loop: each client handled in a **thread** so a new request can cancel a long-running one.

### Request protocol

JSON line in: `{"text":..,"voice":..,"speed":..,"lang_code":..}` →
JSON line out: `{"status":"ok","audio_file":"/tmp/speak11_tts_*/speak11.wav"}`.

### Cancellation & memory

- A `generation_lock` serializes generation (one at a time).
- `cancel_check` peeks the socket (`_client_gone`, line 146) — if the client disconnected (the hotkey toggle killed the old `speak.sh`), generation aborts early with `CancelledError`.
- After each response, `gc.collect()` + `mx.metal.clear_cache()` free MLX Metal buffers — done *after* sending, not between sentences, so back-to-back requests stay fast.

---

## 8. The audio utility — `speak11-audio.swift`

A tiny Swift CLI (compiled to `~/.local/bin/speak11-audio`) with three commands:

- `is-muted` — exit 0 if the default output device is muted, 1 otherwise (CoreAudio, microseconds — replaces the slow `osascript` mute check).
- `unmute` — clear the mute flag.
- `play-queue` — the **gapless audio queue player**.

### The queue player (`QueuePlayer`, line 72)

Reads tab-separated lines from stdin
(`filepath\tepoch\toffset\tsent_len\tstatus_file\tpause_ms`), creates an
`AVAudioPlayer` per clip, and plays them back-to-back:

- On enqueue, it `prepareToPlay()`s and **immediately prints the clip duration** to stdout so `speak.sh` can start generating the next sentence.
- `audioPlayerDidFinishPlaying` prints `DONE` (which unblocks `speak.sh`'s `wait_audio`) and starts the next clip — optionally after a `pauseMs` delay (the configurable inter-sentence pause).
- Before each clip starts, it writes the `STATUS_FILE` (epoch / duration / offset / sentLen) used by the app's respeak position estimate.

This replaced the old per-sentence `afplay` approach, cutting the inter-sentence
gap from **~970 ms to ~30 ms** (the gap is now just hardware latency plus the
intentional pause).

---

## 9. Installation & build

There is **no shipped binary**. The release zip contains source; the user runs
`install.command` (double-clickable; `.command` opens in Terminal).

### `install.command` (~714 lines) — what it does

1. **Strip quarantine** (`xattr -dr com.apple.quarantine`) so `swiftc` can read the sources.
2. **Single-instance lock** at `/tmp/speak11_install.lock`.
3. **Welcome + backend choice** dialogs (osascript). On Apple Silicon: ElevenLabs Only / Both / Local Only.
4. **API key prompt + validation** (loops until valid or skipped). Stored in Keychain.
5. **Command Line Tools check** — ensures CLT major version matches the macOS major; updates via `softwareupdate` (admin prompt) if needed, because `swiftc` is required to build the app.
6. **`xcrun swiftc` reachability** — resets `xcode-select` to the CLT path if Xcode is missing.
7. **mlx-audio install** (Both/Local Only) → delegates to `install-local.sh`.
8. **ftfy/pylatexenc venv** — if local TTS wasn't installed, still create a lightweight venv with just the normalizer deps.
9. **Copy scripts** to `~/.local/bin/` (`speak.sh`, `normalize.py`, `tts_server.py`, `install-local.sh`, `uninstall.command`) and **compile** `speak11-audio`.
10. **Create the Automator "Speak Selection" Quick Action** (inline plist/wflow) for the optional Services shortcut.
11. **Write config** (`~/.config/speak11/config`) — backend fields set from the choice; on re-install, existing user settings are preserved.
12. **Build the app** (if chosen): `xcrun swiftc Speak11.swift -O`, write `Info.plist`, **generate the `.icns` icon** (an inline Swift script draws a rounded-rect + SF Symbol `waveform`, rasterized at 10 sizes → `iconutil`), ad-hoc **codesign**, offer a **login item**, and `open` the app.

Errors are logged to `~/.local/share/speak11/install.log`.

### `install-local.sh` (~194 lines) — the local-TTS bootstrapper

Called by `install.command`, by `speak.sh` (on 429), and by the app
(backend switch). Idempotent.

1. Apple Silicon guard.
2. `find_python` — search common locations for Python ≥3.10.
3. If none, `download_python` — fetch a **standalone CPython 3.12** from python-build-standalone (~17 MB), **SHA256-verified**, extracted to `~/.local/share/speak11/python`.
4. Create venv at `~/.local/share/speak11/venv`, `pip install mlx-audio` + deps (`misaki==0.8.4`, `phonemizer-fork`, `pysbd`, `ftfy`, `pylatexenc`, etc.).
5. Pre-download the Kokoro model (`mlx-community/Kokoro-82M-bf16`, ~350 MB) via `huggingface_hub` so first use is offline-ready.
6. Update config to mark `TTS_BACKENDS_INSTALLED="both"` (skipped for dev/test venvs).

### `uninstall.command`

Removes everything: kills the app + daemon, `tccutil reset Accessibility`,
deletes the app bundle, scripts, Services workflow, config dir, the entire
`~/.local/share/speak11` (venv + standalone Python + model cache), the Keychain
key, and the login item.

---

## 10. Configuration & file locations

### Config file — `~/.config/speak11/config`

Shell-sourceable `KEY="value"` lines. Written by the app's `Config.save()` and by
the installers; read by both the app and `speak.sh`.

```bash
TTS_BACKEND="auto"               # auto | elevenlabs | local
TTS_BACKENDS_INSTALLED="both"    # elevenlabs | local | both
VOICE_ID="pFZP5JQG7iQjIQuC4Bku"  # ElevenLabs voice
MODEL_ID="eleven_flash_v2_5"
STABILITY="0.50"; SIMILARITY_BOOST="0.75"; STYLE="0.00"; USE_SPEAKER_BOOST="true"
SPEED="1.00"                     # ElevenLabs speed (0.7–1.2)
LOCAL_VOICE="bf_lily"            # Kokoro voice; first char = lang_code
LOCAL_SPEED="1.00"               # Kokoro speed (0.5–2.0)
SENTENCE_PAUSE="400"             # ms at 1× speed
```

**Priority: environment variable > config file > hardcoded default** — enforced
both in `Config.load()` (Swift) and at the top of `speak.sh`.

> **Voice → lang_code derivation:** Kokoro's `lang_code` is just the first
> character of the voice ID (`${LOCAL_VOICE:0:1}` — `b`=British, `a`=American), so
> there's no separate language setting.

### Filesystem layout

| Path | Contents |
|---|---|
| `~/Applications/Speak11.app` | Compiled menu bar app |
| `~/.local/bin/speak.sh` | Orchestrator |
| `~/.local/bin/normalize.py`, `tts_server.py` | Python components |
| `~/.local/bin/speak11-audio` | Compiled audio CLI |
| `~/.local/bin/install-local.sh`, `uninstall.command` | Maintenance scripts |
| `~/.config/speak11/config` | Settings |
| `~/.config/speak11/latex_macros.tex` | Optional LaTeX macro cache |
| `~/.local/share/speak11/venv` | Python venv (mlx-audio + deps) |
| `~/.local/share/speak11/python` | Standalone CPython (if downloaded) |
| `~/.local/share/speak11/tts.sock` | Daemon Unix socket |
| `~/.local/share/speak11/tts_server.{pid,lock}` | Daemon single-instance files |
| `~/.local/share/speak11/tts.log`, `install.log` | Logs |
| `$TMPDIR/speak11_tts.pid` | Running `speak.sh` PID (toggle) |
| `$TMPDIR/speak11_text`, `speak11_status` | Respeak text + playback position |
| `$TMPDIR/speak11_tts_*` | Per-sentence audio temp dirs |
| `~/Library/Services/Speak Selection.workflow` | Optional Services action |

### Environment variables

Beyond the config-mirroring vars, debug/override knobs:
`SPEAK11_TRACE=1` (timing trace to stderr), `SPEAK11_NO_QUEUE_PLAYER=1` (afplay
fallback), `SPEAK11_MUTE_CHECKED=1` (skip mute check — set by the app),
`SPEAK11_IDLE_TIMEOUT` (daemon idle seconds), `VENV_PYTHON` (override venv python),
`TTS_SOCK` (override socket path — used to isolate tests).

---

## 11. Concurrency, signals & state machines

### 11.1 The PID-file toggle

`$TMPDIR/speak11_tts.pid` holds the running `speak.sh`'s PID. A second invocation
sees a live PID and kills it (children first so bash 3.2 can process SIGTERM —
it defers signals while a foreground child runs), then exits. The PID file is
only removed if it still belongs to the process being killed, to avoid clobbering
a newer instance that started during the kill wait.

### 11.2 Interruptible waits

Bash 3.2 cannot run trap handlers while a foreground `$(...)` command
substitution is executing. So every long-running operation (`curl`, daemon
request, direct mlx generate) is launched **in the background** and awaited with
`wait "$pid"`, which *is* interruptible. This is why you see the `_CURL_PID` /
`_DAEMON_PID` background pattern throughout `speak.sh`.

### 11.3 The `isSpeakingFlag` state machine

In `Speak11.swift`, guarded by `speakLock`:

- States: idle (`isSpeakingFlag=false`) ↔ speaking (`true`).
- A **generation counter** (`speakGeneration`) is bumped on every `runSpeak` and `killCurrentProcess`. When a `speak.sh` process exits, it only flips the flag/icon back to idle **if its generation is still current**. This prevents a slow, just-killed process from resetting state that a newer request owns — the root cause class of "stuck waveform" / "two voices at once" bugs.

### 11.4 Daemon thread safety

`tts_server.py` accepts each connection on its own thread but serializes actual
generation with `generation_lock`. The cancel-check lets a newer request abort an
in-flight older one. The `flock` guarantees at most one daemon process system-wide.

---

## 12. Testing & profiling

### `tests/test.sh` (~6600 lines, 1000+ assertions)

```bash
bash tests/test.sh                 # everything (includes Swift compile)
bash tests/test.sh --fast          # skip the slow Swift compile test
bash tests/test.sh "normalize"     # only sections matching a filter
bash tests/test.sh --list          # list section names
```

It bootstraps a **repo-local dev venv** at `tests/.venv` (gitignored) by running
`install-local.sh`, falling back to a lightweight ftfy/pylatexenc venv if a full
install isn't possible (not ARM64 / offline). The dep hash is stamped so it only
re-bootstraps when the installers change. Tests are isolated from any real daemon
via `TTS_SOCK=/tmp/...nosock`.

Coverage spans ~90 sections: config priority, PID toggle logic, backend routing,
429/network fallback, the `isSpeakingFlag` state machine, daemon
robustness/cancellation/locking, sentence-splitting quality, **simulations** of
the full pipeline with fake `curl`/`afplay`/TTS, regression tests for past bugs
(combined trap bug, O(n²) substitution, STATUS_FILE offsets), and extensive
`normalize.py` PDF/LaTeX/Markdown cases.

The testing philosophy (see `PRINCIPLES.md`) is to test behavior through the real
scripts with stubbed externals, not to mock internals.

### `tests/profile.sh`

Runs `speak.sh` under `bash -x` with a high-resolution `PS4` timestamp on every
traced line, then extracts phase boundaries (text read → iconv → mute → split →
first generation → first audio) and per-sentence generation times. `--components`
runs micro-benchmarks (bash `json_encode` vs `python json.dumps`, `wav_duration`
vs `afinfo`, `nc -U` vs python socket). Playback is stubbed so it measures
generation latency, not audio duration. This profiler is what surfaced the
optimizations listed in [§5](#5-the-orchestrator--speaksh).

---

## 13. Release process — `release.sh`

```bash
bash release.sh 1.1.0
```

The **CHANGELOG.md is the single source of truth** for release notes. The script:
1. `awk`-extracts the `## v1.1.0` section from `CHANGELOG.md`.
2. Appends a standard GitHub footer.
3. `git archive`s HEAD into two zips: `speak11-v1.1.0.zip` (versioned, for the
   release page) and `speak11.zip` (stable name, so
   `releases/latest/download/speak11.zip` keeps working).
4. Creates a **draft** release via `gh` (or updates an existing one, replacing assets).

Publish manually: `gh release edit v1.1.0 --draft=false`.

The website lives in `docs/` (GitHub Pages, custom domain `speakeleven.com` via
`docs/CNAME`).

---

## 14. Key invariants & gotchas

These are the non-obvious rules that keep the system correct. Violating them
re-introduces classes of bugs the test suite guards against.

1. **bash 3.2 only.** macOS ships bash 3.2. No associative arrays for hot paths, no `${var//pat/}` on large strings (O(n²)), no signal handling during foreground `$()`. Always background-and-`wait`.

2. **Kill children before the parent.** bash defers SIGTERM while a foreground child runs, so `pkill -P <pid>` then `kill <pid>` — both in `speak.sh`'s toggle and the app's `killCurrentProcess`.

3. **The generation counter is law.** Any code that flips `isSpeakingFlag` or the menu-bar icon must check that its generation is still current first.

4. **STATUS_FILE / TEXT_FILE persist on purpose.** `cleanup` does *not* remove them — the app needs them to compute respeak position after a process exits.

5. **The PID file is only yours if it still says your PID.** Always re-check before removing it; a newer instance may have overwritten it during your kill-wait.

6. **The socket file is the daemon readiness signal.** `speak.sh` polls for `tts.sock` to appear, not for a log line. A flock conflict (second daemon) is *expected* and handled by waiting for the first daemon's socket.

7. **Minimize forks in per-sentence hot paths.** Epoch is cached; JSON encoding and WAV duration are pure bash. Re-adding a `perl`/`python`/`bc` fork per sentence is a regression.

8. **The normalizer back-end must stay source-agnostic.** Front-ends own all format knowledge; phases 0/A/B/C/D must work identically regardless of whether the input was PDF, LaTeX, or Markdown.

9. **The API key never touches disk.** It lives only in the macOS Keychain (`security` CLI). Don't write it to the config file or logs.

10. **Everything is built on the user's machine.** Changes to `Speak11.swift` or `speak11-audio.swift` only take effect after re-running `install.command` (which recompiles). The release zip ships source, not binaries.

---

*Generated as a developer reference. When in doubt, the source files referenced
throughout are the authority; `PRINCIPLES.md` records the rationale behind these
decisions.*
