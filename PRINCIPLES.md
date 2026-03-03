# Speak11 -- Design Principles

This document defines the working principles that govern the implementation.
Every change must be consistent with these rules.


## Architecture

Speak11 has four components:

| Component | Language | Role |
|---|---|---|
| `speak.sh` | Bash | TTS orchestrator. Reads text, splits into sentences, generates audio, plays it. |
| `Speak11.swift` | Swift/AppKit | Menu bar app. Global hotkey, settings UI, config file, respeak. |
| `tts_server.py` | Python | Persistent Kokoro daemon. Keeps the model in memory for instant response. |
| `install.command` | Bash | Interactive installer. Dialogs, backend choice, Keychain, app compile. |

Data flows one way: **Swift -> speak.sh -> tts_server.py**.
The Swift app launches speak.sh as a subprocess. speak.sh connects to the daemon
over a Unix socket. There is no reverse communication except through shared files
(TEXT_FILE, STATUS_FILE, config).


## Backend model

Three modes: `elevenlabs`, `local`, `auto`.

- `elevenlabs` -- cloud API, requires an API key.
- `local` -- mlx-audio / Kokoro, requires Apple Silicon.
- `auto` -- tries ElevenLabs first (if API key exists), falls back to local silently.

`auto` resolves at runtime:
- If API key is present: use ElevenLabs. On 429 or network failure, fall back to local.
- If API key is absent: go straight to local (no error dialog).

The `TTS_BACKENDS_INSTALLED` config tracks what is available (`elevenlabs`, `local`,
or `both`). Silent fallback only happens when `both` is installed.


## Configuration priority

    environment variable > config file > hardcoded default

speak.sh saves env vars before sourcing the config to implement this:
```
_ENV_X="${X:-}"
source "$_CONFIG"
X="${_ENV_X:-${X:-default}}"
```

Swift writes the config file. speak.sh reads it. Both parse the same format:
`KEY="value"` lines, comments starting with `#`.


## Sentence-by-sentence pipeline

Text is split into sentences before generation. This is fundamental to how the
app works and serves two purposes:

1. **Credit savings (cloud):** Each ElevenLabs API call sends one sentence.
   Interrupting stops further API calls. Only played sentences are billed.

2. **Fast first audio (local):** Kokoro phonemization is slow on long text.
   Splitting lets the first sentence play while later ones generate.

### Split format

`split_sentences()` outputs one line per sentence:
```
offset<TAB>length<TAB>sentence text
```

- `offset` = character position in the original text (from `text.find(p, pos)`)
- `length` = `len(sentence)` (Python code points)
- Fallback (Python unavailable): `0<TAB>${#1}<TAB>$1` (whole text, single chunk)

### Pipeline overlap

The pipeline pre-generates the next sentence while the current one plays:

```
gen(1)  play(1)  gen(2)  wait(1)  play(2)  gen(3)  wait(2)  play(3)  wait(3)
        ^^^^^^^^^^^^^^^^                    ^^^^^^^^^^^^^^^^
        overlap: gen(2) runs during play(1)
```

- `play_audio` starts afplay in the background (non-blocking).
- `wait_audio` blocks until the current afplay finishes.
- The loop calls `wait_audio` before `play_audio` to ensure sequential playback.
- After the loop, a final `wait_audio` waits for the last sentence.

### Interruption invariant

On SIGTERM, at most `played + 1` generations have occurred (the one lookahead).
The remaining sentences are never sent to the API or to Kokoro.


## Signal handling

speak.sh uses three separate traps. This is mandatory for bash 3.2 correctness:

```bash
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
```

**Why separate traps:** Without `exit` in the INT/TERM handlers, bash runs the
trap handler but then resumes execution after the interrupted command. The script
keeps running instead of dying. `trap cleanup EXIT INT TERM` (combined form) has
this exact bug.

**Why cleanup is idempotent:** The EXIT trap always fires (including after INT/TERM
handlers call `exit`), so cleanup may run twice. All operations are safe to repeat:
kill on dead PIDs, rm on missing files.

### Interruptible waits

bash 3.2 defers signals during foreground command substitution (`$()`). To make
`wait` interruptible by SIGTERM:

- `curl` runs in the background with `&`, then `wait $PID`.
- Daemon requests run in the background with `&`, then `wait $PID`.
- Direct Kokoro fallback runs in the background with `&`, then `wait $PID`.

When SIGTERM arrives during `wait`, bash immediately runs the trap handler
(which calls `exit`), and the EXIT trap cleans up child processes.


## PID file toggle

speak.sh uses a PID file (`speak11_tts.pid`) for toggle behavior:

1. On start: check if PID file exists and process is alive.
2. If alive: **kill children first** (`pkill -P`), then kill parent, wait up to
   0.5s, force-kill if stuck, remove PID file, exit 0.
3. If stale: remove PID file, continue as new instance.
4. Write own PID to file.

**Children first:** bash 3.2 defers SIGTERM while a foreground child runs.
Killing children (afplay, curl, python3) first lets bash process the signal.

**Conditional PID file removal:** Both toggle and cleanup only remove the PID file
if it still contains their own PID. This prevents a race where a new instance
writes its PID while the old one is dying.


## Respeak (live settings preview)

When the user changes voice, speed, or model while audio is playing, the app
respeaks from roughly the current position.

### Data flow

1. speak.sh writes `TEXT_FILE` with the full original text.
2. `play_audio` writes `STATUS_FILE` with four lines:
   ```
   epoch_seconds
   audio_duration
   char_offset        (sentence start in original text)
   sentence_length    (character count of current sentence)
   ```
3. Swift reads both files to compute the resume position:
   ```
   ratio = elapsed / duration
   approxCharPos = charOffset + sentenceLen * ratio
   ```
4. Swift finds the nearest sentence boundary at or after `approxCharPos`.
5. Swift kills the current speak.sh, passes remaining text to a new one.

### Fallback

When `STATUS_FILE` has fewer than 4 lines (fallback paths that call `play_audio`
without offset args), Swift falls back to `text.count * ratio`. The `${1:-0}`
defaults in `play_audio` write `0` for offset and length; Swift's `sentenceLen > 0`
guard catches this and uses the old formula.

### Debounce

`scheduleRespeak()` uses a 0.5s timer. Rapid setting changes (e.g., clicking through
speed options) only trigger one respeak.


## TTS daemon (tts_server.py)

A persistent Python process that keeps the Kokoro model loaded in GPU memory.

### Lifecycle

- **On-demand mode** (default): speak.sh starts the daemon, which auto-shuts down
  after 5 minutes idle.
- **Managed mode** (`--managed`): the Swift app starts the daemon, which shuts down
  when its parent dies (orphan detection via `os.getppid()`).

### Single-instance guarantee

Uses `fcntl.flock` on a lock file. If a second daemon starts, it sees the lock,
exits 0, and the caller waits for the existing daemon's socket.

### Thread safety

- `generation_lock` (threading.Lock) serializes audio generation.
- Each client runs in a daemon thread.
- A new request that arrives while a generation is in progress will block on the lock
  until the previous generation finishes or is cancelled.

### Cancellation

When speak.sh is killed (toggle), its socket connection drops. The daemon detects
this via `select()` on the client socket between generation segments and raises
`CancelledError`, which aborts generation and cleans up temp files.

### Memory management

After each generation (success or failure):
1. `del segments, audio` -- release numpy arrays
2. `gc.collect()` -- collect Python garbage
3. `mx.metal.clear_cache()` -- release MLX metal buffers

Without this, GPU memory accumulates across generations until the system swaps.


## Cleanup discipline

### Temp files

- speak.sh creates temp files/dirs with prefix `speak11_tts_`.
- The pipeline tracks `_PREV_TMP_FILE` / `_PREV_TMP_DIR` and deletes after
  `wait_audio` (ensuring afplay has finished reading).
- `cleanup()` removes current and previous temp files.
- The daemon cleans up orphaned `speak11_tts_*` dirs on startup.

### STATUS_FILE persists

`cleanup()` does NOT remove STATUS_FILE. It persists for the Swift app to read
the last playback position for respeak. Stale data is benign (Swift checks the
epoch timestamp age).


## Error handling

### Cloud failures

| Condition | TTS_BACKENDS_INSTALLED=both | TTS_BACKENDS_INSTALLED=elevenlabs |
|---|---|---|
| First sentence, 429 | Silent fallback to local | Dialog: offer install-local |
| First sentence, network | Silent fallback to local | Dialog: check connection |
| First sentence, other HTTP | Error dialog with response body | Same |
| Mid-stream failure | Stop silently (partial playback OK) | Same |
| Fallback also fails | Error dialog | N/A |

### Local failures

| Condition | Action |
|---|---|
| First sentence fails | Error dialog: re-run installer |
| Mid-stream failure | Stop silently (already played something) |
| Daemon unavailable | Fallback to direct `mlx_audio` invocation (cold start, slow) |

### JSON encoding failure

If `python3 -c "import json..."` fails (python3 missing or crashes),
`run_elevenlabs_tts` returns 1 with `HTTP_CODE` unset. The error handler's
`[ -z "$HTTP_CODE" ]` catches this and routes to the network failure path.


## Config fields

All fields, their bash variable names, and defaults:

| Field | Bash var | Default | Notes |
|---|---|---|---|
| Backend | TTS_BACKEND | auto | auto, elevenlabs, local |
| Installed backends | TTS_BACKENDS_INSTALLED | elevenlabs | elevenlabs, local, both |
| ElevenLabs voice | VOICE_ID | pFZP5JQG7iQjIQuC4Bku | Lily |
| ElevenLabs model | MODEL_ID | eleven_flash_v2_5 | Flash v2.5 |
| ElevenLabs speed | SPEED | 1.0 | Range: 0.7-1.2 |
| Stability | STABILITY | 0.5 | |
| Similarity boost | SIMILARITY_BOOST | 0.75 | |
| Style | STYLE | 0.0 | |
| Speaker boost | USE_SPEAKER_BOOST | true | |
| Local voice | LOCAL_VOICE | bf_lily | Prefix determines lang_code |
| Local speed | LOCAL_SPEED | 1.0 | Range: 0.5-2.0 |

All three sources (speak.sh, Speak11.swift, install.command) must agree on defaults.

### Voice -> lang_code derivation

The first character of LOCAL_VOICE determines the language:
- `a` prefix (af_heart, am_adam) -> lang_code `a` (American English)
- `b` prefix (bf_lily, bm_george) -> lang_code `b` (British English)

This is passed via `${LOCAL_VOICE:0:1}` in bash.


## File locations

| Path | Purpose |
|---|---|
| `~/.config/speak11/config` | Config file (shared between Swift and bash) |
| `~/.local/bin/speak.sh` | Installed speak script |
| `~/.local/bin/tts_server.py` | Installed daemon |
| `~/.local/bin/install-local.sh` | Installed local TTS installer |
| `~/.local/share/speak11/venv/` | Python venv with mlx-audio |
| `~/.local/share/speak11/tts.sock` | Daemon Unix socket |
| `~/.local/share/speak11/tts_server.pid` | Daemon PID file |
| `~/.local/share/speak11/tts_server.lock` | Daemon flock file |
| `~/.local/share/speak11/tts.log` | Shared log file |
| `$TMPDIR/speak11_tts.pid` | speak.sh PID file |
| `$TMPDIR/speak11_text` | Full text for respeak |
| `$TMPDIR/speak11_status` | Playback position for respeak |
| `~/Applications/Speak11.app` | Compiled menu bar app |
| `~/Library/Services/Speak Selection.workflow` | Automator Quick Action |


## Testing

### Test philosophy

Tests are organized by concern, not by file. Each section tests one behavior or
invariant. Simulations mirror the actual pipeline structure to catch real bugs
(they have already caught the trap bug and several timing issues).

### Simulation structure

Pipeline simulations replace real TTS/playback with lightweight stubs:
- `run_tts` writes sentence text to a file (10ms sleep for generation time).
- `play_audio` logs the sentence and starts a background sleep (simulated playback).
- Traps match speak.sh exactly: `trap cleanup EXIT; trap 'exit 143' TERM; trap 'exit 130' INT`.

Interrupt tests use `_run_interrupt_test` which:
1. Starts the simulation in the background.
2. Polls for N plays to complete.
3. Sends SIGTERM.
4. Verifies generation count <= played + 1 (the lookahead invariant).

### What tests verify

- Config priority (env > file > default)
- Backend routing (auto/elevenlabs/local)
- Fallback chains (429, network failure, with/without local installed)
- Signal handling (cleanup kills children, removes correct files, preserves other instances' PID files)
- Pipeline ordering (gen/play overlap, wait before next play)
- Sentence splitting (offsets, edge cases, fallback)
- Per-sentence billing (each sentence = one API call, interrupt saves credits)
- isSpeakingFlag state machine invariants (all writes locked, generation-guarded)
- Swift structure (methods exist, wiring correct)
- File lifecycle (temp files cleaned, STATUS_FILE persists)
- Daemon robustness (flock, socket cleanup, cancellation, memory management)


## Rules for changes

1. **Default values must match** across speak.sh, Speak11.swift, install.command, and tts_server.py.

2. **Traps must be separate.** Never use `trap handler EXIT INT TERM`. Always:
   ```bash
   trap cleanup EXIT
   trap 'cleanup; exit 130' INT
   trap 'cleanup; exit 143' TERM
   ```
   Or the shorter form (relying on EXIT for cleanup):
   ```bash
   trap cleanup EXIT
   trap 'exit 143' TERM
   trap 'exit 130' INT
   ```

3. **Background + wait for interruptibility.** Any long-running subprocess
   (curl, python, mlx_audio) must run with `&` then `wait $PID` so SIGTERM
   can interrupt the wait.

4. **PID file ownership checks.** Always check `cat "$PID_FILE" == "$$"` before
   removing a PID file. Another instance may have overwritten it.

5. **Pipeline overlap pattern.** The loop must follow: `gen -> wait_audio ->
   cleanup_prev -> play_audio`. Never wait and play in the same step.

6. **STATUS_FILE always 4 lines.** `play_audio` always writes 4 lines using
   `${1:-0}` defaults. Swift's `sentenceLen > 0` guard handles the fallback case.

7. **Cleanup is idempotent.** All cleanup operations must be safe to call multiple
   times (kill dead PIDs, rm missing files).

8. **No set -e in speak.sh.** The script does not use `set -e` at the top level.
   Functions must not introduce it. `cleanup()` explicitly calls `set +e`.

9. **phonemizer-fork, not phonemizer.** The upstream `phonemizer` package breaks
   misaki's EspeakFallback. Always install `phonemizer-fork`.

10. **iconv before TTS.** Text must pass through `iconv -f UTF-8 -t UTF-8//IGNORE`
    before being sent to any TTS backend. PDF text often contains unpaired surrogates.
