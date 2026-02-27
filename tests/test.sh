#!/bin/bash
# test.sh — Test suite for Speak11
#
# Usage:
#   bash tests/test.sh           # all tests (Swift compile included, ~20s)
#   bash tests/test.sh --fast    # skip slow Swift compile test

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEAK_SH="$SCRIPT_DIR/speak.sh"
SETTINGS_SWIFT="$SCRIPT_DIR/Speak11.swift"
FAST=false
[[ "${1:-}" == "--fast" ]] && FAST=true

PASS=0
FAIL=0

# Isolate tests from any real running TTS daemon
export TTS_SOCK="/tmp/speak11_test_nosock_$$"

# ── Helpers ──────────────────────────────────────────────────────

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf "  PASS  %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$desc"
        printf "        expected: %s\n" "$(printf '%s' "$expected" | cat -v)"
        printf "        actual:   %s\n" "$(printf '%s' "$actual"   | cat -v)"
        FAIL=$((FAIL + 1))
    fi
}

check_exit() {
    local desc="$1" expected_exit="$2"
    shift 2
    local actual_exit=0
    "$@" 2>/dev/null || actual_exit=$?
    check "$desc" "$expected_exit" "$actual_exit"
}

section() { printf "\n── %s\n" "$1"; }

# ── 1. Config variable priority ──────────────────────────────────

section "Config variable priority"

# Inline the sourcing logic from speak.sh so we can test it in isolation.
resolve_voice() {
    local conf="$1" env_var="${2:-}"
    (
        unset VOICE_ID ELEVENLABS_VOICE_ID
        [ -n "$env_var" ] && export ELEVENLABS_VOICE_ID="$env_var"
        _CONFIG="$conf"
        [ -f "$_CONFIG" ] && source "$_CONFIG"
        VOICE_ID="${ELEVENLABS_VOICE_ID:-${VOICE_ID:-pFZP5JQG7iQjIQuC4Bku}}"
        echo "$VOICE_ID"
    )
}

TMPCONF=$(mktemp)
printf 'VOICE_ID="conf-voice"\n' > "$TMPCONF"

check "no config, no env → hardcoded default" \
    "pFZP5JQG7iQjIQuC4Bku" "$(resolve_voice /nonexistent)"

check "config file set → overrides hardcoded default" \
    "conf-voice" "$(resolve_voice "$TMPCONF")"

check "env var set → overrides config file" \
    "env-voice" "$(resolve_voice "$TMPCONF" "env-voice")"

check "env var set → overrides hardcoded default (no config)" \
    "env-voice" "$(resolve_voice /nonexistent "env-voice")"

# Model
TMPCONF2=$(mktemp)
printf 'MODEL_ID="eleven_multilingual_v2"\n' > "$TMPCONF2"
MODEL=$(
    unset MODEL_ID ELEVENLABS_MODEL_ID
    source "$TMPCONF2"
    echo "${ELEVENLABS_MODEL_ID:-${MODEL_ID:-eleven_flash_v2_5}}"
)
check "config model → overrides hardcoded default" "eleven_multilingual_v2" "$MODEL"

# Speed / stability / similarity / style / speaker boost
TMPCONF3=$(mktemp)
printf 'SPEED="1.50"\nSTABILITY="0.80"\nSIMILARITY_BOOST="0.30"\nSTYLE="0.60"\nUSE_SPEAKER_BOOST="false"\n' > "$TMPCONF3"
VALS=$(
    unset SPEED STABILITY SIMILARITY_BOOST STYLE USE_SPEAKER_BOOST
    source "$TMPCONF3"
    echo "${SPEED:-1.0}|${STABILITY:-0.5}|${SIMILARITY_BOOST:-0.75}|${STYLE:-0.0}|${USE_SPEAKER_BOOST:-true}"
)
check "config speed used"            "1.50"  "${VALS%%|*}"
check "config stability used"        "0.80"  "$(echo "$VALS" | cut -d'|' -f2)"
check "config similarity_boost used" "0.30"  "$(echo "$VALS" | cut -d'|' -f3)"
check "config style used"            "0.60"  "$(echo "$VALS" | cut -d'|' -f4)"
check "config use_speaker_boost used" "false" "$(echo "$VALS" | cut -d'|' -f5)"

# Defaults when not set in config
TMPCONF4=$(mktemp)
printf 'VOICE_ID="test"\n' > "$TMPCONF4"
DEFAULTS=$(
    unset STYLE USE_SPEAKER_BOOST
    source "$TMPCONF4"
    echo "${STYLE:-0.0}|${USE_SPEAKER_BOOST:-true}"
)
check "style defaults to 0.0"           "0.0"  "$(echo "$DEFAULTS" | cut -d'|' -f1)"
check "use_speaker_boost defaults to true" "true" "$(echo "$DEFAULTS" | cut -d'|' -f2)"

rm -f "$TMPCONF" "$TMPCONF2" "$TMPCONF3" "$TMPCONF4"

# ── 2. Config file parsing edge cases ────────────────────────────

section "Config file parsing"

TMPCONF=$(mktemp)
printf '# comment\n\nVOICE_ID="real-voice"\n# another comment\n' > "$TMPCONF"
check "comment lines and blank lines ignored" \
    "real-voice" "$(resolve_voice "$TMPCONF")"

TMPCONF2=$(mktemp)
printf "VOICE_ID='single-quoted'\n" > "$TMPCONF2"
check "single-quoted values parsed (bash)" \
    "single-quoted" "$(resolve_voice "$TMPCONF2")"
rm -f "$TMPCONF" "$TMPCONF2"

# ── 3. Empty / whitespace text detection ─────────────────────────

section "Empty / whitespace text detection"

is_blank() { local t="$1"; [ -z "${t//[[:space:]]/}" ] && echo "blank" || echo "nonempty"; }

check "empty string     → blank"    "blank"    "$(is_blank "")"
check "spaces only      → blank"    "blank"    "$(is_blank "   ")"
check "tab only         → blank"    "blank"    "$(is_blank $'\t')"
check "newline only     → blank"    "blank"    "$(is_blank $'\n')"
check "mixed whitespace → blank"    "blank"    "$(is_blank $' \t\n ')"
check "normal text      → nonempty" "nonempty" "$(is_blank "hello")"
check "text with spaces → nonempty" "nonempty" "$(is_blank "hello world")"
check "text with tabs   → nonempty" "nonempty" "$(is_blank $'hello\tworld')"

# ── 4. JSON encoding ─────────────────────────────────────────────
# Verify round-trip: encode then decode should return the original text.
# Note: <<< appends a newline, so we strip it from the round-trip output.

section "JSON encoding (round-trip)"

json_roundtrip() {
    local text="$1"
    local encoded
    encoded=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$text")
    # Decode and strip the trailing newline that <<< added
    python3 -c "import json,sys; s=json.loads(sys.stdin.read()); print(s[:-1] if s.endswith('\n') else s, end='')" <<< "$encoded"
}

check "plain text"      "hello world"   "$(json_roundtrip 'hello world')"
check "double quotes"   'say "hello"'   "$(json_roundtrip 'say "hello"')"
check "backslash"       'path\file'     "$(json_roundtrip 'path\file')"
check "newline"         $'line1\nline2' "$(json_roundtrip $'line1\nline2')"
check "tab"             $'col1\tcol2'   "$(json_roundtrip $'col1\tcol2')"
check "unicode"         "café résumé"   "$(json_roundtrip 'café résumé')"
check "emoji"           "hello 🎙"      "$(json_roundtrip 'hello 🎙')"
# Null bytes: bash truncates strings at \x00 (C-string limitation),
# so $'a\x00b' is already just "a" by the time python3 sees it.
check "null byte truncated by bash (not a crash)" "a" "$(json_roundtrip $'a\x00b')"

# Verify the output is actually valid JSON (python can load it)
check "output is valid JSON" "0" "$(
    python3 -c "
import json, sys
text = 'complex: \"quotes\" and \\\\backslash and \ttabs'
encoded = json.dumps(text)
decoded = json.loads(encoded)
sys.exit(0 if decoded == text else 1)
" 2>/dev/null; echo $?)"

# ── 5. PID file toggle logic ─────────────────────────────────────

section "PID file toggle logic"

simulate_toggle() {
    local pid_file="$1" fake_pid="$2"
    [ -n "$fake_pid" ] && echo "$fake_pid" > "$pid_file"
    local result="continued"
    if [ -f "$pid_file" ]; then
        local OLD_PID
        OLD_PID=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            result="stopped"
        fi
        rm -f "$pid_file"
    fi
    echo "$result"
}

TMPDIR_T=$(mktemp -d)

check "no PID file → continues" \
    "continued" "$(simulate_toggle "$TMPDIR_T/no.pid" "")"

check "stale PID (process gone) → cleans up and continues" \
    "continued" "$(simulate_toggle "$TMPDIR_T/stale.pid" "99999999")"

check "stale PID file removed after cleanup" \
    "gone" "$(
        f="$TMPDIR_T/stale2.pid"
        simulate_toggle "$f" "99999999" > /dev/null
        [ -f "$f" ] && echo "exists" || echo "gone"
    )"

# Live PID: use a real background process to test the "stop" path
check "live PID → stops playback" \
    "stopped" "$(
        sleep 60 &
        LIVE_PID=$!
        f="$TMPDIR_T/live.pid"
        echo "$LIVE_PID" > "$f"
        result=$(simulate_toggle "$f" "")
        kill "$LIVE_PID" 2>/dev/null || true
        echo "$result"
    )"

rm -rf "$TMPDIR_T"

# ── 6. No key + no local → failure ───────────────────────────────

section "No key + no local → failure"

# Auto with no API key degrades to local. If local TTS also fails → exit 1.
_STUBS=$(mktemp -d)
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"   # no Keychain entry
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"  # suppress dialogs
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/curl"       # must never be reached
# python3 stub: fail all calls (no local TTS available)
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/python3"
chmod +x "$_STUBS/security" "$_STUBS/osascript" "$_STUBS/curl" "$_STUBS/python3"

check_exit "auto + no API key + no local TTS → exits 1" 1 \
    bash -c 'echo "hello world" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" ELEVENLABS_API_KEY="" TTS_BACKEND=auto bash "'"$SPEAK_SH"'"'

rm -rf "$_STUBS"

# ── 7. speak.sh shellcheck / syntax ──────────────────────────────

section "speak.sh syntax"

check "bash syntax valid" "0" "$(bash -n "$SPEAK_SH" 2>/dev/null; echo $?)"

if command -v shellcheck &>/dev/null; then
    check "shellcheck passes" "0" "$(shellcheck -S warning "$SPEAK_SH" 2>/dev/null; echo $?)"
else
    printf "  SKIP  shellcheck not installed\n"
fi

# ── 8. install.command syntax + structure ─────────────────────────

section "install.command syntax + structure"

check "bash syntax valid" "0" "$(bash -n "$SCRIPT_DIR/install.command" 2>/dev/null; echo $?)"

# Bug A: Config write must be unconditional (not nested inside settings app block).
# The case statement assigning _CFG_BACKEND must be at column 0 (top-level code).
check "config write is not nested inside settings if block" \
    "yes" "$(grep -m1 '^case.*BACKEND_CHOICE' "$SCRIPT_DIR/install.command" >/dev/null && echo "yes" || echo "no")"

# Bug B: Done dialog must condition the "model downloaded" message on mlx_ok.
# Check that mlx_ok appears within 3 lines before the "Kokoro voice model" line.
check "done dialog conditions model message on mlx_ok" \
    "yes" "$(grep -B3 'Kokoro voice model' "$SCRIPT_DIR/install.command" | grep -q 'mlx_ok' && echo "yes" || echo "no")"

# ── 9. uninstall.command syntax ──────────────────────────────

section "uninstall.command syntax"

check "bash syntax valid" "0" "$(bash -n "$SCRIPT_DIR/uninstall.command" 2>/dev/null; echo $?)"

# ── 10. Swift source structure ────────────────────────────────────

section "Speak11.swift structure"

# Respeak support methods
check "Swift: handleHotkey method exists" \
    "yes" "$(grep -q 'func handleHotkey' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: runSpeak method exists" \
    "yes" "$(grep -q 'func runSpeak' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: killCurrentProcess method exists" \
    "yes" "$(grep -q 'func killCurrentProcess' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: calculateRemainingText method exists" \
    "yes" "$(grep -q 'func calculateRemainingText' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: respeak method exists" \
    "yes" "$(grep -q 'func respeak' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: scheduleRespeak method exists" \
    "yes" "$(grep -q 'func scheduleRespeak' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: speakGeneration property exists" \
    "yes" "$(grep -q 'speakGeneration' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: speakLock property exists" \
    "yes" "$(grep -q 'speakLock' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# API key management methods
check "Swift: readAPIKey method exists" \
    "yes" "$(grep -q 'func readAPIKey' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: saveAPIKey method exists" \
    "yes" "$(grep -q 'func saveAPIKey' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"
check "Swift: manageAPIKey method exists" \
    "yes" "$(grep -q 'func manageAPIKey' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# Respeak wired into settings actions (scheduleRespeak called after config.save in actions)
check "Swift: pickSpeed calls scheduleRespeak" \
    "yes" "$(awk '/func pickSpeed/,/^    \}/' "$SETTINGS_SWIFT" | grep -q 'scheduleRespeak' && echo "yes" || echo "no")"
check "Swift: pickVoice calls scheduleRespeak" \
    "yes" "$(awk '/func pickVoice/,/^    \}/' "$SETTINGS_SWIFT" | grep -q 'scheduleRespeak' && echo "yes" || echo "no")"

# ── 11. Swift compile (slow ~15s) ────────────────────────────────

section "Speak11.swift compile"

if $FAST; then
    printf "  SKIP  (--fast mode)\n"
elif ! command -v swiftc &>/dev/null; then
    printf "  SKIP  swiftc not found\n"
else
    TMPBIN=$(mktemp)
    rm -f "$TMPBIN"
    printf "        compiling… (this takes ~15s)\n"
    if swiftc "$SETTINGS_SWIFT" -o "$TMPBIN" -O 2>/dev/null; then
        check "compiles without errors" "yes" "yes"
        check "binary is executable"    "yes" "$( [ -x "$TMPBIN" ] && echo yes || echo no )"
        rm -f "$TMPBIN"
    else
        check "compiles without errors" "yes" "no"
    fi
fi

# ── 11. TTS_BACKEND / LOCAL_VOICE config priority ─────────────────

section "TTS_BACKEND / LOCAL_VOICE config priority"

resolve_backend_config() {
    local conf="$1" env_backend="${2:-}" env_voice="${3:-}"
    (
        unset TTS_BACKEND LOCAL_VOICE
        [ -n "$env_backend" ] && export TTS_BACKEND="$env_backend"
        [ -n "$env_voice" ] && export LOCAL_VOICE="$env_voice"
        _ENV_TTS_BACKEND="${TTS_BACKEND:-}"
        _ENV_LOCAL_VOICE="${LOCAL_VOICE:-}"
        _CONFIG="$conf"
        [ -f "$_CONFIG" ] && source "$_CONFIG"
        TTS_BACKEND="${_ENV_TTS_BACKEND:-${TTS_BACKEND:-auto}}"
        LOCAL_VOICE="${_ENV_LOCAL_VOICE:-${LOCAL_VOICE:-bf_lily}}"
        echo "${TTS_BACKEND}|${LOCAL_VOICE}"
    )
}

TMPCONF=$(mktemp)
printf 'TTS_BACKEND="local"\nLOCAL_VOICE="am_adam"\n' > "$TMPCONF"

check "no config → backend defaults to auto" \
    "auto" "$(resolve_backend_config /nonexistent | cut -d'|' -f1)"
check "no config → local voice defaults to bf_lily" \
    "bf_lily" "$(resolve_backend_config /nonexistent | cut -d'|' -f2)"
check "config sets backend=local" \
    "local" "$(resolve_backend_config "$TMPCONF" | cut -d'|' -f1)"
check "config sets local voice=am_adam" \
    "am_adam" "$(resolve_backend_config "$TMPCONF" | cut -d'|' -f2)"
check "env var overrides config backend" \
    "auto" "$(resolve_backend_config "$TMPCONF" "auto" | cut -d'|' -f1)"
check "env var overrides config local voice" \
    "af_sky" "$(resolve_backend_config "$TMPCONF" "" "af_sky" | cut -d'|' -f2)"

rm -f "$TMPCONF"

# ── 12. PID file uses speak11_tts prefix ─────────────────────────

section "PID file prefix"

check "speak.sh uses speak11_tts.pid" \
    "yes" "$(grep -q 'speak11_tts\.pid' "$SPEAK_SH" && echo "yes" || echo "no")"
check "speak.sh does not use elevenlabs_tts.pid" \
    "yes" "$(! grep -q 'elevenlabs_tts\.pid' "$SPEAK_SH" && echo "yes" || echo "no")"
check "speak.sh uses speak11_tts_ temp file prefix" \
    "yes" "$(grep -q 'speak11_tts_' "$SPEAK_SH" && echo "yes" || echo "no")"

# ── 13. API key guard skipped for local backend ──────────────────

section "API key guard (local backend)"

_STUBS=$(mktemp -d)
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"   # no Keychain entry
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"   # suppress dialogs
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"      # no-op playback
# python3 stub: handle mlx_audio calls by creating fake wav; pass through otherwise
cat > "$_STUBS/python3" << PYSTUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
done
exit 1  # fail non-mlx_audio calls (e.g. daemon) so tests use fallback path
PYSTUB
chmod +x "$_STUBS/security" "$_STUBS/osascript" "$_STUBS/afplay" "$_STUBS/python3"

check_exit "TTS_BACKEND=local with no API key → exits 0 (key not needed)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=local LOCAL_VOICE=af_heart bash "'"$SPEAK_SH"'"'

rm -rf "$_STUBS"

# ── 14. Backend routing ──────────────────────────────────────────

section "Backend routing"

_STUBS=$(mktemp -d)
_MARKERS="$_STUBS/markers"
mkdir -p "$_MARKERS"

printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"

# curl stub: mark that it was called, return 200 with fake audio
cat > "$_STUBS/curl" << STUB
#!/bin/bash
touch "$_MARKERS/curl_called"
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then printf "fakeaudio" > "\$a"; fi
    prev="\$a"
done
printf "200"
STUB

# python3 stub: track mlx_audio calls, block daemon, pass through json calls
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        touch "$_MARKERS/mlx_called"
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
    case "\$arg" in *tts_server.py) exit 1;; esac
done
/usr/bin/python3 "\$@"
STUB

chmod +x "$_STUBS/security" "$_STUBS/osascript" "$_STUBS/afplay" "$_STUBS/curl" "$_STUBS/python3"

# Test: local backend routes to mlx_audio, not curl
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=local bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true
check "local backend → curl NOT called" \
    "no" "$([ -f "$_MARKERS/curl_called" ] && echo "yes" || echo "no")"
check "local backend → mlx_audio called" \
    "yes" "$([ -f "$_MARKERS/mlx_called" ] && echo "yes" || echo "no")"

# Test: auto backend (with API key) routes to curl, not mlx_audio
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true
check "auto backend (key) → curl called" \
    "yes" "$([ -f "$_MARKERS/curl_called" ] && echo "yes" || echo "no")"
check "auto backend (key) → mlx_audio NOT called" \
    "no" "$([ -f "$_MARKERS/mlx_called" ] && echo "yes" || echo "no")"

rm -rf "$_STUBS"

# ── 15. HTTP 429 quota detection ─────────────────────────────────

section "HTTP 429 quota detection"

_STUBS=$(mktemp -d)
_LOG="$_STUBS/osascript.log"
printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"

# osascript: log calls, return "Not Now" (user declines local install)
cat > "$_STUBS/osascript" << STUB
#!/bin/bash
echo "\$*" >> "$_LOG"
echo "Not Now"
STUB

# curl: return HTTP 429 with quota_exceeded body
cat > "$_STUBS/curl" << 'CURLSTUB'
#!/bin/bash
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && printf '{"detail":{"status":"quota_exceeded"}}' > "$a"
    prev="$a"
done
printf "429"
CURLSTUB

printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
# python3: pass through for json encoding in the elevenlabs path
printf '#!/bin/bash\n/usr/bin/python3 "$@"\n' > "$_STUBS/python3"
chmod +x "$_STUBS"/*

bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=elevenlabs bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true

# The 429 handler should show a special dialog offering to install local TTS,
# not just the generic error dialog (which also happens to contain "quota" from
# the response body).  Check for the specific "Install Local TTS" button text.
check "HTTP 429 → quota dialog offers local TTS install" \
    "yes" "$(grep -qi 'Install Local TTS' "$_LOG" 2>/dev/null && echo "yes" || echo "no")"

# Non-429 errors should NOT mention quota
> "$_LOG"   # clear log
cat > "$_STUBS/curl" << 'CURLSTUB'
#!/bin/bash
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && printf '{"detail":"invalid_api_key"}' > "$a"
    prev="$a"
done
printf "401"
CURLSTUB
chmod +x "$_STUBS/curl"

check_exit "HTTP 401 → exits 1 (normal error, not quota)" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=elevenlabs bash "'"$SPEAK_SH"'"'

check "HTTP 401 → dialog does NOT offer local TTS install" \
    "no" "$(grep -qi 'Install Local TTS' "$_LOG" 2>/dev/null && echo "yes" || echo "no")"

rm -rf "$_STUBS"

# ── 16. Local TTS generation failure ─────────────────────────────

section "Local TTS generation failure"

_STUBS=$(mktemp -d)
_LOG="$_STUBS/osascript.log"
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"

# osascript: log calls
cat > "$_STUBS/osascript" << STUB
#!/bin/bash
echo "\$*" >> "$_LOG"
echo "OK"
STUB

# python3: mlx_audio call fails with exit 1
cat > "$_STUBS/python3" << 'PYSTUB'
#!/bin/bash
for arg in "$@"; do
    [ "$arg" = "mlx_audio.tts.generate" ] && exit 1
done
exit 1  # fail non-mlx_audio calls (e.g. daemon) so tests use fallback path
PYSTUB
chmod +x "$_STUBS"/*

check_exit "local TTS generation failure → exits 1" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=local bash "'"$SPEAK_SH"'"'

# Check that the dialog specifically mentions local/generation failure, not just any dialog
check "local TTS failure → error dialog mentions generation" \
    "yes" "$(grep -qi 'generat' "$_LOG" 2>/dev/null && echo "yes" || echo "no")"

rm -rf "$_STUBS"

# ── 17. Auto-fallback when both backends installed ───────────────

section "Auto-fallback (both backends installed)"

_STUBS=$(mktemp -d)
_MARKERS="$_STUBS/markers"
_LOG="$_STUBS/osascript.log"
mkdir -p "$_MARKERS"

printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"

# osascript: log calls (should NOT be called for silent fallback)
cat > "$_STUBS/osascript" << STUB
#!/bin/bash
echo "\$*" >> "$_LOG"
echo "OK"
STUB

# curl: return 429 (quota exceeded)
cat > "$_STUBS/curl" << 'CURLSTUB'
#!/bin/bash
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && printf '{"detail":"quota_exceeded"}' > "$a"
    prev="$a"
done
printf "429"
CURLSTUB

# python3: handle mlx_audio (for fallback), block daemon, pass through json calls
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        touch "$_MARKERS/mlx_fallback_called"
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
    case "\$arg" in *tts_server.py) exit 1;; esac
done
/usr/bin/python3 "\$@"
STUB

chmod +x "$_STUBS"/*

# Test: 429 + both installed → silent fallback to local (no dialog)
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
check_exit "429 + both installed → exits 0 (silent fallback)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=both bash "'"$SPEAK_SH"'"'
check "429 + both → local TTS called as fallback" \
    "yes" "$([ -f "$_MARKERS/mlx_fallback_called" ] && echo "yes" || echo "no")"
check "429 + both → no dialog shown (silent)" \
    "no" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: network failure (curl exits non-zero) + both installed → silent fallback
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
printf '#!/bin/bash\nexit 7\n' > "$_STUBS/curl"   # exit 7 = connection refused
chmod +x "$_STUBS/curl"

check_exit "network failure + both installed → exits 0 (silent fallback)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=both bash "'"$SPEAK_SH"'"'
check "network failure + both → local TTS called as fallback" \
    "yes" "$([ -f "$_MARKERS/mlx_fallback_called" ] && echo "yes" || echo "no")"

# Test: 429 + both + local TTS FAILS → error dialog (not silent)
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
# Replace python3 stub with one that fails for mlx_audio
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        exit 1  # simulate local TTS failure
    fi
    case "\$arg" in *tts_server.py) exit 1;; esac
done
/usr/bin/python3 "\$@"
STUB
chmod +x "$_STUBS/python3"
# Restore 429 curl stub
cat > "$_STUBS/curl" << 'CURLSTUB'
#!/bin/bash
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && printf '{"detail":"quota_exceeded"}' > "$a"
    prev="$a"
done
printf "429"
CURLSTUB
chmod +x "$_STUBS/curl"

check_exit "429 + both + local fails → exits 1" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=both bash "'"$SPEAK_SH"'"'
check "429 + both + local fails → error dialog shown" \
    "yes" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: network failure + both + local TTS FAILS → error dialog
rm -f "$_LOG"
printf '#!/bin/bash\nexit 7\n' > "$_STUBS/curl"
chmod +x "$_STUBS/curl"

check_exit "network failure + both + local fails → exits 1" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=both bash "'"$SPEAK_SH"'"'
check "network failure + both + local fails → error dialog shown" \
    "yes" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: network failure + elevenlabs only → error dialog, not fallback
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
check_exit "network failure + elevenlabs only → exits 1" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=elevenlabs bash "'"$SPEAK_SH"'"'
check "network failure + elevenlabs only → error dialog shown" \
    "yes" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"
check "network failure + elevenlabs only → no fallback to local" \
    "no" "$([ -f "$_MARKERS/mlx_fallback_called" ] && echo "yes" || echo "no")"

rm -rf "$_STUBS"

# ── 18. install-local.sh syntax ──────────────────────────────────

section "install-local.sh syntax"

check "bash syntax valid" "0" "$(bash -n "$SCRIPT_DIR/install-local.sh" 2>/dev/null; echo $?)"

# ── 19. Respeak support: play_audio, TEXT_FILE, STATUS_FILE ──────

section "Respeak support (play_audio, TEXT_FILE, STATUS_FILE)"

# Verify play_audio function exists in speak.sh
check "speak.sh defines play_audio function" \
    "yes" "$(grep -q '^play_audio()' "$SPEAK_SH" && echo "yes" || echo "no")"

# Verify TEXT_FILE and STATUS_FILE paths are defined
check "speak.sh defines TEXT_FILE path" \
    "yes" "$(grep -q 'TEXT_FILE=.*speak11_text' "$SPEAK_SH" && echo "yes" || echo "no")"
check "speak.sh defines STATUS_FILE path" \
    "yes" "$(grep -q 'STATUS_FILE=.*speak11_status' "$SPEAK_SH" && echo "yes" || echo "no")"

# Verify TEXT_FILE is written after text acquisition
check "speak.sh writes TEXT_FILE" \
    "yes" "$(grep -q 'printf.*TEXT.*TEXT_FILE\|> "$TEXT_FILE"\|>"$TEXT_FILE"' "$SPEAK_SH" && echo "yes" || echo "no")"

# Verify STATUS_FILE is written in play_audio (with afinfo duration)
check "play_audio writes STATUS_FILE with afinfo duration" \
    "yes" "$(grep -q 'afinfo.*STATUS_FILE\|STATUS_FILE.*afinfo\|STATUS_FILE' "$SPEAK_SH" && grep -q 'afinfo' "$SPEAK_SH" && echo "yes" || echo "no")"

# Functional test: run speak.sh with auto backend (cloud path) and verify files are created
_STUBS=$(mktemp -d)
_TESTTMP=$(mktemp -d)
printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
# afplay stub: exits immediately
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
# afinfo stub: return fake duration
cat > "$_STUBS/afinfo" << 'STUB'
#!/bin/bash
echo "estimated duration: 5.000000 sec"
STUB
# curl stub: return 200 with fake audio
cat > "$_STUBS/curl" << 'STUB'
#!/bin/bash
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then printf "fakeaudio" > "$a"; fi
    prev="$a"
done
printf "200"
STUB
printf '#!/bin/bash\n/usr/bin/python3 "$@"\n' > "$_STUBS/python3"
chmod +x "$_STUBS"/*

echo "Hello world. This is a test sentence." | \
    env PATH="$_STUBS:$PATH" VENV_PYTHON="$_STUBS/python3" TMPDIR="$_TESTTMP" TTS_BACKEND=auto \
    bash "$SPEAK_SH" >/dev/null 2>&1 || true

check "TEXT_FILE created with piped text" \
    "Hello world. This is a test sentence." "$(cat "$_TESTTMP/speak11_text" 2>/dev/null)"

check "STATUS_FILE created" \
    "yes" "$([ -f "$_TESTTMP/speak11_status" ] && echo "yes" || echo "no")"

check "STATUS_FILE has two lines" \
    "2" "$([ -f "$_TESTTMP/speak11_status" ] && wc -l < "$_TESTTMP/speak11_status" | tr -d ' ' || echo "0")"

# First line should be a recent epoch timestamp (within last 60 seconds)
_STATUS_EPOCH=$(head -1 "$_TESTTMP/speak11_status" 2>/dev/null || echo "0")
_NOW_EPOCH=$(date +%s)
_EPOCH_DIFF=$(( ${_NOW_EPOCH:-0} - ${_STATUS_EPOCH:-0} ))
check "STATUS_FILE epoch is recent (within 60s)" \
    "yes" "$([ "$_EPOCH_DIFF" -ge 0 ] && [ "$_EPOCH_DIFF" -le 60 ] && echo "yes" || echo "no")"

# Second line should be the duration from afinfo stub
check "STATUS_FILE contains audio duration" \
    "5.000000" "$([ -f "$_TESTTMP/speak11_status" ] && sed -n '2p' "$_TESTTMP/speak11_status" || echo "none")"

rm -rf "$_STUBS" "$_TESTTMP"

# Functional test: run speak.sh with local backend and verify files
_STUBS=$(mktemp -d)
_TESTTMP=$(mktemp -d)
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
cat > "$_STUBS/afinfo" << 'STUB'
#!/bin/bash
echo "estimated duration: 3.500000 sec"
STUB
# python3: handle mlx_audio (create fake wav) and pass through otherwise
cat > "$_STUBS/python3" << PYSTUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
done
exit 1  # fail non-mlx_audio calls (e.g. daemon) so tests use fallback path
PYSTUB
chmod +x "$_STUBS"/*

echo "Local TTS test sentence." | \
    env PATH="$_STUBS:$PATH" VENV_PYTHON="$_STUBS/python3" TMPDIR="$_TESTTMP" TTS_BACKEND=local LOCAL_VOICE=af_heart \
    bash "$SPEAK_SH" >/dev/null 2>&1 || true

check "local backend: TEXT_FILE created" \
    "Local TTS test sentence." "$(cat "$_TESTTMP/speak11_text" 2>/dev/null)"
check "local backend: STATUS_FILE created" \
    "yes" "$([ -f "$_TESTTMP/speak11_status" ] && echo "yes" || echo "no")"

rm -rf "$_STUBS" "$_TESTTMP"

# ── 20. TTS_BACKEND=auto routing ─────────────────────────────────

section "TTS_BACKEND=auto routing"

# Verify default changed in speak.sh
check "speak.sh default backend is auto" \
    "yes" "$(grep -q 'TTS_BACKEND:-auto' "$SPEAK_SH" && echo "yes" || echo "no")"

_STUBS=$(mktemp -d)
_MARKERS="$_STUBS/markers"
mkdir -p "$_MARKERS"

printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
cat > "$_STUBS/afinfo" << 'STUB'
#!/bin/bash
echo "estimated duration: 5.000000 sec"
STUB

# curl stub: mark called, return 200
cat > "$_STUBS/curl" << STUB
#!/bin/bash
touch "$_MARKERS/curl_called"
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then printf "fakeaudio" > "\$a"; fi
    prev="\$a"
done
printf "200"
STUB

# python3 stub: track mlx_audio calls, block daemon, pass through json calls
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        touch "$_MARKERS/mlx_called"
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
    case "\$arg" in *tts_server.py) exit 1;; esac
done
/usr/bin/python3 "\$@"
STUB
chmod +x "$_STUBS"/*

# Test: auto + API key → ElevenLabs
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true
check "auto + API key → curl called (ElevenLabs)" \
    "yes" "$([ -f "$_MARKERS/curl_called" ] && echo "yes" || echo "no")"
check "auto + API key → mlx_audio NOT called" \
    "no" "$([ -f "$_MARKERS/mlx_called" ] && echo "yes" || echo "no")"

# Test: auto + no API key → local
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"
chmod +x "$_STUBS/security"
bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto ELEVENLABS_API_KEY="" bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true
check "auto + no API key → curl NOT called" \
    "no" "$([ -f "$_MARKERS/curl_called" ] && echo "yes" || echo "no")"
check "auto + no API key → mlx_audio called (local)" \
    "yes" "$([ -f "$_MARKERS/mlx_called" ] && echo "yes" || echo "no")"

# Test: auto + no API key → exits 0 (no error dialog)
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
check_exit "auto + no API key → exits 0 (silent local)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto ELEVENLABS_API_KEY="" bash "'"$SPEAK_SH"'"'

rm -rf "$_STUBS"

# ── 21. TTS_BACKEND=auto fallback on failure ─────────────────────

section "TTS_BACKEND=auto fallback on failure"

_STUBS=$(mktemp -d)
_MARKERS="$_STUBS/markers"
_LOG="$_STUBS/osascript.log"
mkdir -p "$_MARKERS"

printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
cat > "$_STUBS/afinfo" << 'STUB'
#!/bin/bash
echo "estimated duration: 5.000000 sec"
STUB
cat > "$_STUBS/osascript" << STUB
#!/bin/bash
echo "\$*" >> "$_LOG"
echo "OK"
STUB

# curl: simulate network failure
printf '#!/bin/bash\nexit 7\n' > "$_STUBS/curl"

# python3: handle mlx_audio for fallback, block daemon, pass through json calls
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        touch "$_MARKERS/mlx_fallback_called"
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
    case "\$arg" in *tts_server.py) exit 1;; esac
done
/usr/bin/python3 "\$@"
STUB
chmod +x "$_STUBS"/*

rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
check_exit "auto + network failure → exits 0 (falls back)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto bash "'"$SPEAK_SH"'"'
check "auto + network failure → local TTS called" \
    "yes" "$([ -f "$_MARKERS/mlx_fallback_called" ] && echo "yes" || echo "no")"
check "auto + network failure → no dialog (silent)" \
    "no" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: auto + 429 → silent fallback
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
cat > "$_STUBS/curl" << 'CURLSTUB'
#!/bin/bash
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && printf '{"detail":"quota_exceeded"}' > "$a"
    prev="$a"
done
printf "429"
CURLSTUB
chmod +x "$_STUBS/curl"

check_exit "auto + 429 → exits 0 (falls back)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto bash "'"$SPEAK_SH"'"'
check "auto + 429 → local TTS called" \
    "yes" "$([ -f "$_MARKERS/mlx_fallback_called" ] && echo "yes" || echo "no")"

rm -rf "$_STUBS"

# ── 22. Auto-derive lang_code from voice ─────────────────────────

section "Auto-derive lang_code from voice"

# speak.sh derives lang_code from the voice prefix (first character)
check "speak.sh derives lang_code from LOCAL_VOICE" \
    "yes" "$(grep -q 'LOCAL_VOICE:0:1' "$SPEAK_SH" && echo "yes" || echo "no")"

# Functional test: verify the derived lang_code is passed to mlx_audio
_STUBS=$(mktemp -d)
_TESTTMP=$(mktemp -d)
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
cat > "$_STUBS/afinfo" << 'STUB'
#!/bin/bash
echo "estimated duration: 2.000000 sec"
STUB

# python3: capture the --lang_code argument
cat > "$_STUBS/python3" << PYSTUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        # Capture lang_code
        prev=""
        for a in "\$@"; do
            if [ "\$prev" = "--lang_code" ]; then
                printf "%s" "\$a" > "$_TESTTMP/captured_lang"
            fi
            prev="\$a"
        done
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
done
exit 1  # fail non-mlx_audio calls (e.g. daemon) so tests use fallback path
PYSTUB
chmod +x "$_STUBS"/*

# Test with American voice → should derive lang_code "a"
echo "test" | env PATH="$_STUBS:$PATH" VENV_PYTHON="$_STUBS/python3" TMPDIR="$_TESTTMP" TTS_BACKEND=local LOCAL_VOICE=af_heart \
    bash "$SPEAK_SH" >/dev/null 2>&1 || true
check "af_heart → lang_code 'a'" \
    "a" "$(cat "$_TESTTMP/captured_lang" 2>/dev/null)"

# Test with British voice → should derive lang_code "b"
rm -f "$_TESTTMP/captured_lang"
echo "test" | env PATH="$_STUBS:$PATH" VENV_PYTHON="$_STUBS/python3" TMPDIR="$_TESTTMP" TTS_BACKEND=local LOCAL_VOICE=bf_emma \
    bash "$SPEAK_SH" >/dev/null 2>&1 || true
check "bf_emma → lang_code 'b'" \
    "b" "$(cat "$_TESTTMP/captured_lang" 2>/dev/null)"

rm -rf "$_STUBS" "$_TESTTMP"

# ── 23. Swift auto backend + credits structure ───────────────────

section "Swift auto backend + credits structure"

check "Swift: buildBackendItems includes Auto" \
    "yes" "$(grep -q '"Auto"' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Swift: backend item uses repr auto" \
    "yes" "$(grep -q '"auto"' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Swift: API Key condition uses ttsBackend auto" \
    "yes" "$(grep -A5 'ttsBackend.*==.*"auto"' "$SETTINGS_SWIFT" | grep -q 'API Key\|apiItem\|api-key\|Credits' && echo "yes" || echo "no")"

check "Swift: fetchCredits method exists" \
    "yes" "$(grep -q 'func fetchCredits' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Swift: fetchCredits fires for both auto and elevenlabs" \
    "yes" "$(grep -A2 'func fetchCredits' "$SETTINGS_SWIFT" | grep -q '"elevenlabs"' && echo "yes" || echo "no")"

check "Swift: cachedCredits property exists" \
    "yes" "$(grep -q 'cachedCredits' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Swift: pickLanguage removed" \
    "yes" "$(! grep -q 'func pickLanguage' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# ── 24. isSpeakingFlag state machine invariants ──────────────────
#
# These tests verify the speaking-state lifecycle so that
# scheduleRespeak() only fires while actually speaking.
# A violation of any invariant = phantom respeaks or stuck state.

section "isSpeakingFlag state machine"

# ── Invariant 1: every exit path from runSpeak clears the flag ──
#
# runSpeak's async block has exactly 2 exit paths:
#   a) task.run() throws → early return
#   b) task.waitUntilExit() → normal completion
# Both MUST set isSpeakingFlag = false (guarded by generation).

# Count how many times isSpeakingFlag is set to true inside runSpeak.
_TRUE_IN_RUNSPEAK=$(awk '/func runSpeak/,/^    \}/' "$SETTINGS_SWIFT" \
    | grep -c 'isSpeakingFlag = true')

# Count how many times it's set to false inside runSpeak.
_FALSE_IN_RUNSPEAK=$(awk '/func runSpeak/,/^    \}/' "$SETTINGS_SWIFT" \
    | grep -c 'isSpeakingFlag = false')

check "runSpeak: flag-clear count >= flag-set count" \
    "yes" "$([ "$_FALSE_IN_RUNSPEAK" -ge "$_TRUE_IN_RUNSPEAK" ] && echo "yes" || echo "no")"

check "runSpeak: sets flag true exactly once (at entry)" \
    "1" "$_TRUE_IN_RUNSPEAK"

check "runSpeak: clears flag in both exit paths (count=2)" \
    "2" "$_FALSE_IN_RUNSPEAK"

# ── Invariant 2: error path clears the flag ─────────────────────
# The catch block (task.run() throws) must clear isSpeakingFlag
# before its early return.
check "runSpeak: error path (catch) clears flag" \
    "yes" "$(awk '/func runSpeak/,/^    \}/' "$SETTINGS_SWIFT" \
        | awk '/} catch/,/return/' \
        | grep -q 'isSpeakingFlag = false' && echo "yes" || echo "no")"

# ── Invariant 3: normal completion clears the flag ──────────────
# After task.waitUntilExit(), isSpeakingFlag must be set to false.
check "runSpeak: normal completion (waitUntilExit) clears flag" \
    "yes" "$(awk '/func runSpeak/,/^    \}/' "$SETTINGS_SWIFT" \
        | awk '/waitUntilExit/,0' \
        | grep -q 'isSpeakingFlag = false' && echo "yes" || echo "no")"

# ── Invariant 4: flag always cleared under lock ─────────────────
# Every assignment to isSpeakingFlag must be between
# speakLock.lock() and speakLock.unlock().
# Extract lines that write to the flag and verify each has a
# preceding lock and subsequent unlock.
_UNGUARDED=$(awk '
    /speakLock\.lock/   { locked=1 }
    /speakLock\.unlock/ { locked=0 }
    /isSpeakingFlag =/ && !/var isSpeakingFlag/ && !locked { count++ }
    END { print count+0 }
' "$SETTINGS_SWIFT")

check "isSpeakingFlag: all writes are under speakLock (0 unguarded)" \
    "0" "$_UNGUARDED"

# ── Invariant 5: flag always READ under lock ────────────────────
# Reading isSpeakingFlag outside the lock is a race. Check that
# every read (let x = isSpeakingFlag) is also guarded.
_UNGUARDED_READ=$(awk '
    /speakLock\.lock/   { locked=1 }
    /speakLock\.unlock/ { locked=0 }
    /= isSpeakingFlag/ && !locked { count++ }
    END { print count+0 }
' "$SETTINGS_SWIFT")

check "isSpeakingFlag: all reads are under speakLock (0 unguarded)" \
    "0" "$_UNGUARDED_READ"

# ── Invariant 6: generation guard on clears in runSpeak ─────────
# Inside runSpeak, isSpeakingFlag = false must always be guarded by
# a generation check (to avoid clobbering a newer runSpeak call).
_UNGUARDED_CLEAR=$(awk '/func runSpeak/,/^    \}/' "$SETTINGS_SWIFT" | awk '
    /== gen/ { gen_check=1 }
    /isSpeakingFlag = false/ {
        if (!gen_check) unguarded++
        gen_check=0
    }
    END { print unguarded+0 }
')

check "runSpeak: every flag-clear is generation-guarded (0 unguarded)" \
    "0" "$_UNGUARDED_CLEAR"

# ── Invariant 7: stopSpeaking unconditionally clears ────────────
# stopSpeaking is the manual-stop path; it must always clear.
check "stopSpeaking: clears isSpeakingFlag" \
    "yes" "$(awk '/func stopSpeaking/,/^    \}/' "$SETTINGS_SWIFT" \
        | grep -q 'isSpeakingFlag = false' && echo "yes" || echo "no")"

# ── Invariant 8: scheduleRespeak guards on the flag ─────────────
# scheduleRespeak must read isSpeakingFlag and return early if false.
check "scheduleRespeak: reads isSpeakingFlag" \
    "yes" "$(awk '/func scheduleRespeak/,/^    \}/' "$SETTINGS_SWIFT" \
        | grep -q 'isSpeakingFlag' && echo "yes" || echo "no")"

check "scheduleRespeak: returns early when not speaking" \
    "yes" "$(awk '/func scheduleRespeak/,/^    \}/' "$SETTINGS_SWIFT" \
        | grep -q 'guard speaking else.*return\|guard.*isSpeakingFlag.*return' \
        && echo "yes" || echo "no")"

# ── Invariant 9: handleHotkey reads flag to decide ──────────────
# handleHotkey must check speaking state before deciding stop vs start.
check "handleHotkey: reads isSpeakingFlag before branching" \
    "yes" "$(awk '/func handleHotkey/,/^    \}/' "$SETTINGS_SWIFT" \
        | grep -q 'isSpeakingFlag' && echo "yes" || echo "no")"

# ── Invariant 10: no direct isSpeakingFlag access outside lock ──
# Global check — total writes to isSpeakingFlag must equal the
# number of writes found inside lock regions.
# Exclude the property declaration (var isSpeakingFlag = false) — that's
# an initializer, not a runtime mutation.
_TOTAL_WRITES=$(grep 'isSpeakingFlag =' "$SETTINGS_SWIFT" \
    | grep -vc 'var isSpeakingFlag')
_LOCKED_WRITES=$(awk '
    /speakLock\.lock/   { locked=1 }
    /speakLock\.unlock/ { locked=0 }
    /isSpeakingFlag =/ && !/var isSpeakingFlag/ && locked { count++ }
    END { print count+0 }
' "$SETTINGS_SWIFT")

check "isSpeakingFlag: total runtime writes == locked writes ($_TOTAL_WRITES)" \
    "$_TOTAL_WRITES" "$_LOCKED_WRITES"

# ── 25. install.command backend choice ────────────────────────────

section "install.command backend choice"

check "install.command has 3-way backend choice dialog" \
    "yes" "$(grep -q 'ElevenLabs Only.*Both.*Local Only' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command maps ElevenLabs Only to elevenlabs backend" \
    "yes" "$(grep -q '_CFG_BACKEND="elevenlabs"' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command maps Both to auto backend" \
    "yes" "$(grep -q '_CFG_BACKEND="auto"' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command maps Local Only to local backend" \
    "yes" "$(grep -q '_CFG_BACKEND="local"' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command: Local Only + install fail exits with error" \
    "yes" "$(awk '/Local Only.*install fail/,/exit 1/' "$SCRIPT_DIR/install.command" \
        | grep -q 'exit 1' && echo "yes" || \
        grep -B2 'exit 1' "$SCRIPT_DIR/install.command" | grep -q 'Local Only' && echo "yes" || echo "no")"

check "install.command: Both + install fail falls back to ElevenLabs" \
    "yes" "$(grep -q 'ElevenLabs will be used instead' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# ── 26. Backend submenu always visible ───────────────────────────

section "Backend submenu always visible"

# rebuildMenu must call buildBackendItems unconditionally (no if-guard
# checking backendsInstalled around it).
_GUARDED_BACKEND=$(awk '
    /backendsInstalled.*==.*"both"/ { in_guard=1 }
    in_guard && /buildBackendItems/ { found=1 }
    in_guard && /\}/ { in_guard=0 }
    END { print (found ? "yes" : "no") }
' "$SETTINGS_SWIFT")

check "rebuildMenu: backend submenu NOT behind backendsInstalled guard" \
    "no" "$_GUARDED_BACKEND"

check "rebuildMenu: buildBackendItems still called" \
    "yes" "$(grep -q 'buildBackendItems' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# ── 27. Guided setup for Local backend ──────────────────────────

section "Guided setup for Local backend"

# pickBackend must check local readiness when selecting "local"
check "pickBackend: handles local backend readiness" \
    "yes" "$(awk '/func pickBackend/,/^    \}/' "$SETTINGS_SWIFT" \
        | grep -q 'local\|Local\|backendsInstalled' && echo "yes" || echo "no")"

# Apple Silicon detection must exist somewhere in the file
check "Swift: Apple Silicon check exists" \
    "yes" "$(grep -q 'arm64\|isAppleSilicon\|utsname' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# A method to run install-local.sh must exist
check "Swift: runInstallLocal method exists" \
    "yes" "$(grep -q 'installLocal\|install-local\|runInstallLocal' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# Install must run on a background queue (not block UI)
check "Swift: local install runs async (background queue)" \
    "yes" "$(awk '/func runInstallLocal/,/^    \}/' "$SETTINGS_SWIFT" \
        | grep -q 'DispatchQueue.*global' && echo "yes" || echo "no")"

# Install result dialog must exist
check "Swift: install result dialog exists" \
    "yes" "$(grep -q 'showInstallResult\|Installation Failed\|Local TTS Installed\|installed.*successfully' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# ── 28. Guided setup for Auto backend ───────────────────────────

section "Guided setup for Auto backend"

# pickBackend must handle the auto case (the else branch)
check "pickBackend: handles auto backend" \
    "yes" "$(awk '/func pickBackend/,/^    \}/' "$SETTINGS_SWIFT" \
        | grep -q 'auto\|hasKey.*hasLocal' && echo "yes" || echo "no")"

# Soft/optional API key prompt for auto (Skip button instead of Cancel)
check "Swift: optional API key dialog exists (Skip button)" \
    "yes" "$(grep -q 'Skip\|optional.*Bool' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# ── 29. Auto shows both voice submenus ──────────────────────────

section "Auto shows both voice submenus"

# When backend is auto, rebuildMenu should show both voice submenus.
# Use grep -A to capture lines after the auto branch.
check "rebuildMenu: auto shows ElevenLabs voice section" \
    "yes" "$(grep -q 'showEl.*=.*auto' "$SETTINGS_SWIFT" && \
        grep -q 'if showEl' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "rebuildMenu: auto shows Local voice section (when installed)" \
    "yes" "$(grep -q 'showLocal.*=.*local\|showLocal.*auto.*isLocalInstalled' "$SETTINGS_SWIFT" && \
        grep -q 'if showLocal' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# ── 30. pickBackend calls scheduleRespeak ────────────────────────

section "pickBackend calls scheduleRespeak"

check "pickBackend: calls scheduleRespeak" \
    "yes" "$(awk '/func pickBackend/,/^    \}/' "$SETTINGS_SWIFT" \
        | grep -q 'scheduleRespeak' && echo "yes" || echo "no")"

# ── 31. Standalone Python download fallback ────────────────────────

section "Standalone Python download fallback"

INSTALL_LOCAL="$SCRIPT_DIR/install-local.sh"

check "install-local.sh: download_python function exists" \
    "yes" "$(grep -q 'download_python' "$INSTALL_LOCAL" && echo "yes" || echo "no")"

check "install-local.sh: SHA256 verification exists" \
    "yes" "$(grep -q 'shasum.*256\|sha256' "$INSTALL_LOCAL" && echo "yes" || echo "no")"

check "install-local.sh: standalone Python URL present" \
    "yes" "$(grep -q 'python-build-standalone' "$INSTALL_LOCAL" && echo "yes" || echo "no")"

check "install-local.sh: falls back to download when find_python fails" \
    "yes" "$(grep -A5 'find_python.*||' "$INSTALL_LOCAL" \
        | grep -q 'download_python' && echo "yes" || echo "no")"

# ── 32. mktemp patterns (macOS requires XXXXXX at end) ─────────
section "mktemp patterns"

# macOS mktemp requires the X template at the very end of the string.
# Suffixes like .tar.gz or .swift after XXXXXX silently fail.
_mktemp_ok="yes"
while IFS= read -r line; do
    if echo "$line" | grep -qE 'mktemp[^)]*X{4,}\.[a-zA-Z]'; then
        _mktemp_ok="no"
        break
    fi
done < <(grep -rn 'mktemp' "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.command 2>/dev/null)

check "no mktemp templates with suffix after XXXXXX" \
    "yes" "$_mktemp_ok"

# ── 33. Local TTS integration (skipped with --fast) ────────────
section "Local TTS integration"

VENV_PY="$HOME/.local/share/speak11/venv/bin/python3"
if [ "${1:-}" = "--fast" ] || [ ! -x "$VENV_PY" ]; then
    printf "  %s  %s\n" "SKIP" "local TTS: venv not installed or --fast mode"
else
    _TTS_TMPD=$(mktemp -d /tmp/speak11_test_tts_XXXXXXXXXX)
    _tts_ok="no"
    if (cd "$_TTS_TMPD" && "$VENV_PY" -m mlx_audio.tts.generate \
            --model mlx-community/Kokoro-82M-bf16 \
            --text "test" \
            --voice af_heart \
            --speed 1.00 \
            --lang_code a \
            --file_prefix speak11 \
            --audio_format wav \
            --join_audio >/dev/null 2>&1) && [ -s "$_TTS_TMPD/speak11.wav" ]; then
        _tts_ok="yes"
    fi
    rm -rf "$_TTS_TMPD"
    check "local TTS generates speak11.wav" "yes" "$_tts_ok"
fi

# ── 34. TTS daemon (tts_server.py) ────────────────────────────
section "TTS daemon"

TTS_SERVER="$SCRIPT_DIR/tts_server.py"

check "tts_server.py exists" \
    "yes" "$([ -f "$TTS_SERVER" ] && echo "yes" || echo "no")"

check "tts_server.py: valid Python syntax" \
    "yes" "$(python3 -c "import ast; ast.parse(open('$TTS_SERVER').read())" 2>/dev/null && echo "yes" || echo "no")"

check "tts_server.py: Unix socket (AF_UNIX)" \
    "yes" "$(grep -q 'AF_UNIX' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: idle timeout logic" \
    "yes" "$(grep -q 'IDLE_TIMEOUT' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: SIGTERM signal handling" \
    "yes" "$(grep -q 'SIGTERM' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: PID file management" \
    "yes" "$(grep -q 'tts_server.pid' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: socket cleanup on shutdown" \
    "yes" "$(grep -q 'os.unlink(SOCKET_PATH)' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: flock prevents multiple daemons" \
    "yes" "$(grep -q 'fcntl.flock' "$TTS_SERVER" && echo "yes" || echo "no")"

check "speak.sh: run_local_tts references daemon socket" \
    "yes" "$(grep -q 'TTS_SOCK' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: daemon fallback to direct invocation" \
    "yes" "$(grep -q 'falling back to direct invocation' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: start_tts_daemon function exists" \
    "yes" "$(grep -q 'start_tts_daemon' "$SPEAK_SH" && echo "yes" || echo "no")"

check "uninstall.command: kills TTS daemon" \
    "yes" "$(grep -q 'tts_server.pid' "$SCRIPT_DIR/uninstall.command" && echo "yes" || echo "no")"

check "tts_server.py: --managed mode support" \
    "yes" "$(grep -q '\-\-managed' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: parent watchdog for orphan detection" \
    "yes" "$(grep -q 'parent_watchdog' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: pipeline warmup" \
    "yes" "$(grep -q 'warmup_pipeline' "$TTS_SERVER" && echo "yes" || echo "no")"

check "install.command: tts_server.py symlinked" \
    "yes" "$(grep -q 'tts_server.py' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "uninstall.command: removes tts_server.py symlink" \
    "yes" "$(grep -q 'tts_server.py' "$SCRIPT_DIR/uninstall.command" && echo "yes" || echo "no")"

check "Speak11.swift: startTTSDaemon method" \
    "yes" "$(grep -q 'startTTSDaemon' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Speak11.swift: stopTTSDaemon method" \
    "yes" "$(grep -q 'stopTTSDaemon' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Speak11.swift: applicationWillTerminate stops daemon" \
    "yes" "$(grep -q 'applicationWillTerminate' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# ── 35. Per-backend speed settings ──────────────────────────────
section "Per-backend speed"

check "speak.sh: LOCAL_SPEED variable defined" \
    "yes" "$(grep -q 'LOCAL_SPEED=' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: LOCAL_SPEED env var saved before config sourcing" \
    "yes" "$(grep -q '_ENV_LOCAL_SPEED=' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: LOCAL_SPEED restored with env var priority" \
    "yes" "$(grep -q '_ENV_LOCAL_SPEED:-' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: SPEED env var saved before config sourcing" \
    "yes" "$(grep -q '_ENV_SPEED=' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: local TTS uses LOCAL_SPEED" \
    "yes" "$(grep -q '_SPEED=\"\$LOCAL_SPEED\"' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: python3 check skipped for local-only mode" \
    "yes" "$(grep -q 'TTS_BACKEND.*!=.*local.*python3' "$SPEAK_SH" && echo "yes" || echo "no")"

check "Speak11.swift: localSpeed config field" \
    "yes" "$(grep -q 'localSpeed' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Speak11.swift: pickLocalSpeed handler" \
    "yes" "$(grep -q 'pickLocalSpeed' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Speak11.swift: LOCAL_SPEED in config save" \
    "yes" "$(grep -q 'LOCAL_SPEED' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Speak11.swift: default local voice is bf_lily" \
    "yes" "$(grep -q 'bf_lily' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "speak.sh: default local voice is bf_lily" \
    "yes" "$(grep -q 'bf_lily' "$SPEAK_SH" && echo "yes" || echo "no")"

check "install.command: default local voice is bf_lily" \
    "yes" "$(grep -q 'bf_lily' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command: LOCAL_SPEED in default config" \
    "yes" "$(grep -q 'LOCAL_SPEED' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "tts_server.py: warmup uses bf_lily" \
    "yes" "$(grep -q 'bf_lily' "$TTS_SERVER" && echo "yes" || echo "no")"

# ── 33. MLX memory management ───────────────────────────────────

section "MLX memory management"

check "tts_server.py: clears MLX metal cache after generation" \
    "yes" "$(grep -q 'mx.metal.clear_cache()' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: runs gc.collect after generation" \
    "yes" "$(grep -q 'gc.collect()' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: imports mlx.core in generate_audio" \
    "yes" "$(grep -q 'import mlx.core' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: deletes segments and audio arrays" \
    "yes" "$(grep -q 'del segments, audio' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: clears cache on error path too" \
    "yes" "$(awk '/except Exception/,/raise/' "$TTS_SERVER" | grep -q 'clear_cache' && echo "yes" || echo "no")"

# ── Summary ──────────────────────────────────────────────────────

printf "\n────────────────────────────────────────────\n"
printf "  %d passed, %d failed\n\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
