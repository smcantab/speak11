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
| `install.command` | Bash | Interactive installer. Dialogs, backend choice, CLT auto-update, Keychain, app compile. |
| `speak11-audio.swift` | Swift | CoreAudio CLI. Sub-millisecond mute check and unmute for standalone use. |

Data flows one way: **Swift -> speak.sh -> tts_server.py**.
The Swift app checks mute state via CoreAudio in-process (microseconds), then
launches speak.sh as a subprocess with `SPEAK11_MUTE_CHECKED=1`. speak.sh
connects to the daemon over a Unix socket. There is no reverse communication
except through shared files (TEXT_FILE, STATUS_FILE, config).


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

### Split implementation

`split_sentences()` uses pySBD (rule-based sentence boundary disambiguation) when
available in the venv, falling back to a regex for cloud-only installs:

1. **pySBD** (venv path): handles abbreviations (`Dr.`, `Mr.`), initials (`J. K.`),
   and all common edge cases correctly.
2. **Regex fallback**: `(?<=[.!?])\s+` with abbreviation protection. Does NOT split
   on colons or semicolons (they are not sentence enders).
3. **Bash fallback** (Python unavailable): whole text as single chunk.

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
   epoch_seconds      (fractional, cached at startup then derived with bash SECONDS)
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


## isSpeakingFlag state machine

The Swift app tracks whether audio is playing via `isSpeakingFlag` and a generation
counter (`speakGeneration`). All writes to both are guarded by `speakLock`.

### States and transitions

```
IDLE --> SPEAKING:    runSpeak() sets flag=true, increments generation
SPEAKING --> IDLE:    task completion (if generation matches saved value)
SPEAKING --> IDLE:    stopSpeaking() (explicit clear, any generation)
SPEAKING --> SPEAKING: respeak() kills old, starts new (generation increments twice)
```

### Generation counter prevents stale completions

1. `runSpeak()` saves `gen=N`, sets `flag=true`.
2. `killCurrentProcess()` sets `gen=N+1`.
3. Old task completes, sees `gen != N`, does NOT clear flag.
4. New `runSpeak()` saves `gen=N+2`, flag stays `true` (correct).

Without the generation counter, step 3 would clear the flag, leaving IDLE during
step 4 -- a race where a second hotkey press could start overlapping audio.

### Invariant

`isSpeakingFlag` is true if and only if there exists a running speak.sh process
that was started by the current generation.


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

After each complete client request (in `handle_client`'s `finally` block, after
the response is sent):
1. `gc.collect()` -- collect Python garbage
2. `mx.metal.clear_cache()` -- release MLX metal buffers

This runs once per text, not once per sentence segment. Doing it between segments
would add gc overhead to back-to-back sentence requests in the pipeline.

Within `generate_audio`, only `del segments, audio` runs to release numpy arrays
immediately. The heavier gc/cache-clear is deferred to idle time.


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

### JSON encoding

`json_encode()` is a pure-bash function (no fork). It escapes `\`, `"`, newline,
carriage return, and tab. This replaces the old `python3 -c "import json..."` call
that forked Python once per sentence (30-80ms x N sentences = 300-800ms overhead).

### Daemon communication

`tts_daemon_request()` uses a python one-liner for Unix socket I/O. macOS's
built-in `nc -U` silently drops responses from Unix sockets (sends fine but
cannot read replies), so a python socket is required. JSON request is built
with `json_encode`, response is parsed with bash string operations. The parser
strips optional spaces after colons (`"key": "value"` vs `"key":"value"`)
because Python's `json.dumps` adds them.


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
| `~/.local/bin/speak11-audio` | Compiled CoreAudio CLI (mute check/unmute) |
| `~/.local/bin/uninstall.command` | Installed uninstaller |
| `~/.local/share/speak11/venv/` | Python venv with mlx-audio |
| `~/.local/share/speak11/tts.sock` | Daemon Unix socket |
| `~/.local/share/speak11/tts_server.pid` | Daemon PID file |
| `~/.local/share/speak11/tts_server.lock` | Daemon flock file |
| `~/.local/share/speak11/tts.log` | Shared log file |
| `~/.local/share/speak11/install.log` | Installer error log (pip, swiftc output) |
| `$TMPDIR/speak11_tts.pid` | speak.sh PID file |
| `$TMPDIR/speak11_text` | Full text for respeak |
| `$TMPDIR/speak11_status` | Playback position for respeak |
| `~/Applications/Speak11.app` | Compiled menu bar app |
| `~/Library/Services/Speak Selection.workflow` | Automator Quick Action |
| `/tmp/speak11_install.lock` | Installer single-instance lock |


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


## Performance

### Critical rule: no O(n^2) bash substitutions

**Never** use `${VAR//[[:space:]]/}` or any `${VAR//[char-class]/replacement}`
in bash 3.2 (macOS default). These are O(n^2) for character class patterns.
A 6KB text takes ~12 seconds per call.

Use `[[ "$VAR" =~ [^[:space:]] ]]` instead (builtin, no fork, short-circuits
on first match, O(n) worst case).

### Minimize forks in hot paths

speak.sh runs on every hotkey press. Each `fork+exec` costs 5-50ms. Rules:

1. **json_encode is pure bash.** No python3 fork per sentence.
2. **tts_daemon_request uses python socket.** One fork per daemon request
   (`nc -U` is broken on macOS -- silently drops responses from Unix sockets).
3. **wav_duration uses pure bash arithmetic.** `stat -f%z` for file size,
   then shell arithmetic for 24kHz mono 16-bit WAV: `(bytes - 44) * 1000 / 48000`.
   Falls back to afinfo for non-WAV (ElevenLabs MP3/OGG).
4. **Fractional epoch is cached once.** `perl -MTime::HiRes` runs once at startup.
   Subsequent calls use `_BASE_EPOCH + (SECONDS - _BASE_SECONDS)` with pure bash
   arithmetic (no fork per sentence).

### Profiling

`tests/profile.sh` measures each phase of speak.sh. Run it to identify
regressions or new optimization opportunities:

```bash
bash tests/profile.sh                  # uses default 2KB test text
bash tests/profile.sh "custom text"    # profile specific text
```

Color-coded output: green (<10ms), yellow (10-100ms), red (>100ms).


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

11. **pySBD for sentence splitting.** The venv installs `pysbd` for high-quality
    sentence boundary detection. The regex fallback must not split on colons or
    semicolons and must protect common abbreviations (`Mr.`, `Dr.`, etc.).

12. **Numeric config values are validated.** `_validate_num` rejects non-numeric
    SPEED, STABILITY, etc. and falls back to defaults. `USE_SPEAKER_BOOST` must
    be exactly `true` or `false`.

13. **Use `xcrun swiftc`, not bare `swiftc`.** `xcrun` resolves the compiler
    through Xcode's toolchain, ensuring the correct SDK is used even when the
    CLT version doesn't match the macOS version.

14. **Installer dialogs must not abort on failure.** Every `$(osascript ...)`
    call in install.command and uninstall.command must end with `|| true`. Without
    it, `set -e` silently kills the script when a user presses Escape or osascript
    fails. Error messages interpolated into osascript strings must be sanitized
    with `tr '"\\' "'/"` to prevent quote injection.

15. **No `set +e` toggles in install.command.** Use `if cmd; then ok=0; else
    ok=$?; fi` instead of `set +e; cmd; rc=$?; set -e`. The `if` pattern is
    clearer about intent and doesn't leave a window where failures are silently
    ignored.

16. **Installer is single-instance.** `mkdir /tmp/speak11_install.lock` acts as
    an atomic lock. Stale locks (dead PID) are reclaimed. The lock is removed in
    the EXIT trap.

17. **Re-install preserves user config.** When `~/.config/speak11/config` already
    exists, the installer updates only `TTS_BACKEND` and `TTS_BACKENDS_INSTALLED`.
    All other fields (voice, speed, stability, etc.) are preserved.

18. **Config is written before the app launches.** The config write block must
    appear before `open "$APP_BUNDLE"` to avoid a first-run race where the Swift
    app reads stale defaults.

19. **Terminal.app calls must be guarded.** Both install.command and
    uninstall.command use `$_IS_TERMINAL_APP` to skip Terminal.app-specific
    AppleScript when the user runs the script in iTerm2, Warp, or another
    terminal. Cleanup closes the specific window by ID, not `front window`.

20. **nc -U is broken on macOS.** The built-in netcat sends data over Unix
    sockets but silently drops responses. Always use a python socket one-liner
    for two-way Unix socket communication.

21. **JSON parsing must handle spaces after colon.** Python's `json.dumps`
    outputs `"key": "value"`. Bash string operations must strip the optional
    space: `${resp#*\"key\":}` then `${val# }`.

22. **Mute check is three-tier.** From the app: in-process CoreAudio
    (microseconds). Standalone: `speak11-audio` CLI (35ms). Last resort:
    osascript (80-500ms). `SPEAK11_MUTE_CHECKED=1` env var tells speak.sh
    the app already handled it.

23. **Profiler detects daemon bypass.** When daemon communication fails,
    speak.sh falls back to cold model loading (~3s). `tests/profile.sh`
    checks for this and prints a warning so silent fallbacks don't go
    unnoticed.

24. **Releases decouple users from HEAD.** Download links point to
    `releases/latest/download/speak11.zip`, not the main branch archive.
    To cut a new release:
    `git archive --format=zip --prefix=speak11/ -o /tmp/speak11.zip HEAD`
    then `gh release create vX.Y.Z /tmp/speak11.zip --title "Speak11 vX.Y.Z" --notes "..."`.
    The `/latest/` URL auto-resolves to the newest release.

25. **Text normalization runs before TTS.** `normalize_text()` in speak.sh
    calls `normalize.py` (standalone Python module) via stdin/stdout, with a
    bash `sed` fallback for hyphen rejoining when Python is unavailable.
    Architecture: source detection -> front-end -> shared back-end. Each
    front-end converts its source format into clean prose; the back-end never
    knows the source.
    **Source detection:** Score-based heuristics (`_is_latex`, `_is_markdown`)
    with high-confidence guards and negative signals. Detection order: LaTeX
    first (higher specificity, with ATX heading as negative signal), then
    Markdown, then PDF (default). Detection is logged to stderr.
    **PDF front-end (`_frontend_pdf`):** ftfy mojibake fix, CRLF, invisible
    character stripping, ligature decomposition, subscript/superscript digits,
    Unicode fractions, hyphenated word rejoining, paragraph-aware line joining,
    scientific notation, isotope notation, bullet/list markers.
    **LaTeX front-end (`_frontend_latex`):** L1: comment/preamble stripping.
    L2: custom macro expansion (with ~/.config/speak11/latex_macros.tex cache).
    L3: environment dispatch table (equation, align, figure, table, lists,
    theorem-likes, skips). L4: text macros (sections, citations, cross-refs,
    siunitx, mhchem, special chars). L5: math-to-speech conversion (22-rule
    cascade producing word-form English). L6: pylatexenc accents + residual
    cleanup. Math-internal environments (pmatrix, cases, etc.) are handled
    by L5, not L3.
    **Markdown front-end (`_frontend_markdown`):** M1: YAML frontmatter +
    Obsidian comments. M2: code blocks. M3: headings. M4: images. M5: links
    + wikilinks. M6: text formatting (bold, italic, strikethrough, inline
    code). M7: math (reuses `_math_to_speech`). M8: block elements (tables,
    blockquotes, lists, horizontal rules). M9: HTML tag stripping. M10: cleanup.
    **Shared back-end:** Phase 0: universal typographic normalization (smart
    quotes, minus, ellipsis, exotic whitespace). Phase A: noise removal (chemicals,
    URLs, citations). Phase B: punctuation, abbreviations, ranges, math operators.
    Phase C: scientific symbols, units, Greek letters, Roman numerals. Phase D:
    final cleanup. Dependencies: ftfy and pylatexenc (installed in venv).

26. **API key is validated on entry.** Both `install.command` and
    `Speak11Settings.swift` validate the API key by calling
    `GET /v1/user/subscription` with the `xi-api-key` header. 200 means valid,
    401 means invalid key, 403 means missing permissions, 000/timeout means
    network error. The dialog loops (retry) until the key validates or the
    user presses Skip/Cancel.

27. **Cmd+V paste requires .regular activation policy.** Menu bar apps use
    `.accessory` activation policy, which means no Edit menu and no Cmd+V.
    Before showing any `NSAlert` with a text field, temporarily switch to
    `NSApp.setActivationPolicy(.regular)` and restore with
    `defer { NSApp.setActivationPolicy(.accessory) }`.

28. **Test suite supports filtering and fast mode.** `tests/test.sh` accepts
    `--fast` (skip slow network tests), `--list` (print section names and
    exit), and a positional filter argument (case-insensitive substring match
    on section names). When python3 is stubbed in tests, the stub must guard
    against `tts_server.py` (`case "$arg" in *tts_server.py) exit 1`) to
    prevent the daemon lock-conflict path from adding 30s per sentence.
