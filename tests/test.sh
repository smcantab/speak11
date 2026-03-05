#!/bin/bash
# test.sh — Test suite for Speak11
#
# Usage:
#   bash tests/test.sh                    # all tests (Swift compile included)
#   bash tests/test.sh --fast             # skip slow Swift compile test
#   bash tests/test.sh "normalize"        # run sections matching "normalize"
#   bash tests/test.sh --fast "STATUS"    # fast + filter by "STATUS"
#   bash tests/test.sh --list             # list all section names

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEAK_SH="$SCRIPT_DIR/speak.sh"
SETTINGS_SWIFT="$SCRIPT_DIR/Speak11.swift"
FAST=false
FILTER=""

for arg in "$@"; do
    case "$arg" in
        --fast) FAST=true ;;
        --list)
            grep -oP '(?<=^section ").*(?=")' "$0" 2>/dev/null || \
                grep '^section "' "$0" | sed 's/^section "//;s/"$//'
            exit 0 ;;
        *) FILTER="$arg" ;;
    esac
done

PASS=0
FAIL=0
_SKIP_SECTION=false

# Isolate tests from any real running TTS daemon
export TTS_SOCK="/tmp/speak11_test_nosock_$$"

# ── Helpers ──────────────────────────────────────────────────────

check() {
    $_SKIP_SECTION && return 0
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
    $_SKIP_SECTION && return 0
    local desc="$1" expected_exit="$2"
    shift 2
    local actual_exit=0
    "$@" 2>/dev/null || actual_exit=$?
    check "$desc" "$expected_exit" "$actual_exit"
}

section() {
    if [ -n "$FILTER" ]; then
        case "$1" in
            *"$FILTER"*|*"$(echo "$FILTER" | tr '[:upper:]' '[:lower:]')"*) _SKIP_SECTION=false ;;
            *) _SKIP_SECTION=true; return 0 ;;
        esac
    fi
    printf "\n── %s\n" "$1"
}

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

# ── 2b. Config numeric validation ────────────────────────────────

section "Config numeric validation"

# Structural: speak.sh validates numeric config values
check "speak.sh validates SPEED is numeric" \
    "yes" "$(grep -q '_validate_num.*SPEED' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh validates STABILITY is numeric" \
    "yes" "$(grep -q '_validate_num.*STABILITY' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh validates USE_SPEAKER_BOOST is true/false" \
    "yes" "$(grep -q 'USE_SPEAKER_BOOST.*true.*false\|case.*USE_SPEAKER_BOOST' "$SPEAK_SH" && echo "yes" || echo "no")"

# Functional: invalid SPEED falls back to default
_TMPCONF=$(mktemp)
printf 'SPEED="fast"\n' > "$_TMPCONF"
_result=$(
    _ENV_SPEED=""
    source "$_TMPCONF"
    SPEED="${_ENV_SPEED:-${SPEED:-1.0}}"
    # Simulate validation
    if [[ "$SPEED" =~ ^[0-9]*\.?[0-9]+$ ]]; then echo "$SPEED"; else echo "1.0"; fi
)
check "invalid SPEED falls back to 1.0" "1.0" "$_result"

# Functional: valid SPEED passes through
_result=$(
    SPEED="1.25"
    if [[ "$SPEED" =~ ^[0-9]*\.?[0-9]+$ ]]; then echo "$SPEED"; else echo "1.0"; fi
)
check "valid SPEED passes through" "1.25" "$_result"
rm -f "$_TMPCONF"

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

# calculateRemainingText uses per-sentence offset from STATUS_FILE
check "Swift: calculateRemainingText uses sentence offset for position" \
    "yes" "$(grep -q 'charOffset + Int' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

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
elif ! xcrun swiftc --version &>/dev/null; then
    printf "  SKIP  swiftc not found\n"
else
    TMPBIN=$(mktemp)
    rm -f "$TMPBIN"
    printf "        compiling… (this takes ~15s)\n"
    if xcrun swiftc "$SETTINGS_SWIFT" -o "$TMPBIN" -O 2>/dev/null; then
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

# osascript: log dialog calls, return "Not Now" (user declines local install)
cat > "$_STUBS/osascript" << STUB
#!/bin/bash
case "\$*" in *"volume settings"*) echo "false"; exit 0;; esac
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

# osascript: log dialog calls (ignore volume queries from mute check)
cat > "$_STUBS/osascript" << STUB
#!/bin/bash
case "\$*" in *"volume settings"*) echo "false"; exit 0;; esac
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

# osascript: log dialog calls (ignore volume queries from mute check)
cat > "$_STUBS/osascript" << STUB
#!/bin/bash
case "\$*" in *"volume settings"*) echo "false"; exit 0;; esac
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
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=both SPEAK11_MUTE_CHECKED=1 bash "'"$SPEAK_SH"'"'
check "429 + both → local TTS called as fallback" \
    "yes" "$([ -f "$_MARKERS/mlx_fallback_called" ] && echo "yes" || echo "no")"
check "429 + both → no dialog shown (silent)" \
    "no" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: network failure (curl exits non-zero) + both installed → silent fallback
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
printf '#!/bin/bash\nexit 7\n' > "$_STUBS/curl"   # exit 7 = connection refused
chmod +x "$_STUBS/curl"

check_exit "network failure + both installed → exits 0 (silent fallback)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=both SPEAK11_MUTE_CHECKED=1 bash "'"$SPEAK_SH"'"'
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
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=both SPEAK11_MUTE_CHECKED=1 bash "'"$SPEAK_SH"'"'
check "429 + both + local fails → error dialog shown" \
    "yes" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: network failure + both + local TTS FAILS → error dialog
rm -f "$_LOG"
printf '#!/bin/bash\nexit 7\n' > "$_STUBS/curl"
chmod +x "$_STUBS/curl"

check_exit "network failure + both + local fails → exits 1" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto TTS_BACKENDS_INSTALLED=both SPEAK11_MUTE_CHECKED=1 bash "'"$SPEAK_SH"'"'
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

# phonemizer-fork is required for espeak fallback (OOV word pronunciation).
# The upstream "phonemizer" package is missing set_data_path(), which makes
# misaki's EspeakFallback fail silently — unknown words get dropped.
check "install-local.sh installs phonemizer-fork (not upstream phonemizer)" \
    "yes" "$(grep -q 'phonemizer-fork' "$SCRIPT_DIR/install-local.sh" && echo "yes" || echo "no")"

check "install-local.sh does not install upstream phonemizer (only -fork)" \
    "0" "$(grep 'pip install' "$SCRIPT_DIR/install-local.sh" | grep -oE 'phonemizer[^ ]*' | grep -cxv 'phonemizer-fork')"

check "install-local.sh upgrades existing venvs from phonemizer to phonemizer-fork" \
    "yes" "$(grep -q 'pip.*uninstall.*phonemizer' "$SCRIPT_DIR/install-local.sh" && \
             grep -q 'pip.*install phonemizer-fork' "$SCRIPT_DIR/install-local.sh" && echo "yes" || echo "no")"

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

# play_audio always writes 4-line STATUS_FILE (offset defaults to 0)
check "play_audio: writes offset and len to STATUS_FILE" \
    "yes" "$(awk '/^play_audio\(\)/,/^}/' "$SPEAK_SH" | grep -q '${1:-0}.*${2:-0}' && echo "yes" || echo "no")"

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

check "STATUS_FILE has four lines (epoch, duration, offset, len)" \
    "4" "$([ -f "$_TESTTMP/speak11_status" ] && wc -l < "$_TESTTMP/speak11_status" | tr -d ' ' || echo "0")"

# First line should be a recent epoch timestamp (within last 60 seconds)
# Epoch may be fractional (e.g. 1741234567.890) — truncate to integer for arithmetic
_STATUS_EPOCH=$(head -1 "$_TESTTMP/speak11_status" 2>/dev/null || echo "0")
_STATUS_EPOCH=${_STATUS_EPOCH%%.*}
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
case "\$*" in *"volume settings"*) echo "false"; exit 0;; esac
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
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto SPEAK11_MUTE_CHECKED=1 bash "'"$SPEAK_SH"'"'
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
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=auto SPEAK11_MUTE_CHECKED=1 bash "'"$SPEAK_SH"'"'
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

# ── 25b. Quarantine stripping ─────────────────────────────────────

section "Quarantine stripping"

# Structural: install.command strips quarantine from source directory
check "strips quarantine from source directory before compilation" \
    "yes" "$(grep -q 'xattr.*quarantine.*SCRIPT_DIR' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# ── 25c. CLT auto-update logic ────────────────────────────────────

section "CLT auto-update logic"

# Structural: install.command checks CLT version against macOS version
check "compares CLT major version to macOS major version" \
    "yes" "$(grep -q 'sw_vers.*productVersion' "$SCRIPT_DIR/install.command" && \
             grep -q 'pkgutil.*CLTools_Executables' "$SCRIPT_DIR/install.command" && \
             grep -q '_clt_major.*_os_major' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# Structural: uses softwareupdate --install for the update
check "uses softwareupdate --install to update CLT" \
    "yes" "$(grep -q 'softwareupdate --install' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# Structural: uses xcrun swiftc (not bare swiftc) for compilation
check "uses xcrun swiftc for compilation" \
    "yes" "$(grep -q 'xcrun swiftc.*Speak11.swift' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# Structural: logs errors to install.log instead of /dev/null
check "swiftc stderr goes to log file" \
    "yes" "$(grep -q 'xcrun swiftc.*>>.*LOG_FILE' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install-local.sh output goes to log file" \
    "yes" "$(grep -q 'install-local.sh.*>>.*LOG_FILE' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# Simulation: test the version comparison logic with mocked commands
_CLT_SIM_DIR=$(mktemp -d)

# Mock sw_vers returning macOS 26
cat > "$_CLT_SIM_DIR/sw_vers" << 'MOCKSW'
#!/bin/bash
echo "26.3"
MOCKSW
chmod +x "$_CLT_SIM_DIR/sw_vers"

# Mock pkgutil returning old CLT version 15
cat > "$_CLT_SIM_DIR/pkgutil" << 'MOCKPKG'
#!/bin/bash
echo "package-id: com.apple.pkg.CLTools_Executables"
echo "version: 15.0.0.0.1.1234567890"
MOCKPKG
chmod +x "$_CLT_SIM_DIR/pkgutil"

# Extract and test the version comparison
_clt_os_major=$("$_CLT_SIM_DIR/sw_vers" -productVersion | cut -d. -f1)
_clt_clt_major=$("$_CLT_SIM_DIR/pkgutil" --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null \
    | awk '/version:/{print $2}' | cut -d. -f1)

check "sim: detects version mismatch (os=26, clt=15)" \
    "mismatch" "$( [ "$_clt_clt_major" != "$_clt_os_major" ] && echo "mismatch" || echo "match")"

# Mock pkgutil returning matching version
cat > "$_CLT_SIM_DIR/pkgutil" << 'MOCKPKG2'
#!/bin/bash
echo "package-id: com.apple.pkg.CLTools_Executables"
echo "version: 26.2.0.0.1.1764812424"
MOCKPKG2
chmod +x "$_CLT_SIM_DIR/pkgutil"

_clt_clt_major2=$("$_CLT_SIM_DIR/pkgutil" --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null \
    | awk '/version:/{print $2}' | cut -d. -f1)

check "sim: accepts matching version (os=26, clt=26)" \
    "match" "$( [ "$_clt_clt_major2" != "$_clt_os_major" ] && echo "mismatch" || echo "match")"

# Mock pkgutil returning nothing (CLT not installed)
cat > "$_CLT_SIM_DIR/pkgutil" << 'MOCKPKG3'
#!/bin/bash
echo "No receipt for 'com.apple.pkg.CLTools_Executables' found at '/'." >&2
exit 1
MOCKPKG3
chmod +x "$_CLT_SIM_DIR/pkgutil"

_clt_clt_major3=$("$_CLT_SIM_DIR/pkgutil" --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null \
    | awk '/version:/{print $2}' | cut -d. -f1 || true)

check "sim: triggers update when CLT missing" \
    "update" "$( [ -z "$_clt_clt_major3" ] && echo "update" || echo "skip")"

rm -rf "$_CLT_SIM_DIR"

# Structural: installer fixes xcrun when xcode-select points to wrong path
check "fixes xcrun by switching xcode-select to CLT path" \
    "yes" "$(grep -q 'xcrun swiftc --version' "$SCRIPT_DIR/install.command" && \
             grep -q 'xcode-select --switch.*CommandLineTools' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# ── 25d. install.command failure handling ─────────────────────────

section "install.command failure handling"

# Every osascript $(...) call must have || true to prevent set -e abort
_osa_calls=$(grep -c '=$(osascript' "$SCRIPT_DIR/install.command")
_osa_guarded=$(grep '=$(osascript' "$SCRIPT_DIR/install.command" | grep -c '|| true)')
check "all osascript \$() calls have || true" \
    "$_osa_calls" "$_osa_guarded"

# Error messages interpolated into osascript must be sanitized (tr '"\\')
check "mlx error sanitized before osascript" \
    "yes" "$(grep '_mlx_err=.*| tr ' "$SCRIPT_DIR/install.command" | grep -q '"' && echo "yes" || echo "no")"

check "swift error sanitized before osascript" \
    "yes" "$(grep '_swift_err=.*| tr ' "$SCRIPT_DIR/install.command" | grep -q '"' && echo "yes" || echo "no")"

# security keychain failure must not abort (uses if instead of bare command)
check "keychain failure handled gracefully" \
    "yes" "$(grep -q 'if security add-generic-password' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# open $APP_BUNDLE must have || true
check "open app bundle has || true" \
    "yes" "$(grep -q 'open "\$APP_BUNDLE" || true' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# Error dialog osascripts (display dialog with icon stop/caution) must have || true
_err_dialogs=$(grep -c 'icon \(stop\|caution\)' "$SCRIPT_DIR/install.command")
_err_guarded=$(grep 'icon \(stop\|caution\)' "$SCRIPT_DIR/install.command" | grep -c '|| true')
check "all error dialogs have || true" \
    "$_err_dialogs" "$_err_guarded"

# Error messages reference the log file
check "mlx error dialog references log file" \
    "yes" "$(grep -A1 'Could not install local TTS' "$SCRIPT_DIR/install.command" | grep -q 'install.log' && echo "yes" || echo "no")"

check "swift error dialog references log file" \
    "yes" "$(grep -A1 'Could not compile' "$SCRIPT_DIR/install.command" | grep -q 'install.log' && echo "yes" || echo "no")"

# Simulation: error message sanitization strips quotes
_test_err='ERROR: Could not find "libfoo.dylib" in C:\path'
_sanitized=$(echo "$_test_err" | tr '"\\' "'/")
check "sim: quotes removed from error message" \
    "no" "$(echo "$_sanitized" | grep -q '"' && echo "yes" || echo "no")"
check "sim: backslashes removed from error message" \
    "no" "$(echo "$_sanitized" | grep -q '\\\\' && echo "yes" || echo "no")"

# ── 25e. install.command robustness ──────────────────────────────

section "install.command robustness"

# §1: Config must be written BEFORE the app is opened (race condition)
# The config write block (case $BACKEND_CHOICE) must appear before open "$APP_BUNDLE"
_cfg_line=$(grep -n '^case.*BACKEND_CHOICE' "$SCRIPT_DIR/install.command" | head -1 | cut -d: -f1)
_open_line=$(grep -n 'open "\$APP_BUNDLE"' "$SCRIPT_DIR/install.command" | head -1 | cut -d: -f1)
check "§1: config written before app launch" \
    "yes" "$( [ -n "$_cfg_line" ] && [ -n "$_open_line" ] && [ "$_cfg_line" -lt "$_open_line" ] && echo "yes" || echo "no")"

# §2: CLT update failure produces a warning when compilation was requested
check "§2: CLT failure warning when settings_result=Install" \
    "yes" "$(grep -A5 '_clt_major.*_os_major' "$SCRIPT_DIR/install.command" | grep -q 'could not be updated\|Command Line Tools.*warning\|settings_result' && echo "yes" || echo "no")"

# §3: softwareupdate admin prompt includes 'with prompt' for context
check "§3: admin password prompt has 'with prompt'" \
    "yes" "$(grep 'softwareupdate --install' "$SCRIPT_DIR/install.command" | grep -q 'with prompt' && echo "yes" || echo "no")"

# §4: Single-instance guard using mkdir lock
check "§4: single-instance lock directory created" \
    "yes" "$(grep -q 'mkdir.*\$_LOCKDIR\|mkdir.*speak11_install' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "§4: lock directory cleaned up in cleanup/trap" \
    "yes" "$(grep -q 'rm.*\$_LOCKDIR\|rm.*speak11_install' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "§4: stale lock detected via PID check" \
    "yes" "$(grep -q 'kill -0.*holder\|cat.*lock.*pid' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# §5: Log file is appended, not truncated (preserves previous run errors)
check "§5: log file not truncated (no : > \$_LOG_FILE)" \
    "no" "$(grep -q '^: > "\$_LOG_FILE"' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "§5: log file has run separator" \
    "yes" "$(grep -q 'Install run:' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# §6: Error extraction uses grep for actual errors, not just tail
check "§6: mlx error extraction uses grep for error patterns" \
    "yes" "$(grep '_mlx_err=' "$SCRIPT_DIR/install.command" | grep -q 'grep' && echo "yes" || echo "no")"

# §7: Cleanup closes the installer's specific Terminal window, not front window
check "§7: Terminal window ID captured at startup" \
    "yes" "$(grep -q '_TERM_WINDOW_ID' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "§7: cleanup closes specific window by ID" \
    "yes" "$(grep -q 'whose id is' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# §8: Fallback done dialog (no settings app) acknowledges partial install
check "§8: fallback done mentions missing menu bar app on compile failure" \
    "yes" "$(awk '/compile_ok.*ne 0/,/fi/' "$SCRIPT_DIR/install.command" \
        | grep -q 'menu bar app\|could not be compiled\|without settings app' \
        && echo "yes" || echo "no")"

# §9: Re-install preserves user-customized config values
check "§9: existing config preserved on re-install" \
    "yes" "$(grep -q 'if.*-f.*config.*existing\|Existing.*config\|existing settings preserved\|preserve.*config\|read.*line.*config' "$SCRIPT_DIR/install.command" \
        && echo "yes" || echo "no")"

# §9 simulation: merge logic updates backend but preserves other fields
_SIM_CONFIG=$(mktemp)
cat > "$_SIM_CONFIG" << 'SIMCFG'
TTS_BACKEND="local"
TTS_BACKENDS_INSTALLED="local"
VOICE_ID="custom-voice-id"
MODEL_ID="eleven_multilingual_v2"
STABILITY="0.80"
SIMILARITY_BOOST="0.30"
STYLE="0.60"
USE_SPEAKER_BOOST="false"
SPEED="1.3"
LOCAL_VOICE="am_adam"
LOCAL_SPEED="1.2"
SIMCFG

# Simulate the merge: update backend fields, preserve rest
_SIM_OUT=$(mktemp)
_CFG_BACKEND="auto"
_CFG_INSTALLED="both"
while IFS= read -r line; do
    case "$line" in
        TTS_BACKEND=*)           echo "TTS_BACKEND=\"$_CFG_BACKEND\"" ;;
        TTS_BACKENDS_INSTALLED=*) echo "TTS_BACKENDS_INSTALLED=\"$_CFG_INSTALLED\"" ;;
        *)                        echo "$line" ;;
    esac
done < "$_SIM_CONFIG" > "$_SIM_OUT"
check "§9 sim: backend updated" \
    "auto" "$(grep '^TTS_BACKEND=' "$_SIM_OUT" | cut -d'"' -f2)"
check "§9 sim: backends_installed updated" \
    "both" "$(grep '^TTS_BACKENDS_INSTALLED=' "$_SIM_OUT" | cut -d'"' -f2)"
check "§9 sim: voice preserved" \
    "custom-voice-id" "$(grep '^VOICE_ID=' "$_SIM_OUT" | cut -d'"' -f2)"
check "§9 sim: speed preserved" \
    "1.3" "$(grep '^SPEED=' "$_SIM_OUT" | cut -d'"' -f2)"
check "§9 sim: local_voice preserved" \
    "am_adam" "$(grep '^LOCAL_VOICE=' "$_SIM_OUT" | cut -d'"' -f2)"
rm -f "$_SIM_CONFIG" "$_SIM_OUT"

# §12: No set +e / set -e toggles — uses if/else for error handling
check "§12: no set +e toggles in install.command" \
    "0" "$(grep -c 'set +e' "$SCRIPT_DIR/install.command")"

# §13: Terminal window is NOT minimized during install (stays visible)
check "§13: Terminal not minimized during install" \
    "yes" "$(grep -q 'miniaturized.*true' "$SCRIPT_DIR/install.command" && echo "no" || echo "yes")"

# §14: Uninstaller copied to install directory
check "§14: uninstall.command copied to install dir" \
    "yes" "$(grep -q 'cp.*uninstall.command' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# §16: Login item check before adding (no duplicates)
check "§16: login item checked before adding" \
    "yes" "$(grep -q 'login item.*Speak11\|every login item' "$SCRIPT_DIR/install.command" \
        && grep 'login item' "$SCRIPT_DIR/install.command" | grep -q 'get\|name of\|count\|exists' && echo "yes" || echo "no")"

# §4 simulation: mkdir lock atomicity
_LOCKDIR=$(mktemp -d)/speak11_install.lock
mkdir "$_LOCKDIR" 2>/dev/null
echo "$$" > "$_LOCKDIR/pid"
# Second attempt should fail
check "§4 sim: mkdir lock rejects second instance" \
    "no" "$(mkdir "$_LOCKDIR" 2>/dev/null && echo "yes" || echo "no")"
# Stale lock with dead PID should be claimable
echo "99999" > "$_LOCKDIR/pid"
_stale_claimable="no"
if ! mkdir "$_LOCKDIR" 2>/dev/null; then
    _holder_pid=$(cat "$_LOCKDIR/pid" 2>/dev/null)
    if [ -n "$_holder_pid" ] && ! kill -0 "$_holder_pid" 2>/dev/null; then
        rm -rf "$_LOCKDIR"
        mkdir "$_LOCKDIR" 2>/dev/null && _stale_claimable="yes"
    fi
fi
check "§4 sim: stale lock (dead PID) can be reclaimed" \
    "yes" "$_stale_claimable"
rm -rf "$(dirname "$_LOCKDIR")"

# §5 simulation: log append preserves previous content
_SIM_LOG=$(mktemp)
echo "PREVIOUS RUN ERROR: something failed" > "$_SIM_LOG"
# Simulate the append logic
if [ -f "$_SIM_LOG" ] && [ "$(stat -f%z "$_SIM_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -500 "$_SIM_LOG" > "$_SIM_LOG.tmp" && mv "$_SIM_LOG.tmp" "$_SIM_LOG"
fi
printf '\n══ Install run: %s ══\n\n' "$(date)" >> "$_SIM_LOG"
echo "NEW RUN OUTPUT" >> "$_SIM_LOG"
check "§5 sim: previous log content preserved" \
    "yes" "$(grep -q 'PREVIOUS RUN ERROR' "$_SIM_LOG" && echo "yes" || echo "no")"
check "§5 sim: run separator present" \
    "yes" "$(grep -q 'Install run:' "$_SIM_LOG" && echo "yes" || echo "no")"
rm -f "$_SIM_LOG"

# §6 simulation: error grep extracts actual errors
_SIM_LOG2=$(mktemp)
cat > "$_SIM_LOG2" << 'SIMLOG'
Collecting mlx-audio
  Downloading mlx-audio-0.1.0.tar.gz (1.2 MB)
Building wheels for collected packages: mlx-audio
  Building wheel for mlx-audio (setup.py): started
ERROR: Could not find a version of scipy that satisfies the requirement
ERROR: No matching distribution found for scipy>=1.10
SIMLOG
_grep_err=$(grep -iE '(^ERROR|^fatal|exception|failed|not found|no matching)' "$_SIM_LOG2" \
    | tail -3 | tr '"\\' "'/" | head -c 500)
check "§6 sim: grep extracts ERROR lines, not download progress" \
    "yes" "$(echo "$_grep_err" | grep -q 'scipy' && echo "yes" || echo "no")"
check "§6 sim: grep skips non-error lines" \
    "no" "$(echo "$_grep_err" | grep -q 'Downloading' && echo "yes" || echo "no")"
rm -f "$_SIM_LOG2"

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

    # EspeakFallback must be active (phonemizer-fork + espeakng_loader).
    # Without it, out-of-vocabulary words like proper nouns are silently dropped.
    _espeak_ok="no"
    if "$VENV_PY" -c "
from misaki.espeak import EspeakFallback
fb = EspeakFallback(british=True)
" 2>/dev/null; then
        _espeak_ok="yes"
    fi
    check "EspeakFallback initializes (OOV words handled)" "yes" "$_espeak_ok"

    # Verify proper nouns that are NOT in misaki's dictionary get phonemized
    # (not dropped). "Frum" is the canonical test case.
    _oov_ok="no"
    _oov_result=$("$VENV_PY" -c "
from misaki.en import G2P
from misaki.espeak import EspeakFallback
fb = EspeakFallback(british=True)
g2p = G2P(trf=False, british=True, fallback=fb)
_, tokens = g2p('David Frum said hello.')
dropped = [t.text for t in tokens if t.phonemes is None and t.text.strip() not in '.,;:!?']
print('dropped:' + ','.join(dropped) if dropped else 'ok')
" 2>/dev/null)
    [ "$_oov_result" = "ok" ] && _oov_ok="yes"
    check "OOV proper nouns phonemized (not dropped)" "yes" "$_oov_ok"
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

check "install.command: copies speak.sh" \
    "yes" "$(grep -q 'cp -f.*speak.sh' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command: copies tts_server.py" \
    "yes" "$(grep -q 'cp -f.*tts_server.py' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command: copies install-local.sh" \
    "yes" "$(grep -q 'cp -f.*install-local.sh' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command: no symlinks (uses cp not ln)" \
    "yes" "$(grep -q 'ln -s' "$SCRIPT_DIR/install.command" && echo "no" || echo "yes")"

check "uninstall.command: removes tts_server.py" \
    "yes" "$(grep -q 'tts_server.py' "$SCRIPT_DIR/uninstall.command" && echo "yes" || echo "no")"

check "uninstall.command: removes install-local.sh" \
    "yes" "$(grep -q 'install-local.sh' "$SCRIPT_DIR/uninstall.command" && echo "yes" || echo "no")"

check "Speak11.swift: startTTSDaemon method" \
    "yes" "$(grep -q 'startTTSDaemon' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Speak11.swift: stopTTSDaemon method" \
    "yes" "$(grep -q 'stopTTSDaemon' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Speak11.swift: applicationWillTerminate stops daemon" \
    "yes" "$(grep -q 'applicationWillTerminate' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Speak11.swift: applicationWillTerminate kills current process" \
    "yes" "$(awk '/applicationWillTerminate/,/^    }/' "$SETTINGS_SWIFT" | grep -q 'killCurrentProcess' && echo "yes" || echo "no")"

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

# python3 check was removed (json_encode is pure bash; split_sentences has its own fallback)
check "speak.sh: no hard exit for missing python3" \
    "0" "$(grep -c 'command -v python3.*exit 1' "$SPEAK_SH" || true)"

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

# gc/cache cleanup moved from generate_audio to handle_client (idle time)
check "tts_server.py: gc.collect in handle_client (after response)" \
    "yes" "$(grep -q 'gc.collect()' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: mx.metal.clear_cache in handle_client" \
    "yes" "$(grep -q 'mx.metal.clear_cache()' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: deletes segments and audio arrays" \
    "yes" "$(grep -q 'del segments, audio' "$TTS_SERVER" && echo "yes" || echo "no")"

# ── 34. Generation cancellation on client disconnect ─────────────

section "Generation cancellation"

check "tts_server.py: CancelledError exception class" \
    "yes" "$(grep -q 'class CancelledError' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: generate_audio accepts cancel_check parameter" \
    "yes" "$(grep -q 'def generate_audio.*cancel_check' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: cancel_check called between segments" \
    "yes" "$(awk '/for result in results/,/segments.append/' "$TTS_SERVER" | grep -q 'cancel_check' && echo "yes" || echo "no")"

check "tts_server.py: raises CancelledError on disconnect" \
    "yes" "$(grep -q 'raise CancelledError' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: _client_gone helper uses select" \
    "yes" "$(grep -q 'def _client_gone' "$TTS_SERVER" && grep -q 'select.select' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: handle_client passes cancel_check lambda" \
    "yes" "$(grep -q 'cancel_check=lambda' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: CancelledError caught in handle_client" \
    "yes" "$(grep -q 'except CancelledError' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: cancelled generation is logged" \
    "yes" "$(grep -q 'generation cancelled' "$TTS_SERVER" && echo "yes" || echo "no")"

# ── 35. Threaded client handling ─────────────────────────────────

section "Threaded client handling"

check "tts_server.py: clients handled in threads" \
    "yes" "$(grep -q 'threading.Thread(target=handle_client' "$TTS_SERVER" && echo "yes" || echo "no")"

check "tts_server.py: client threads are daemon threads" \
    "yes" "$(grep -q 'daemon=True' "$TTS_SERVER" && echo "yes" || echo "no")"

# ── 36. Orphaned temp dir cleanup ────────────────────────────────

section "Orphaned temp dir cleanup"

check "tts_server.py: cleans up speak11_tts_ temp dirs on startup" \
    "yes" "$(grep -q 'speak11_tts_' "$TTS_SERVER" && grep -q 'shutil.rmtree' "$TTS_SERVER" && echo "yes" || echo "no")"

# ── 37. Unicode sanitization ────────────────────────────────────

section "Unicode sanitization"

check "speak.sh: sanitizes text with iconv before TTS" \
    "yes" "$(grep -q 'iconv -f UTF-8 -t UTF-8//IGNORE' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: iconv runs after reading text, before save" \
    "yes" "$(awk '/Strip invalid Unicode/,/Save text for live/' "$SPEAK_SH" | grep 'iconv' >/dev/null 2>&1 && echo "yes" || echo "no")"

check "iconv: preserves normal ASCII" \
    "Hello world" "$(printf 'Hello world' | iconv -f UTF-8 -t UTF-8//IGNORE)"

check "iconv: preserves accented characters" \
    "café résumé" "$(printf 'caf\xc3\xa9 r\xc3\xa9sum\xc3\xa9' | iconv -f UTF-8 -t UTF-8//IGNORE)"

check "iconv: preserves CJK characters" \
    "$(printf '\xe4\xb8\xad\xe6\x96\x87')" "$(printf '\xe4\xb8\xad\xe6\x96\x87' | iconv -f UTF-8 -t UTF-8//IGNORE)"

check "iconv: strips unpaired surrogates" \
    "ab" "$(printf 'a\xed\xb3\x95b' | iconv -f UTF-8 -t UTF-8//IGNORE)"

check "iconv: strips invalid bytes" \
    "ab" "$(printf 'a\xfe\xffb' | iconv -f UTF-8 -t UTF-8//IGNORE)"

check "iconv: empty string passes through" \
    "" "$(printf '' | iconv -f UTF-8 -t UTF-8//IGNORE)"

# ── 38. Mute check ──────────────────────────────────────────────

section "Mute check"

check "speak.sh: checks mute status before TTS" \
    "yes" "$(grep -q 'output muted of (get volume settings)' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: mute dialog offers Unmute & Play" \
    "yes" "$(grep -q 'Unmute & Play' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: unmutes system audio on confirmation" \
    "yes" "$(grep -q 'set volume without output muted' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: mute check exits on Cancel" \
    "yes" "$(awk '/MUTE_CHECKED/,/exit 0/' "$SPEAK_SH" | grep -q 'exit 0' && echo "yes" || echo "no")"

# ── 39. Sentence-by-sentence generation ──────────────────────────

section "Sentence-by-sentence generation"

check "speak.sh: split_sentences function exists" \
    "yes" "$(grep -q 'split_sentences()' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: split_sentences uses regex on sentence boundaries" \
    "yes" "$(grep -q 're.split' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: run_elevenlabs_tts function exists" \
    "yes" "$(grep -q 'run_elevenlabs_tts()' "$SPEAK_SH" && echo "yes" || echo "no")"

# Pipeline loops parse offset/len from split_sentences and pass to play_audio
check "speak.sh: local loop passes sentence offset to play_audio" \
    "yes" "$(awk '/TTS_BACKEND.*=.*local/,/^else/' "$SPEAK_SH" | grep -q 'play_audio.*_OFFSET.*_SENT_LEN' && echo "yes" || echo "no")"

check "speak.sh: cloud loop passes sentence offset to play_audio" \
    "yes" "$(awk '/ElevenLabs.*cloud/,/^fi/' "$SPEAK_SH" | grep -q 'play_audio.*_OFFSET.*_SENT_LEN' && echo "yes" || echo "no")"

# Functional tests for sentence splitting
_SPLIT_PY="${VENV_PYTHON:-python3}"
[ -x "$_SPLIT_PY" ] || _SPLIT_PY=python3

_split_count() {
    "$_SPLIT_PY" -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
parts = re.split(r'(?<=[.!?])\s+', text)
c=0
for p in parts:
    if p.strip(): c+=1
print(c)
" <<< "$1" 2>/dev/null
}

check "split: single sentence unchanged" \
    "Hello world." "$("$_SPLIT_PY" -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
parts = re.split(r'(?<=[.!?])\s+', text)
for p in parts:
    p = p.strip()
    if p: print(p)
" <<< "Hello world.")"

check "split: two sentences produce two lines" \
    "2" "$(_split_count "First sentence. Second sentence.")"

check "split: preserves text within sentences" \
    "First sentence." "$("$_SPLIT_PY" -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
parts = re.split(r'(?<=[.!?])\s+', text)
for p in parts:
    p = p.strip()
    if p: print(p); break
" <<< "First sentence. Second sentence.")"

check "split: handles question marks" \
    "2" "$(_split_count "What time is it? It is noon.")"

check "split: handles exclamation marks" \
    "2" "$(_split_count "Wow! That is great.")"

check "split: no split mid-sentence" \
    "1" "$(_split_count "Hello world without punctuation")"

# ── 40. PID and toggle mechanism ─────────────────────────────────

section "PID and toggle mechanism"

check "speak.sh: stores own PID in PID file" \
    "yes" "$(grep -q 'echo "\$\$" > "\$PID_FILE"' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: cleanup kills PLAY_PID" \
    "yes" "$(grep -q 'kill "\$PLAY_PID"' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: play_audio does NOT write to PID file" \
    "no" "$(awk '/^play_audio\(\)/,/^}/' "$SPEAK_SH" | grep -q 'PID_FILE' && echo "yes" || echo "no")"

check "speak.sh: toggle reads PID file and kills process" \
    "yes" "$(grep -q 'kill "\$OLD_PID"' "$SPEAK_SH" && echo "yes" || echo "no")"

# ── 41. Audio pipeline (overlapping generation and playback) ──────

section "Audio pipeline (overlapping generation and playback)"

# play_audio must be non-blocking (start afplay, don't wait)
check "play_audio is non-blocking (no wait inside)" \
    "0" "$(awk '/^play_audio\(\)/,/^}/' "$SPEAK_SH" | grep -c 'wait')"

# wait_audio function must exist
check "wait_audio() defined" \
    "yes" "$(grep -q '^wait_audio()' "$SPEAK_SH" && echo "yes" || echo "no")"

# wait_audio must wait for PLAY_PID
check "wait_audio waits for PLAY_PID" \
    "yes" "$(awk '/^wait_audio\(\)/,/^}/' "$SPEAK_SH" | grep -q 'wait.*PLAY_PID' && echo "yes" || echo "no")"

# Pipeline: previous temp file tracking
check "_PREV_TMP_FILE initialized" \
    "yes" "$(grep -q '_PREV_TMP_FILE=""' "$SPEAK_SH" && echo "yes" || echo "no")"

check "_PREV_TMP_DIR initialized" \
    "yes" "$(grep -q '_PREV_TMP_DIR=""' "$SPEAK_SH" && echo "yes" || echo "no")"

# Cleanup must handle previous temp files (from the pipeline)
check "cleanup removes _PREV_TMP_FILE" \
    "yes" "$(awk '/^cleanup\(\)/,/^}/' "$SPEAK_SH" | grep -q '_PREV_TMP_FILE' && echo "yes" || echo "no")"

check "cleanup removes _PREV_TMP_DIR" \
    "yes" "$(awk '/^cleanup\(\)/,/^}/' "$SPEAK_SH" | grep -q '_PREV_TMP_DIR' && echo "yes" || echo "no")"

# Local sentence loop: wait_audio before play_audio (pipeline pattern)
_LOCAL_LOOP=$(awk '/TTS_BACKEND.*=.*local/,/^else/' "$SPEAK_SH")
check "local loop: calls wait_audio" \
    "yes" "$(echo "$_LOCAL_LOOP" | grep -q 'wait_audio' && echo "yes" || echo "no")"

check "local loop: wait_audio before play_audio" \
    "yes" "$(echo "$_LOCAL_LOOP" | awk '/wait_audio/{found=1} /play_audio/{if(found) {print "yes"; exit}}' | head -1)"

check "local loop: final wait_audio after loop" \
    "yes" "$(awk '/done <<< "\$_SENTENCES"/,/TEXT="\$_SAVED_TEXT"/' "$SPEAK_SH" | grep -q 'wait_audio' && echo "yes" || echo "no")"

# Cloud sentence loop: wait_audio before play_audio (pipeline pattern)
_CLOUD_LOOP=$(awk '/ElevenLabs.*cloud/,/done <<< "\$_SENTENCES"/' "$SPEAK_SH")
check "cloud loop: calls wait_audio" \
    "yes" "$(echo "$_CLOUD_LOOP" | grep -q 'wait_audio' && echo "yes" || echo "no")"

check "cloud loop: wait_audio before play_audio" \
    "yes" "$(echo "$_CLOUD_LOOP" | awk '/wait_audio/{found=1} /play_audio/{if(found) {print "yes"; exit}}' | head -1)"

check "cloud loop: final wait_audio after loop" \
    "yes" "$(awk '/done <<< "\$_SENTENCES"/{n++} n==2,/\$_FIRST/{if(/wait_audio/){print "yes"; exit}}' "$SPEAK_SH" | head -1)"

# Fallback paths must call wait_audio after play_audio
# (network failure fallback, 429 fallback, install-local fallback)
_FALLBACK_SECTION=$(awk '/first sentence failed/,/^fi$/' "$SPEAK_SH")
_FALLBACK_PLAY_COUNT=$(echo "$_FALLBACK_SECTION" | grep -c 'play_audio' || true)
_FALLBACK_WAIT_COUNT=$(echo "$_FALLBACK_SECTION" | grep -c 'wait_audio' || true)
check "fallback paths: wait_audio after every play_audio" \
    "yes" "$([ "$_FALLBACK_PLAY_COUNT" -gt 0 ] && [ "$_FALLBACK_WAIT_COUNT" -ge "$_FALLBACK_PLAY_COUNT" ] && echo "yes" || echo "no")"

# Previous temp file cleanup in loops
check "local loop: cleans up _PREV_TMP_FILE" \
    "yes" "$(echo "$_LOCAL_LOOP" | grep -q '_PREV_TMP_FILE' && echo "yes" || echo "no")"

check "cloud loop: cleans up _PREV_TMP_FILE" \
    "yes" "$(echo "$_CLOUD_LOOP" | grep -q '_PREV_TMP_FILE' && echo "yes" || echo "no")"

# ── 42. Daemon generation lock (thread safety) ──────────────────

section "Daemon generation lock"

TTS_SERVER="$SCRIPT_DIR/tts_server.py"

check "daemon defines generation_lock" \
    "yes" "$(grep -q 'generation_lock' "$TTS_SERVER" && echo "yes" || echo "no")"

check "daemon uses threading.Lock for generation" \
    "yes" "$(grep -q 'threading.Lock' "$TTS_SERVER" && echo "yes" || echo "no")"

check "daemon wraps generate_audio with lock" \
    "yes" "$(grep -q 'with generation_lock' "$TTS_SERVER" && echo "yes" || echo "no")"

# ── 43. Signal handling and cleanup robustness ───────────────────

section "Signal handling and cleanup robustness"

# cleanup() must disable set -e (bash 3.2 trap quirk)
check "cleanup disables set -e" \
    "yes" "$(awk '/^cleanup\(\)/,/^}/' "$SPEAK_SH" | grep -q 'set +e' && echo "yes" || echo "no")"

# cleanup handles empty PLAY_PID (guarded by -n)
check "cleanup guards PLAY_PID with -n" \
    "yes" "$(awk '/^cleanup\(\)/,/^}/' "$SPEAK_SH" | grep -q '\[ -n "\$PLAY_PID" \]' && echo "yes" || echo "no")"

# Separate traps: EXIT for normal cleanup, INT/TERM for signal cleanup + explicit exit
# (bash resumes execution after a trap handler unless the handler calls exit)
check "trap cleanup EXIT" \
    "yes" "$(grep -q 'trap cleanup EXIT$' "$SPEAK_SH" && echo "yes" || echo "no")"
check "trap INT exits 130" \
    "yes" "$(grep -q "trap 'cleanup; exit 130' INT" "$SPEAK_SH" && echo "yes" || echo "no")"
check "trap TERM exits 143" \
    "yes" "$(grep -q "trap 'cleanup; exit 143' TERM" "$SPEAK_SH" && echo "yes" || echo "no")"

# cleanup only removes PID_FILE if it's ours (prevents clobbering a new instance)
check "cleanup conditionally removes own PID_FILE" \
    "yes" "$(awk '/^cleanup\(\)/,/^}/' "$SPEAK_SH" | grep -q 'cat "\$PID_FILE".*\$\$' && echo "yes" || echo "no")"

# ── 44. set -e containment ──────────────────────────────────────

section "set -e containment"

# run_elevenlabs_tts must NOT leak set -e to the global scope.
# The script has no global set -e, so the function must not call set -e.
_EL_FUNC=$(awk '/^run_elevenlabs_tts\(\)/,/^}/' "$SPEAK_SH")
check "run_elevenlabs_tts: does not contain set -e (no leak)" \
    "0" "$(echo "$_EL_FUNC" | grep -c 'set -e' || true)"

# ── 45. PID file safety ──────────────────────────────────────────

section "PID file safety"

# Toggle checks if process exists (kill -0) before killing
check "toggle does kill -0 before kill" \
    "yes" "$(grep -q 'kill -0 "\$OLD_PID"' "$SPEAK_SH" && echo "yes" || echo "no")"

# Toggle kills children first (curl, python, afplay) so bash can handle SIGTERM
check "toggle uses pkill -P to kill children first" \
    "yes" "$(grep -q 'pkill -P "\$OLD_PID"' "$SPEAK_SH" && echo "yes" || echo "no")"

# Toggle only kills if process is alive (kill follows kill -0 check)
check "toggle kill is inside if kill -0 block" \
    "yes" "$(grep -A 5 'kill -0.*OLD_PID.*then' "$SPEAK_SH" | grep -q 'kill "\$OLD_PID"' && echo "yes" || echo "no")"

# Toggle waits for old process to die before proceeding
check "toggle waits for old process to die" \
    "yes" "$(grep -A 8 'pkill -P "\$OLD_PID"' "$SPEAK_SH" | grep -q 'sleep 0.0[1-9]\|sleep 0.1' && echo "yes" || echo "no")"

# Toggle force-kills if process still alive after grace period
check "toggle force-kills (kill -9) as fallback" \
    "yes" "$(grep -q 'kill -9 "\$OLD_PID"' "$SPEAK_SH" && echo "yes" || echo "no")"

# Toggle only removes PID file if it still belongs to the killed process
# (prevents race: new instance writes PID while toggle waits for old to die)
check "toggle conditionally removes PID (checks OLD_PID)" \
    "yes" "$(awk '/pkill -P.*OLD_PID/,/exit 0/' "$SPEAK_SH" | grep -q 'cat "\$PID_FILE".*OLD_PID' && echo "yes" || echo "no")"

# PID file stores $$ (speak.sh PID, not afplay PID)
check "PID file stores \$\$ (shell PID)" \
    "yes" "$(grep -q 'echo "\$\$" > "\$PID_FILE"' "$SPEAK_SH" && echo "yes" || echo "no")"

# Stale PID file is cleaned up (process not running)
check "stale PID file cleaned on dead process" \
    "yes" "$(awk '/kill -0.*OLD_PID/,/fi/{next} /rm -f.*PID_FILE/' "$SPEAK_SH" | head -1 | grep -q 'rm' && echo "yes" || echo "no")"

# Cleanup uses pkill -P to kill all children
check "cleanup uses pkill -P \$\$ to kill all children" \
    "yes" "$(awk '/^cleanup\(\)/,/^}/' "$SPEAK_SH" | grep -q 'pkill -P \$\$' && echo "yes" || echo "no")"

# _DAEMON_PID tracked in shared state (local TTS daemon requests)
check "_DAEMON_PID initialized in shared state" \
    "yes" "$(grep -q '^_DAEMON_PID=""' "$SPEAK_SH" && echo "yes" || echo "no")"

# cleanup kills _DAEMON_PID's children (python3 inside subshell) then the subshell
check "cleanup kills _DAEMON_PID children (pkill -P + kill)" \
    "yes" "$(awk '/^cleanup\(\)/,/^}/' "$SPEAK_SH" | grep -q 'pkill -P "\$_DAEMON_PID"' && echo "yes" || echo "no")"

# curl runs in background + wait (interruptible by SIGTERM)
check "curl runs in background (& + wait)" \
    "yes" "$(awk '/^run_elevenlabs_tts\(\)/,/^}/' "$SPEAK_SH" | grep -q '_CURL_PID=\$!' && echo "yes" || echo "no")"

# Daemon request runs in background + wait (interruptible by SIGTERM)
check "daemon request runs in background (& + wait)" \
    "yes" "$(awk '/^run_local_tts\(\)/,/^}/' "$SPEAK_SH" | grep -q '_DAEMON_PID=\$!' && echo "yes" || echo "no")"

# Direct fallback runs in background + wait
check "direct fallback runs in background (& + wait)" \
    "yes" "$(awk '/^run_local_tts\(\)/,/^}/' "$SPEAK_SH" | grep -q 'join_audio.*) &' && echo "yes" || echo "no")"

# Log directory is created if missing
check "log dir created with mkdir -p" \
    "yes" "$(grep -q 'mkdir -p.*dirname.*LOG_FILE' "$SPEAK_SH" && echo "yes" || echo "no")"

# ── 46. Sentence splitting edge cases ────────────────────────────

section "Sentence splitting edge cases"

_SPLIT_PY="${VENV_PYTHON:-python3}"
[ -x "$_SPLIT_PY" ] || _SPLIT_PY=python3

_run_split() {
    "$_SPLIT_PY" -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
try:
    import pysbd
    seg = pysbd.Segmenter(language='en', clean=False)
    parts = seg.segment(text)
except ImportError:
    _ABR = re.compile(r'\b(Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc)\. ')
    _p = _ABR.sub(lambda m: m.group(1) + '\x00 ', text)
    _p = re.sub(r'\b([A-Z])\. ', lambda m: m.group(1) + '\x00 ', _p)
    parts = [p.replace('\x00', '.') for p in re.split(r'(?<=[.!?])\s+', _p)]
for p in parts:
    p = p.strip()
    if p: print(p)
" <<< "$1" 2>/dev/null || printf '%s\n' "$1"
}

# Single word, no punctuation → one line
check "split: single word" \
    "1" "$(echo "$(_run_split "Hello")" | wc -l | tr -d ' ')"

# Embedded newlines → split respects them
check "split: embedded newlines" \
    "2" "$(echo "$(_run_split "Line one.
Line two.")" | wc -l | tr -d ' ')"

# Glob characters preserved (no expansion)
check "split: glob chars preserved" \
    "What*" "$(echo "$(_run_split "What*")" | head -1)"

# Text with only punctuation
check "split: punctuation-only text" \
    "1" "$(echo "$(_run_split "...")" | wc -l | tr -d ' ')"

# Unicode text (no ASCII punctuation) → one sentence
check "split: CJK without ASCII punctuation stays together" \
    "1" "$(echo "$(_run_split "这是一个测试")" | wc -l | tr -d ' ')"

# Abbreviations should stay with the following text (not split)
check "split: abbreviation Mr. stays with name" \
    "1" "$(echo "$(_run_split "Mr. Smith went home.")" | wc -l | tr -d ' ')"

# Semicolons and colons are not sentence enders
check "split: semicolons stay in sentence" \
    "1" "$(echo "$(_run_split "First part; second part.")" | wc -l | tr -d ' ')"

# Multiple whitespace between sentences
check "split: double space between sentences" \
    "2" "$(echo "$(_run_split "First.  Second.")" | wc -l | tr -d ' ')"

# split_sentences has a fallback if python fails
check "split_sentences has fallback on python failure" \
    "yes" "$(grep -q '|| printf' "$SPEAK_SH" && echo "yes" || echo "no")"

# ── 46a2. Sentence splitting: quality ───────────────────────────

section "Sentence splitting quality"

# Abbreviations must not trigger sentence splits
check "split: Dr. stays with name" \
    "2" "$(echo "$(_run_split "Dr. Smith said hello. He was tired.")" | wc -l | tr -d ' ')"

check "split: Mrs. stays with name" \
    "1" "$(echo "$(_run_split "Mrs. Jones went to the store.")" | wc -l | tr -d ' ')"

check "split: Prof. stays with name" \
    "1" "$(echo "$(_run_split "Prof. Brown teaches history.")" | wc -l | tr -d ' ')"

# Spaced initials must not split
check "split: J. K. Rowling stays together" \
    "2" "$(echo "$(_run_split "J. K. Rowling wrote Harry Potter. It sold millions.")" | wc -l | tr -d ' ')"

# Colons in prose are not sentence enders
check "split: colon kept in sentence" \
    "2" "$(echo "$(_run_split "He had one goal: win the race. And he did.")" | wc -l | tr -d ' ')"

# Normal two-sentence text still splits
check "split: two sentences split correctly" \
    "2" "$(echo "$(_run_split "Hello world. Goodbye world.")" | wc -l | tr -d ' ')"

# Structural: speak.sh tries pySBD before regex fallback
check "speak.sh: split_sentences tries pySBD" \
    "yes" "$(grep -q 'import pysbd' "$SPEAK_SH" && echo "yes" || echo "no")"

# Structural: regex fallback does not split on colons/semicolons
check "speak.sh: regex fallback has no colon/semicolon" \
    "no" "$(awk '/^split_sentences/,/^}/' "$SPEAK_SH" | grep -qF '[.!?;:]' && echo "yes" || echo "no")"

# Structural: regex fallback protects abbreviations
check "speak.sh: regex fallback protects abbreviations" \
    "yes" "$(awk '/^split_sentences/,/^}/' "$SPEAK_SH" | grep -q 'Mr|Mrs' && echo "yes" || echo "no")"

# Functional: test the regex fallback explicitly (force pySBD import to fail)
_run_split_regex() {
    "$_SPLIT_PY" -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
_ABR = re.compile(r'\b(Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc)\. ')
_p = _ABR.sub(lambda m: m.group(1) + '\x00 ', text)
_p = re.sub(r'\b([A-Z])\. ', lambda m: m.group(1) + '\x00 ', _p)
parts = [p.replace('\x00', '.') for p in re.split(r'(?<=[.!?])\s+', _p)]
for p in parts:
    p = p.strip()
    if p: print(p)
" <<< "$1" 2>/dev/null || printf '%s\n' "$1"
}

check "regex fallback: Dr. stays with name" \
    "2" "$(echo "$(_run_split_regex "Dr. Smith said hello. He was tired.")" | wc -l | tr -d ' ')"

check "regex fallback: Mr. stays with name" \
    "1" "$(echo "$(_run_split_regex "Mr. Smith went home.")" | wc -l | tr -d ' ')"

check "regex fallback: J. K. stays together" \
    "2" "$(echo "$(_run_split_regex "J. K. Rowling wrote Harry Potter. It sold millions.")" | wc -l | tr -d ' ')"

check "regex fallback: colon kept in sentence" \
    "2" "$(echo "$(_run_split_regex "He had one goal: win the race. And he did.")" | wc -l | tr -d ' ')"

check "regex fallback: semicolons kept in sentence" \
    "1" "$(echo "$(_run_split_regex "First part; second part.")" | wc -l | tr -d ' ')"

check "regex fallback: basic two sentences" \
    "2" "$(echo "$(_run_split_regex "Hello world. Goodbye world.")" | wc -l | tr -d ' ')"

# ── 46b. Sentence splitting: offset format ─────────────────────

section "Sentence splitting: offset format"

# The new split_sentences outputs offset<TAB>len<TAB>sentence per line.
_test_split_offsets() {
    local py="${VENV_PYTHON:-python3}"
    [ -x "$py" ] || py=python3
    "$py" -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
try:
    import pysbd
    seg = pysbd.Segmenter(language='en', clean=False)
    parts = seg.segment(text)
except ImportError:
    _ABR = re.compile(r'\b(Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc)\. ')
    _p = _ABR.sub(lambda m: m.group(1) + '\x00 ', text)
    _p = re.sub(r'\b([A-Z])\. ', lambda m: m.group(1) + '\x00 ', _p)
    parts = [p.replace('\x00', '.') for p in re.split(r'(?<=[.!?])\s+', _p)]
pos = 0
for p in parts:
    p = p.strip()
    if not p:
        continue
    idx = text.find(p, pos)
    if idx == -1:
        idx = pos
    print(f'{idx}\t{len(p)}\t{p}')
    pos = idx + len(p)
" <<< "$1" 2>/dev/null
}

# Verify speak.sh split_sentences uses offset format
check "split_sentences outputs offset format" \
    "yes" "$(grep -q "print(f'" "$SPEAK_SH" && grep -q 'idx.*len(p)' "$SPEAK_SH" && echo "yes" || echo "no")"

# Two sentences: verify format and offset computation
_OFF_RESULT=$(_test_split_offsets "Hello. World.")
check "offset: format is offset<TAB>len<TAB>sentence" \
    "0	6	Hello." "$(echo "$_OFF_RESULT" | head -1)"
check "offset: second sentence offset accounts for gap" \
    "7	6	World." "$(echo "$_OFF_RESULT" | sed -n '2p')"

# Repeated sentences: offsets advance (not all 0)
_OFF_RESULT=$(_test_split_offsets "Yes. Yes. Yes.")
check "offset: repeated sentences advance correctly" \
    "0|5|10" "$(echo "$_OFF_RESULT" | cut -f1 | tr '\n' '|' | sed 's/|$//')"

# David Frum: colon stays in sentence, only period splits
_OFF_RESULT=$(_test_split_offsets "David Frum: Hello, and welcome to The David Frum Show. I'm David Frum, a staff writer at The Atlantic.")
check "offset: David Frum second sentence at 55" \
    "55" "$(echo "$_OFF_RESULT" | sed -n '2p' | cut -f1)"

# ── 47. Temp file lifecycle ──────────────────────────────────────

section "Temp file lifecycle"

# run_local_tts must NOT delete TMP_FILE (the pipeline loop handles cleanup
# via _PREV_TMP_FILE — deleting here races with afplay opening the file)
check "run_local_tts does NOT delete TMP_FILE at start" \
    "no" "$(awk '/^run_local_tts\(\)/,/^}/' "$SPEAK_SH" | head -5 | grep -q 'rm -f "\$TMP_FILE"' && echo "yes" || echo "no")"

# ElevenLabs: mktemp failure returns 1
check "run_elevenlabs_tts: mktemp failure returns 1" \
    "yes" "$(awk '/^run_elevenlabs_tts\(\)/,/^}/' "$SPEAK_SH" | grep -q '\[ -z "\$TMP_FILE" \].*return 1' && echo "yes" || echo "no")"

# Daemon generate_audio: tmp_dir is assigned BEFORE the try block
# (so it's in scope in the except handler)
check "daemon generate_audio: tmp_dir assigned before try" \
    "yes" "$(python3 -c "
import ast
with open('$TTS_SERVER') as f:
    tree = ast.parse(f.read())
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'generate_audio':
        body = node.body
        # Find tmp_dir assignment and try block positions
        tmp_dir_line = None
        try_line = None
        for stmt in body:
            if isinstance(stmt, ast.Assign):
                for t in stmt.targets:
                    if isinstance(t, ast.Name) and t.id == 'tmp_dir':
                        tmp_dir_line = stmt.lineno
            if isinstance(stmt, ast.Try) and try_line is None:
                try_line = stmt.lineno
        if tmp_dir_line and try_line and tmp_dir_line < try_line:
            print('yes')
        else:
            print('no')
        break
else:
    print('no')
" 2>/dev/null || echo "no")"

# Daemon: CancelledError caught by except Exception in generate_audio
check "daemon: CancelledError inherits from Exception" \
    "yes" "$(grep -q 'class CancelledError(Exception)' "$TTS_SERVER" && echo "yes" || echo "no")"

# Daemon: handle_client closes connection in finally block
check "daemon: connection closed in finally" \
    "yes" "$(grep -A 3 'finally:' "$TTS_SERVER" | grep -q 'conn.close' && echo "yes" || echo "no")"

# STATUS_FILE is NOT removed in cleanup — it persists for the Swift app
# to read the last playback timestamp. Stale data is benign (the app checks age).
check "cleanup does NOT remove STATUS_FILE (persists for app)" \
    "no" "$(awk '/^cleanup\(\)/,/^}/' "$SPEAK_SH" | grep -q 'STATUS_FILE' && echo "yes" || echo "no")"

# ── 48. Pipeline state edge cases ────────────────────────────────

section "Pipeline state edge cases"

# wait_audio is safe when PLAY_PID is empty (guarded by -n)
check "wait_audio guards empty PLAY_PID" \
    "yes" "$(awk '/^wait_audio\(\)/,/^}/' "$SPEAK_SH" | grep -q '\[ -n "\$PLAY_PID" \]' && echo "yes" || echo "no")"

# wait_audio clears PLAY_PID after waiting (prevents double-kill)
check "wait_audio clears PLAY_PID" \
    "yes" "$(awk '/^wait_audio\(\)/,/^}/' "$SPEAK_SH" | grep -q 'PLAY_PID=""' && echo "yes" || echo "no")"

# wait_audio uses || true (handles non-zero exit from afplay)
check "wait_audio tolerates afplay failure (|| true)" \
    "yes" "$(awk '/^wait_audio\(\)/,/^}/' "$SPEAK_SH" | grep -q '|| true' && echo "yes" || echo "no")"

# _FIRST flag: local path shows error dialog only on first sentence failure
check "local loop: error dialog only on first sentence" \
    "yes" "$(awk '/TTS_BACKEND.*=.*local/,/^else/' "$SPEAK_SH" | grep -q '\$_FIRST.*_ok.*-ne 0' && echo "yes" || echo "no")"

# _FIRST flag: cloud path breaks to error handler only on first sentence
check "cloud loop: single break on TTS failure" \
    "yes" "$(awk '/ElevenLabs.*cloud/,/done/' "$SPEAK_SH" | grep -q 'break' && echo "yes" || echo "no")"

# Single sentence works: wait_audio after loop catches it
check "pipeline handles single sentence (wait_audio after loop)" \
    "yes" "$(awk '/done <<< "\$_SENTENCES"/{found++} found==1 && /wait_audio/{print "yes"; exit}' "$SPEAK_SH" | head -1)"

# ── 49. Cloud TTS failure modes ──────────────────────────────────

section "Cloud TTS failure modes"

# curl has --max-time timeout
check "curl has --max-time for timeout protection" \
    "yes" "$(awk '/^run_elevenlabs_tts/,/^}/' "$SPEAK_SH" | grep -q 'max-time' && echo "yes" || echo "no")"

# Mid-stream cloud failure stops silently (no dialog)
check "cloud TTS HTTP error: shows dialog" \
    "yes" "$(awk '/HTTP_CODE.*!=.*200/,/osascript/' "$SPEAK_SH" | grep -q 'osascript' && echo "yes" || echo "no")"

# Fallback: network failure with both backends → tries local
check "network failure + both: runs run_local_tts" \
    "yes" "$(awk '/Network failure/,/HTTP 429/' "$SPEAK_SH" | grep -q 'run_local_tts' && echo "yes" || echo "no")"

# Fallback: 429 with both backends → tries local
check "429 + both: runs run_local_tts" \
    "yes" "$(awk '/HTTP 429/,/Handle other/' "$SPEAK_SH" | grep -q 'run_local_tts' && echo "yes" || echo "no")"

# JSON encoding failure: CURL_EXIT/HTTP_CODE uninitialized.
# The error handler checks [ -z "$HTTP_CODE" ] which catches this.
check "error handler catches unset HTTP_CODE (JSON failure)" \
    "yes" "$(awk '/first sentence failed/,/fi$/' "$SPEAK_SH" | grep -q '\-z "\$HTTP_CODE"' && echo "yes" || echo "no")"

# ── 50. Local TTS failure modes ──────────────────────────────────

section "Local TTS failure modes"

# Daemon client socket read timeout
check "daemon client socket timeout" \
    "yes" "$(grep -q 'conn.settimeout' "$TTS_SERVER" && echo "yes" || echo "no")"

# run_local_tts: fallback to direct invocation when daemon unavailable
check "run_local_tts: fallback to direct mlx invocation" \
    "yes" "$(awk '/^run_local_tts/,/^}/' "$SPEAK_SH" | grep -q 'mlx_audio.tts.generate' && echo "yes" || echo "no")"


# ── 51. Functional: toggle kills entire process tree ──────────────

section "Functional: toggle and rapid invocation"

_TESTTMP=$(mktemp -d "${TMPDIR:-/tmp}/speak11_test_XXXXXXXXXX")

# Simulate toggle: PID file with running process → kills children + parent
(
    set +e  # match speak.sh behavior (no set -e)
    # Start a background sleep to simulate speak.sh
    sleep 30 &
    _SIM_PID=$!

    _PID_FILE="$_TESTTMP/speak11_tts.pid"
    echo "$_SIM_PID" > "$_PID_FILE"

    # New invocation: read PID, kill children first, then parent
    OLD_PID=$(cat "$_PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        pkill -P "$OLD_PID" 2>/dev/null
        kill "$OLD_PID" 2>/dev/null
        for _i in 1 2 3 4 5; do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null
        rm -f "$_PID_FILE"
    fi
    # Verify the process is dead
    sleep 0.1
    kill -0 "$_SIM_PID" 2>/dev/null && echo "alive" || echo "dead"
) > "$_TESTTMP/toggle_result" 2>/dev/null
check "toggle kills previous process" \
    "dead" "$(cat "$_TESTTMP/toggle_result")"

# Simulate stale PID (process not running) → clean up and proceed
(
    _PID_FILE="$_TESTTMP/speak11_tts2.pid"
    echo "99999999" > "$_PID_FILE"  # PID that doesn't exist
    if [ -f "$_PID_FILE" ]; then
        OLD_PID=$(cat "$_PID_FILE" 2>/dev/null)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            echo "would_kill"
        else
            rm -f "$_PID_FILE"
            echo "cleaned_stale"
        fi
    fi
) > "$_TESTTMP/stale_result" 2>/dev/null
check "stale PID file: cleaned up, no kill sent" \
    "cleaned_stale" "$(cat "$_TESTTMP/stale_result")"

# Rapid triple-invoke: B kills A (with pkill+wait), C sees no PID file
(
    set +e  # match speak.sh behavior (no set -e)
    _PID_FILE="$_TESTTMP/speak11_tts3.pid"

    # Instance A: starts running
    sleep 30 &
    A_PID=$!
    echo "$A_PID" > "$_PID_FILE"

    # Instance B: toggle-kills A with new robust mechanism
    OLD_PID=$(cat "$_PID_FILE" 2>/dev/null)
    pkill -P "$OLD_PID" 2>/dev/null
    kill "$OLD_PID" 2>/dev/null
    for _i in 1 2 3 4 5; do
        kill -0 "$OLD_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null
    rm -f "$_PID_FILE"

    # Instance C: no PID file → proceeds normally
    if [ -f "$_PID_FILE" ]; then
        echo "found_pid"
    else
        echo "no_pid_proceeds"
    fi

    wait "$A_PID" 2>/dev/null || true
) > "$_TESTTMP/rapid_result" 2>/dev/null
check "rapid triple-invoke: third instance proceeds cleanly" \
    "no_pid_proceeds" "$(cat "$_TESTTMP/rapid_result")"

rm -rf "$_TESTTMP"

# ── 52. Functional: cleanup on signal ────────────────────────────

section "Functional: cleanup on signal"

_TESTTMP=$(mktemp -d "${TMPDIR:-/tmp}/speak11_test_XXXXXXXXXX")

# Simulate cleanup behavior: SIGTERM kills PLAY_PID and removes files
(
    TMP_FILE="$_TESTTMP/audio.wav"
    PID_FILE="$_TESTTMP/tts.pid"
    _PREV_TMP_FILE="$_TESTTMP/prev_audio.wav"
    _PREV_TMP_DIR="$_TESTTMP/prev_dir"
    TMP_DIR=""
    STATUS_FILE="$_TESTTMP/status"

    touch "$TMP_FILE" "$PID_FILE" "$_PREV_TMP_FILE" "$STATUS_FILE"
    mkdir -p "$_PREV_TMP_DIR"

    # Simulate afplay running in background
    sleep 30 &
    PLAY_PID=$!

    # Write our own PID into the PID file (simulating a different instance's PID)
    echo "999" > "$PID_FILE"

    # Run cleanup (simulating trap — skip pkill -P in test to avoid killing
    # test runner children; the pkill behavior is verified by structural checks)
    set +e
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" 2>/dev/null
    rm -f "$TMP_FILE" "$_PREV_TMP_FILE"
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    [ -n "$_PREV_TMP_DIR" ] && rm -rf "$_PREV_TMP_DIR"
    # Only remove PID file if it's ours ($$=test runner, PID file says "999")
    [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE"

    # Check what was cleaned
    [ ! -f "$TMP_FILE" ] && echo "tmp_ok"
    [ ! -f "$_PREV_TMP_FILE" ] && echo "prev_ok"
    [ ! -d "$_PREV_TMP_DIR" ] && echo "prev_dir_ok"
    kill -0 "$PLAY_PID" 2>/dev/null || echo "play_killed"
    # PID file should NOT be removed (it contains "999", not $$)
    [ -f "$PID_FILE" ] && echo "pid_preserved"

    wait "$PLAY_PID" 2>/dev/null || true
) > "$_TESTTMP/cleanup_result" 2>/dev/null

check "cleanup: removes TMP_FILE" \
    "yes" "$(grep -q 'tmp_ok' "$_TESTTMP/cleanup_result" && echo "yes" || echo "no")"
check "cleanup: preserves PID_FILE owned by other instance" \
    "yes" "$(grep -q 'pid_preserved' "$_TESTTMP/cleanup_result" && echo "yes" || echo "no")"
check "cleanup: removes _PREV_TMP_FILE" \
    "yes" "$(grep -q 'prev_ok' "$_TESTTMP/cleanup_result" && echo "yes" || echo "no")"
check "cleanup: removes _PREV_TMP_DIR" \
    "yes" "$(grep -q 'prev_dir_ok' "$_TESTTMP/cleanup_result" && echo "yes" || echo "no")"
check "cleanup: kills PLAY_PID" \
    "yes" "$(grep -q 'play_killed' "$_TESTTMP/cleanup_result" && echo "yes" || echo "no")"

rm -rf "$_TESTTMP"

# ── 53. Functional: pipeline ordering ─────────────────────────────

section "Functional: pipeline overlap simulation"

_TESTTMP=$(mktemp -d "${TMPDIR:-/tmp}/speak11_test_XXXXXXXXXX")

# Simulate pipeline: generate, play, generate overlapping, wait, play
(
    PLAY_PID=""
    _PREV_TMP_FILE=""
    _TIMELINE=""

    wait_audio() {
        if [ -n "$PLAY_PID" ]; then
            wait "$PLAY_PID" 2>/dev/null || true
            PLAY_PID=""
        fi
    }
    play_audio() {
        sleep 0.05 &
        PLAY_PID=$!
    }
    generate() {
        _TIMELINE="${_TIMELINE}gen$1 "
    }

    # Sentence 1
    generate 1
    wait_audio  # no-op (first)
    _PREV_TMP_FILE="file1"
    play_audio
    _TIMELINE="${_TIMELINE}play1 "

    # Sentence 2 (generated while 1 plays)
    generate 2
    wait_audio  # waits for play1
    _TIMELINE="${_TIMELINE}wait1 "
    _PREV_TMP_FILE="file2"
    play_audio
    _TIMELINE="${_TIMELINE}play2 "

    # Final wait
    wait_audio
    _TIMELINE="${_TIMELINE}wait2"

    echo "$_TIMELINE"
) > "$_TESTTMP/pipeline_result" 2>/dev/null

check "pipeline ordering: gen1 play1 gen2 wait1 play2 wait2" \
    "gen1 play1 gen2 wait1 play2 wait2" \
    "$(cat "$_TESTTMP/pipeline_result" | tr -s ' ' | sed 's/ $//')"

rm -rf "$_TESTTMP"


# ── 55. Daemon robustness ────────────────────────────────────────

section "Daemon robustness"

# Server listen backlog
check "daemon: listen backlog >= 2" \
    "yes" "$(grep -q 'server_socket.listen(2)' "$TTS_SERVER" && echo "yes" || echo "no")"

# Daemon writes PID file after acquiring lock
check "daemon: PID file written after lock" \
    "yes" "$(awk '/fcntl.flock/,/PID_FILE/' "$TTS_SERVER" | grep -q 'PID_FILE' && echo "yes" || echo "no")"

# Daemon removes stale socket before binding
check "daemon: removes stale socket" \
    "yes" "$(awk '/Remove stale socket/,/pass/' "$TTS_SERVER" | grep -q 'os.unlink(SOCKET_PATH)' && echo "yes" || echo "no")"

# Daemon socket has timeout (prevents blocking forever on accept)
check "daemon: server_socket.settimeout" \
    "yes" "$(grep -q 'server_socket.settimeout' "$TTS_SERVER" && echo "yes" || echo "no")"

# Daemon shutdown cleans up socket and PID file
check "daemon: shutdown removes socket and PID" \
    "yes" "$(grep -A 15 'def do_shutdown' "$TTS_SERVER" | grep -q 'os.unlink' && echo "yes" || echo "no")"

# Daemon: signal handlers for clean shutdown
check "daemon: SIGTERM handler" \
    "yes" "$(grep -q 'signal.SIGTERM' "$TTS_SERVER" && echo "yes" || echo "no")"

check "daemon: SIGINT handler" \
    "yes" "$(grep -q 'signal.SIGINT' "$TTS_SERVER" && echo "yes" || echo "no")"

# Daemon: managed mode has parent watchdog
check "daemon: parent_watchdog for managed mode" \
    "yes" "$(grep -q 'def parent_watchdog' "$TTS_SERVER" && echo "yes" || echo "no")"

# Daemon: idle mode has idle watchdog
check "daemon: idle_watchdog for standalone mode" \
    "yes" "$(grep -q 'def idle_watchdog' "$TTS_SERVER" && echo "yes" || echo "no")"

# Daemon: handle_client sends error response on exception
check "daemon: error response sent to client on failure" \
    "yes" "$(grep -q '"status": "error"' "$TTS_SERVER" && echo "yes" || echo "no")"

# ── 56. Simulation: local pipeline with fake TTS ──────────────────

section "Simulation: local pipeline with fake TTS"

_SIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/speak11_sim_XXXXXXXXXX")
_SIM_LOG="$_SIMDIR/play.log"
_SIM_STATUS="$_SIMDIR/status"
_SIM_PIDFILE="$_SIMDIR/tts.pid"

# Create a fake TTS driver script that uses the actual pipeline logic from
# speak.sh but replaces afplay/daemon with stubs that log what they do.
cat > "$_SIMDIR/sim_local.sh" << 'SIMEOF'
#!/bin/bash
# Simulation: runs the local pipeline with fake TTS and fake afplay.
# Receives TEXT via env, logs which sentences are played and in what order.
_SIMDIR="$1"
_SIM_LOG="$_SIMDIR/play.log"
STATUS_FILE="$_SIMDIR/status"
PID_FILE="$_SIMDIR/tts.pid"
TMP_FILE=""
TMP_DIR=""
PLAY_PID=""
_PREV_TMP_FILE=""
_PREV_TMP_DIR=""
_GEN_COUNT=0

echo "$$" > "$PID_FILE"

cleanup() {
    set +e
    pkill -P $$ 2>/dev/null
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" 2>/dev/null
    rm -f "$TMP_FILE" "$_PREV_TMP_FILE"
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    [ -n "$_PREV_TMP_DIR" ] && rm -rf "$_PREV_TMP_DIR"
    [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

split_sentences() {
    python3 -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
parts = re.split(r'(?<=[.!?])\s+', text)
pos = 0
for p in parts:
    p = p.strip()
    if not p:
        continue
    idx = text.find(p, pos)
    if idx == -1:
        idx = pos
    print(f'{idx}\t{len(p)}\t{p}')
    pos = idx + len(p)
" <<< "$1" 2>/dev/null || printf '0\t%d\t%s\n' "${#1}" "$1"
}

# Fake run_local_tts: creates a WAV file (just text content for verification)
run_local_tts() {
    _GEN_COUNT=$((_GEN_COUNT + 1))
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/speak11_sim_gen_XXXXXXXXXX")
    TMP_FILE="$TMP_DIR/speak11.wav"
    printf '%s' "$TEXT" > "$TMP_FILE"
    # Simulate generation time (10ms)
    sleep 0.01
    [ -s "$TMP_FILE" ]
}

# Fake play_audio: logs the sentence content, starts a brief background sleep
play_audio() {
    # Verify the file exists and is readable at play time
    if [ ! -s "$TMP_FILE" ]; then
        echo "ERROR:file_missing_at_play:$TMP_FILE" >> "$_SIM_LOG"
        return
    fi
    local content
    content=$(cat "$TMP_FILE")
    echo "PLAY:$content" >> "$_SIM_LOG"
    # Simulate playback (30ms)
    sleep 0.03 &
    PLAY_PID=$!
}

wait_audio() {
    if [ -n "$PLAY_PID" ]; then
        wait "$PLAY_PID" 2>/dev/null || true
        PLAY_PID=""
    fi
}

# ── Run the pipeline (mirrors speak.sh local loop) ──
_SENTENCES=$(split_sentences "$TEXT")

_SAVED_TEXT="$TEXT"
_FIRST=true
while IFS=$'\t' read -r _OFFSET _SENT_LEN _SENTENCE; do
    [ -z "$_SENTENCE" ] && continue
    TEXT="$_SENTENCE"
    run_local_tts
    _ok=$?
    if $_FIRST && [ $_ok -ne 0 ]; then
        echo "ERROR:first_gen_failed" >> "$_SIM_LOG"
        exit 1
    fi
    if [ $_ok -eq 0 ]; then
        wait_audio
        [ -n "$_PREV_TMP_FILE" ] && rm -f "$_PREV_TMP_FILE"
        [ -n "$_PREV_TMP_DIR" ] && rm -rf "$_PREV_TMP_DIR"
        _FIRST=false
        _PREV_TMP_FILE="$TMP_FILE"
        _PREV_TMP_DIR="$TMP_DIR"
        play_audio
    fi
done <<< "$_SENTENCES"
wait_audio
TEXT="$_SAVED_TEXT"

echo "DONE:$_GEN_COUNT" >> "$_SIM_LOG"
SIMEOF
chmod +x "$_SIMDIR/sim_local.sh"

# Test: multi-sentence text plays all sentences in order
_SIM_TEXT="First sentence. Second sentence. Third sentence. Fourth sentence."
TEXT="$_SIM_TEXT" bash "$_SIMDIR/sim_local.sh" "$_SIMDIR" 2>/dev/null

check "sim-local: all 4 sentences played" \
    "4" "$(grep -c '^PLAY:' "$_SIM_LOG" 2>/dev/null || true)"

check "sim-local: sentence 1 played first" \
    "yes" "$(sed -n '1p' "$_SIM_LOG" | grep -q 'PLAY:First sentence\.' && echo "yes" || echo "no")"

check "sim-local: sentence 2 played second" \
    "yes" "$(sed -n '2p' "$_SIM_LOG" | grep -q 'PLAY:Second sentence\.' && echo "yes" || echo "no")"

check "sim-local: sentence 3 played third" \
    "yes" "$(sed -n '3p' "$_SIM_LOG" | grep -q 'PLAY:Third sentence\.' && echo "yes" || echo "no")"

check "sim-local: sentence 4 played fourth" \
    "yes" "$(sed -n '4p' "$_SIM_LOG" | grep -q 'PLAY:Fourth sentence\.' && echo "yes" || echo "no")"

check "sim-local: no file-missing errors" \
    "0" "$(grep -c 'ERROR:file_missing' "$_SIM_LOG" 2>/dev/null || true)"

check "sim-local: generation count matches sentence count" \
    "yes" "$(grep -q 'DONE:4' "$_SIM_LOG" && echo "yes" || echo "no")"

# Test: PID file cleaned up after normal completion
check "sim-local: PID file removed after normal exit" \
    "no" "$([ -f "$_SIM_PIDFILE" ] && echo "yes" || echo "no")"

# Test with the user's real-world text that was failing
rm -f "$_SIM_LOG"
_SIM_TEXT='On this week'\''s episode of The David Frum Show, Atlantic staff writer David Frum opens with his take on President Trump'\''s reaction to a recent Supreme Court defeat on tariffs, arguing that the real issue is not just economics but the president'\''s drive for unchecked power.

Then David is joined by Tim Miller of The Bulwark to unpack Tim'\''s recent trip to Minneapolis and what he saw on the ground amid ongoing ICE enforcement operations in the Twin Cities. They explore why younger Americans find "Resist libs" cringe and how that cynicism has helped fuel Trump'\''s politics. David and Tim also debate whether Never Trump conservatives are losing the core values that once defined them and whether that evolution is necessary in order to actually take on Trump.'

TEXT="$_SIM_TEXT" bash "$_SIMDIR/sim_local.sh" "$_SIMDIR" 2>/dev/null

_PLAY_COUNT=$(grep -c '^PLAY:' "$_SIM_LOG" 2>/dev/null || true)
check "sim-local: real-world text plays all sentences (>=3)" \
    "yes" "$([ "$_PLAY_COUNT" -ge 3 ] && echo "yes" || echo "no")"

check "sim-local: real-world first sentence starts with 'On this'" \
    "yes" "$(head -1 "$_SIM_LOG" | grep -q 'PLAY:On this' && echo "yes" || echo "no")"

check "sim-local: real-world no errors" \
    "0" "$(grep -c 'ERROR:' "$_SIM_LOG" 2>/dev/null || true)"

rm -rf "$_SIMDIR"

# ── 57. Simulation: cloud pipeline with fake curl ──────────────────

section "Simulation: cloud pipeline with fake curl"

_SIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/speak11_sim_XXXXXXXXXX")
_SIM_LOG="$_SIMDIR/play.log"

# Create a fake cloud TTS driver
cat > "$_SIMDIR/sim_cloud.sh" << 'SIMEOF'
#!/bin/bash
_SIMDIR="$1"
_SIM_LOG="$_SIMDIR/play.log"
STATUS_FILE="$_SIMDIR/status"
PID_FILE="$_SIMDIR/tts.pid"
TMP_FILE=""
PLAY_PID=""
_PREV_TMP_FILE=""
HTTP_CODE=""
CURL_EXIT=0

echo "$$" > "$PID_FILE"

cleanup() {
    set +e
    pkill -P $$ 2>/dev/null
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" 2>/dev/null
    rm -f "$TMP_FILE" "$_PREV_TMP_FILE"
    [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

split_sentences() {
    python3 -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
parts = re.split(r'(?<=[.!?])\s+', text)
pos = 0
for p in parts:
    p = p.strip()
    if not p:
        continue
    idx = text.find(p, pos)
    if idx == -1:
        idx = pos
    print(f'{idx}\t{len(p)}\t{p}')
    pos = idx + len(p)
" <<< "$1" 2>/dev/null || printf '0\t%d\t%s\n' "${#1}" "$1"
}

run_elevenlabs_tts() {
    local sentence="$1"
    TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/speak11_sim_tts_XXXXXXXXXX")
    printf '%s' "$sentence" > "$TMP_FILE"
    sleep 0.01
    HTTP_CODE="200"
    CURL_EXIT=0
    [ -s "$TMP_FILE" ]
}

play_audio() {
    if [ ! -s "$TMP_FILE" ]; then
        echo "ERROR:file_missing_at_play:$TMP_FILE" >> "$_SIM_LOG"
        return
    fi
    local content
    content=$(cat "$TMP_FILE")
    echo "PLAY:$content" >> "$_SIM_LOG"
    sleep 0.03 &
    PLAY_PID=$!
}

wait_audio() {
    if [ -n "$PLAY_PID" ]; then
        wait "$PLAY_PID" 2>/dev/null || true
        PLAY_PID=""
    fi
}

_SENTENCES=$(split_sentences "$TEXT")
_FIRST=true
while IFS=$'\t' read -r _OFFSET _SENT_LEN _SENTENCE; do
    [ -z "$_SENTENCE" ] && continue
    if ! run_elevenlabs_tts "$_SENTENCE"; then
        if $_FIRST; then break; fi
        break
    fi
    wait_audio
    [ -n "$_PREV_TMP_FILE" ] && rm -f "$_PREV_TMP_FILE"
    _FIRST=false
    _PREV_TMP_FILE="$TMP_FILE"
    play_audio
done <<< "$_SENTENCES"
wait_audio

echo "DONE" >> "$_SIM_LOG"
SIMEOF
chmod +x "$_SIMDIR/sim_cloud.sh"

rm -f "$_SIM_LOG"
TEXT="Alpha. Beta. Gamma." bash "$_SIMDIR/sim_cloud.sh" "$_SIMDIR" 2>/dev/null

check "sim-cloud: all 3 sentences played" \
    "3" "$(grep -c '^PLAY:' "$_SIM_LOG" 2>/dev/null || true)"

check "sim-cloud: sentence order correct" \
    "PLAY:Alpha.|PLAY:Beta.|PLAY:Gamma." \
    "$(grep '^PLAY:' "$_SIM_LOG" | tr '\n' '|' | sed 's/|$//')"

check "sim-cloud: no file-missing errors" \
    "0" "$(grep -c 'ERROR:' "$_SIM_LOG" 2>/dev/null || true)"

rm -rf "$_SIMDIR"

# ── 57b. Simulation: per-sentence billing and interruption ─────────
#
# Both the cloud (ElevenLabs) and local (Kokoro) pipelines generate one
# sentence at a time with one-sentence lookahead.  This means:
#   - Each API call / Kokoro generation handles a single sentence
#   - Interrupting stops further generation (saves credits / GPU time)
#   - At most played + 1 generations occur (the pre-fetched lookahead)
#
# The simulation uses separate traps matching speak.sh:
#   trap cleanup EXIT          — cleanup on any exit
#   trap 'exit 143' TERM      — SIGTERM causes immediate exit (cleanup via EXIT)
#   trap 'exit 130' INT       — SIGINT  causes immediate exit

section "Simulation: per-sentence billing and interruption"

# ── Helper: create a pipeline simulation script ──
# Usage: _make_pipeline_sim <path> <backend> <play_sleep>
#   backend: "cloud" or "local"
#   play_sleep: seconds for simulated playback (e.g. "0.1" or "0.3")
_make_pipeline_sim() {
    local path="$1" backend="$2" play_sleep="$3"
    cat > "$path" << SIMEOF
#!/bin/bash
_SIMDIR="\$1"
_SIM_LOG="\$_SIMDIR/play.log"
_GEN_LOG="\$_SIMDIR/gen.log"
PID_FILE="\$_SIMDIR/tts.pid"
TMP_FILE=""
TMP_DIR=""
PLAY_PID=""
_PREV_TMP_FILE=""
_PREV_TMP_DIR=""

echo "\$\$" > "\$PID_FILE"

cleanup() {
    set +e
    pkill -P \$\$ 2>/dev/null
    [ -n "\$PLAY_PID" ] && kill "\$PLAY_PID" 2>/dev/null
    rm -f "\$TMP_FILE" "\$_PREV_TMP_FILE"
    [ -n "\$TMP_DIR" ] && rm -rf "\$TMP_DIR"
    [ -n "\$_PREV_TMP_DIR" ] && rm -rf "\$_PREV_TMP_DIR"
    [ -f "\$PID_FILE" ] && [ "\$(cat "\$PID_FILE" 2>/dev/null)" = "\$\$" ] && rm -f "\$PID_FILE"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

split_sentences() {
    python3 -c "
import re, sys
text = sys.stdin.read().rstrip('\n')
parts = re.split(r'(?<=[.!?])\s+', text)
pos = 0
for p in parts:
    p = p.strip()
    if not p:
        continue
    idx = text.find(p, pos)
    if idx == -1:
        idx = pos
    print(f'{idx}\t{len(p)}\t{p}')
    pos = idx + len(p)
" <<< "\$1" 2>/dev/null || printf '0\t%d\t%s\n' "\${#1}" "\$1"
}

run_tts() {
    echo "GEN:\$1" >> "\$_GEN_LOG"
    TMP_DIR=\$(mktemp -d "\${TMPDIR:-/tmp}/speak11_sim_gen_XXXXXXXXXX")
    TMP_FILE="\$TMP_DIR/speak11.wav"
    printf '%s' "\$1" > "\$TMP_FILE"
    sleep 0.01
    [ -s "\$TMP_FILE" ]
}

play_audio() {
    if [ ! -s "\$TMP_FILE" ]; then
        echo "ERROR:file_missing" >> "\$_SIM_LOG"
        return
    fi
    echo "PLAY:\$(cat "\$TMP_FILE")" >> "\$_SIM_LOG"
    sleep $play_sleep &
    PLAY_PID=\$!
}

wait_audio() {
    [ -n "\$PLAY_PID" ] && { wait "\$PLAY_PID" 2>/dev/null || true; PLAY_PID=""; }
}

_SENTENCES=\$(split_sentences "\$TEXT")
SIMEOF

    if [ "$backend" = "cloud" ]; then
        cat >> "$path" << 'SIMEOF2'
_FIRST=true
while IFS=$'\t' read -r _OFFSET _SENT_LEN _SENTENCE; do
    [ -z "$_SENTENCE" ] && continue
    if ! run_tts "$_SENTENCE"; then
        if $_FIRST; then break; fi
        break
    fi
    wait_audio
    [ -n "$_PREV_TMP_FILE" ] && rm -f "$_PREV_TMP_FILE"
    _FIRST=false
    _PREV_TMP_FILE="$TMP_FILE"
    play_audio
done <<< "$_SENTENCES"
wait_audio
echo "DONE" >> "$_SIM_LOG"
SIMEOF2
    else
        cat >> "$path" << 'SIMEOF3'
_SAVED_TEXT="$TEXT"
_FIRST=true
while IFS=$'\t' read -r _OFFSET _SENT_LEN _SENTENCE; do
    [ -z "$_SENTENCE" ] && continue
    TEXT="$_SENTENCE"
    run_tts "$_SENTENCE"
    _ok=$?
    if $_FIRST && [ $_ok -ne 0 ]; then exit 1; fi
    if [ $_ok -eq 0 ]; then
        wait_audio
        [ -n "$_PREV_TMP_FILE" ] && rm -f "$_PREV_TMP_FILE"
        [ -n "$_PREV_TMP_DIR" ] && rm -rf "$_PREV_TMP_DIR"
        _FIRST=false
        _PREV_TMP_FILE="$TMP_FILE"
        _PREV_TMP_DIR="$TMP_DIR"
        play_audio
    fi
done <<< "$_SENTENCES"
wait_audio
TEXT="$_SAVED_TEXT"
echo "DONE" >> "$_SIM_LOG"
SIMEOF3
    fi
    chmod +x "$path"
}

# ── Helper: run interrupt test ──
# Usage: _run_interrupt_test <sim_path> <simdir> <text> <wait_for_plays>
# Returns: sets _GEN_COUNT and _PLAY_COUNT
_run_interrupt_test() {
    local sim_path="$1" simdir="$2" text="$3" wait_for="$4"
    rm -f "$simdir/play.log" "$simdir/gen.log"
    TEXT="$text" bash "$sim_path" "$simdir" 2>/dev/null &
    local sim_pid=$!
    local _i
    for _i in $(seq 1 80); do
        [ "$(grep -c '^PLAY:' "$simdir/play.log" 2>/dev/null)" -ge "$wait_for" ] 2>/dev/null && break
        sleep 0.05
    done
    kill "$sim_pid" 2>/dev/null
    wait "$sim_pid" 2>/dev/null || true
    _GEN_COUNT=$(grep -c '^GEN:' "$simdir/gen.log" 2>/dev/null || echo 0)
    _PLAY_COUNT=$(grep -c '^PLAY:' "$simdir/play.log" 2>/dev/null || echo 0)
}

_SIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/speak11_sim_XXXXXXXXXX")

# ── Cloud (ElevenLabs): per-sentence API calls ──

_make_pipeline_sim "$_SIMDIR/sim_cloud.sh" "cloud" "0.1"
_make_pipeline_sim "$_SIMDIR/sim_cloud_slow.sh" "cloud" "0.5"

# Full run: each sentence gets its own API call
rm -f "$_SIMDIR/play.log" "$_SIMDIR/gen.log"
TEXT="One. Two. Three. Four. Five." bash "$_SIMDIR/sim_cloud.sh" "$_SIMDIR" 2>/dev/null

check "cloud-billing: 5 API calls for 5 sentences" \
    "5" "$(grep -c '^GEN:' "$_SIMDIR/gen.log" 2>/dev/null || echo 0)"

check "cloud-billing: each call sends one sentence" \
    "GEN:One.|GEN:Two.|GEN:Three.|GEN:Four.|GEN:Five." \
    "$(cat "$_SIMDIR/gen.log" | tr '\n' '|' | sed 's/|$//')"

check "cloud-billing: all 5 played" \
    "5" "$(grep -c '^PLAY:' "$_SIMDIR/play.log" 2>/dev/null || echo 0)"

# Single sentence: no splitting overhead
rm -f "$_SIMDIR/play.log" "$_SIMDIR/gen.log"
TEXT="Just one sentence." bash "$_SIMDIR/sim_cloud.sh" "$_SIMDIR" 2>/dev/null

check "cloud-billing: single sentence = 1 API call" \
    "1" "$(grep -c '^GEN:' "$_SIMDIR/gen.log" 2>/dev/null || echo 0)"

# Interrupted: kill after 2 plays of 10 sentences → credits saved
_run_interrupt_test "$_SIMDIR/sim_cloud_slow.sh" "$_SIMDIR" \
    "S1. S2. S3. S4. S5. S6. S7. S8. S9. S10." 2

check "cloud-interrupt: credits saved (< 10 API calls)" \
    "yes" "$([ "$_GEN_COUNT" -lt 10 ] && echo "yes" || echo "no")"

check "cloud-interrupt: API calls <= played + 1 (lookahead)" \
    "yes" "$([ "$_GEN_COUNT" -le $((_PLAY_COUNT + 1)) ] && echo "yes" || echo "no")"

# ── Local (Kokoro): per-sentence generation ──

_make_pipeline_sim "$_SIMDIR/sim_local.sh" "local" "0.1"
_make_pipeline_sim "$_SIMDIR/sim_local_slow.sh" "local" "0.5"

# Full run
rm -f "$_SIMDIR/play.log" "$_SIMDIR/gen.log"
TEXT="One. Two. Three. Four. Five." bash "$_SIMDIR/sim_local.sh" "$_SIMDIR" 2>/dev/null

check "local-billing: 5 generations for 5 sentences" \
    "5" "$(grep -c '^GEN:' "$_SIMDIR/gen.log" 2>/dev/null || echo 0)"

check "local-billing: each generation is one sentence" \
    "GEN:One.|GEN:Two.|GEN:Three.|GEN:Four.|GEN:Five." \
    "$(cat "$_SIMDIR/gen.log" | tr '\n' '|' | sed 's/|$//')"

check "local-billing: all 5 played" \
    "5" "$(grep -c '^PLAY:' "$_SIMDIR/play.log" 2>/dev/null || echo 0)"

# Single sentence
rm -f "$_SIMDIR/play.log" "$_SIMDIR/gen.log"
TEXT="Just one sentence." bash "$_SIMDIR/sim_local.sh" "$_SIMDIR" 2>/dev/null

check "local-billing: single sentence = 1 generation" \
    "1" "$(grep -c '^GEN:' "$_SIMDIR/gen.log" 2>/dev/null || echo 0)"

# Interrupted: kill after 2 plays of 10 sentences → skips remaining
_run_interrupt_test "$_SIMDIR/sim_local_slow.sh" "$_SIMDIR" \
    "S1. S2. S3. S4. S5. S6. S7. S8. S9. S10." 2

check "local-interrupt: skipped generations (< 10)" \
    "yes" "$([ "$_GEN_COUNT" -lt 10 ] && echo "yes" || echo "no")"

check "local-interrupt: generations <= played + 1 (lookahead)" \
    "yes" "$([ "$_GEN_COUNT" -le $((_PLAY_COUNT + 1)) ] && echo "yes" || echo "no")"

# ── Pipeline overlap: next sentence pre-generated during playback ──
# With slow playback (0.5s) and fast gen (10ms), the pipeline should
# have the next sentence ready before the current one finishes.
rm -f "$_SIMDIR/play.log" "$_SIMDIR/gen.log"
TEXT="A. B. C." bash "$_SIMDIR/sim_cloud_slow.sh" "$_SIMDIR" 2>/dev/null

check "pipeline-overlap: all 3 sentences played" \
    "3" "$(grep -c '^PLAY:' "$_SIMDIR/play.log" 2>/dev/null || echo 0)"

check "pipeline-overlap: completed successfully" \
    "yes" "$(grep -q '^DONE' "$_SIMDIR/play.log" && echo "yes" || echo "no")"

rm -rf "$_SIMDIR"
unset -f _make_pipeline_sim _run_interrupt_test

# ── 57c. Regression: combined trap pattern continues after SIGTERM ──
#
# The OLD broken pattern: `trap cleanup EXIT INT TERM`
# On SIGTERM, bash runs cleanup but does NOT exit — the loop continues.
# The CORRECT pattern: separate traps with explicit `exit`.
# This test proves the bug exists and our fix prevents it.

section "Regression: combined trap bug"

_SIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/speak11_sim_XXXXXXXXXX")

# Script with BROKEN trap pattern (combined)
cat > "$_SIMDIR/broken_trap.sh" << 'SIMEOF'
#!/bin/bash
_LOG="$1"
cleanup() { set +e; echo "CLEANUP" >> "$_LOG"; }
trap cleanup EXIT INT TERM
for i in 1 2 3 4 5; do
    echo "ITER:$i" >> "$_LOG"
    sleep 0.5 &
    wait $! 2>/dev/null || true
done
echo "FINISHED" >> "$_LOG"
SIMEOF
chmod +x "$_SIMDIR/broken_trap.sh"

# Script with CORRECT trap pattern (separate)
cat > "$_SIMDIR/correct_trap.sh" << 'SIMEOF'
#!/bin/bash
_LOG="$1"
cleanup() { set +e; echo "CLEANUP" >> "$_LOG"; }
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
for i in 1 2 3 4 5; do
    echo "ITER:$i" >> "$_LOG"
    sleep 0.5 &
    wait $! 2>/dev/null || true
done
echo "FINISHED" >> "$_LOG"
SIMEOF
chmod +x "$_SIMDIR/correct_trap.sh"

# Run broken script, kill after first iteration
rm -f "$_SIMDIR/broken.log"
bash "$_SIMDIR/broken_trap.sh" "$_SIMDIR/broken.log" &
_PID=$!
for _i in $(seq 1 40); do
    grep -q 'ITER:1' "$_SIMDIR/broken.log" 2>/dev/null && break
    sleep 0.05
done
kill "$_PID" 2>/dev/null
wait "$_PID" 2>/dev/null || true
sleep 0.2

_BROKEN_ITERS=$(grep -c '^ITER:' "$_SIMDIR/broken.log" 2>/dev/null || echo 0)
check "broken trap: script continues after SIGTERM (iterations > 1)" \
    "yes" "$([ "$_BROKEN_ITERS" -gt 1 ] && echo "yes" || echo "no")"

# Run correct script, kill after first iteration
rm -f "$_SIMDIR/correct.log"
bash "$_SIMDIR/correct_trap.sh" "$_SIMDIR/correct.log" &
_PID=$!
for _i in $(seq 1 40); do
    grep -q 'ITER:1' "$_SIMDIR/correct.log" 2>/dev/null && break
    sleep 0.05
done
kill "$_PID" 2>/dev/null
wait "$_PID" 2>/dev/null || true
sleep 0.2

_CORRECT_ITERS=$(grep -c '^ITER:' "$_SIMDIR/correct.log" 2>/dev/null || echo 0)
check "correct trap: script stops on SIGTERM (iterations <= 2)" \
    "yes" "$([ "$_CORRECT_ITERS" -le 2 ] && echo "yes" || echo "no")"

check "correct trap: did not reach FINISHED" \
    "no" "$(grep -q 'FINISHED' "$_SIMDIR/correct.log" 2>/dev/null && echo "yes" || echo "no")"

check "correct trap: cleanup handler ran" \
    "yes" "$(grep -q 'CLEANUP' "$_SIMDIR/correct.log" 2>/dev/null && echo "yes" || echo "no")"

rm -rf "$_SIMDIR"

# ── 57d. Regression: cleanup idempotency ─────────────────────────
#
# cleanup() may run twice on INT/TERM (once in the trap, once via EXIT).
# All operations must be safe to repeat without errors.

section "Regression: cleanup idempotency"

_SIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/speak11_sim_XXXXXXXXXX")

(
    set +e
    TMP_FILE="$_SIMDIR/audio.wav"
    TMP_DIR="$_SIMDIR/tmpdir"
    _PREV_TMP_FILE="$_SIMDIR/prev.wav"
    _PREV_TMP_DIR="$_SIMDIR/prevdir"
    PID_FILE="$_SIMDIR/tts.pid"
    STATUS_FILE="$_SIMDIR/status"
    PLAY_PID=""
    _CURL_PID=""
    _DAEMON_PID=""

    touch "$TMP_FILE" "$_PREV_TMP_FILE"
    mkdir -p "$TMP_DIR" "$_PREV_TMP_DIR"
    echo "$$" > "$PID_FILE"

    # Define cleanup matching speak.sh
    cleanup() {
        set +e
        [ -n "$_CURL_PID" ] && kill "$_CURL_PID" 2>/dev/null
        [ -n "$_DAEMON_PID" ] && { pkill -P "$_DAEMON_PID" 2>/dev/null; kill "$_DAEMON_PID" 2>/dev/null; }
        [ -n "$PLAY_PID" ] && kill "$PLAY_PID" 2>/dev/null
        rm -f "$TMP_FILE" "$_PREV_TMP_FILE" "${TMP_FILE}.code"
        [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
        [ -n "$_PREV_TMP_DIR" ] && rm -rf "$_PREV_TMP_DIR"
        [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE"
    }

    # Call cleanup TWICE — simulating INT/TERM + EXIT
    cleanup
    cleanup

    echo "ok"
) > "$_SIMDIR/result" 2>"$_SIMDIR/stderr"

check "double cleanup: no crash" \
    "ok" "$(cat "$_SIMDIR/result" 2>/dev/null)"

check "double cleanup: no errors on stderr" \
    "0" "$(wc -l < "$_SIMDIR/stderr" 2>/dev/null | tr -d ' ')"

rm -rf "$_SIMDIR"

# ── 57e. Regression: STATUS_FILE offset values for multi-sentence ──
#
# The respeak position bug: without correct offsets in STATUS_FILE,
# Swift maps progress through current sentence to the full text length.
# Verify that for multi-sentence text, the last STATUS_FILE contains
# the offset of the LAST sentence, not 0 or a full-text value.

section "Regression: STATUS_FILE sentence offsets"

_STUBS=$(mktemp -d)
_TESTTMP=$(mktemp -d)
printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
cat > "$_STUBS/afinfo" << 'STUB'
#!/bin/bash
echo "estimated duration: 2.000000 sec"
STUB
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

# 3 sentences: "Alpha. Beta. Gamma." → offsets 0, 7, 13
echo "Alpha. Beta. Gamma." | \
    env PATH="$_STUBS:$PATH" VENV_PYTHON="$_STUBS/python3" TMPDIR="$_TESTTMP" TTS_BACKEND=auto \
    bash "$SPEAK_SH" >/dev/null 2>&1 || true

# STATUS_FILE should contain the LAST sentence's offset and length.
# "Gamma." starts at offset 13, length 6.
_STATUS_OFFSET=$(sed -n '3p' "$_TESTTMP/speak11_status" 2>/dev/null)
_STATUS_LEN=$(sed -n '4p' "$_TESTTMP/speak11_status" 2>/dev/null)

check "STATUS_FILE offset is last sentence (13, not 0)" \
    "13" "$_STATUS_OFFSET"

check "STATUS_FILE length is last sentence (6)" \
    "6" "$_STATUS_LEN"

# Verify offset is NOT 0 (which would indicate the old bug where offsets
# were not passed through the pipeline)
check "STATUS_FILE offset is not zero (regression guard)" \
    "yes" "$([ "${_STATUS_OFFSET:-0}" -gt 0 ] 2>/dev/null && echo "yes" || echo "no")"

rm -rf "$_STUBS" "$_TESTTMP"

# Repeat for local backend: verify offsets work in the local pipeline too
_STUBS=$(mktemp -d)
_TESTTMP=$(mktemp -d)
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
cat > "$_STUBS/afinfo" << 'STUB'
#!/bin/bash
echo "estimated duration: 2.000000 sec"
STUB
cat > "$_STUBS/python3" << 'PYSTUB'
#!/bin/bash
for arg in "$@"; do
    # Fake TTS: create minimal WAV file
    if [ "$arg" = "mlx_audio.tts.generate" ]; then
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
    # Daemon: exit non-zero so speak.sh falls back to direct invocation
    case "$arg" in *tts_server.py) exit 1 ;; esac
done
# Pass through to real python3 for split_sentences, normalize_text etc.
/usr/bin/python3 "$@"
PYSTUB
chmod +x "$_STUBS"/*

echo "Alpha. Beta. Gamma." | \
    env PATH="$_STUBS:$PATH" VENV_PYTHON="$_STUBS/python3" TMPDIR="$_TESTTMP" TTS_BACKEND=local LOCAL_VOICE=af_heart \
    bash "$SPEAK_SH" >/dev/null 2>&1 || true

_STATUS_OFFSET=$(sed -n '3p' "$_TESTTMP/speak11_status" 2>/dev/null)
_STATUS_LEN=$(sed -n '4p' "$_TESTTMP/speak11_status" 2>/dev/null)

check "local: STATUS_FILE offset is last sentence (13)" \
    "13" "$_STATUS_OFFSET"

check "local: STATUS_FILE length is last sentence (6)" \
    "6" "$_STATUS_LEN"

rm -rf "$_STUBS" "$_TESTTMP"

# ── 58. Simulation: toggle kills process and cleans up ────────────

section "Simulation: toggle kills all processes"

# Run the entire toggle simulation in a separate bash process to isolate
# signal handling and job control from the test runner.
_SIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/speak11_sim_XXXXXXXXXX")

bash -c '
set +e
_SIMDIR="$1"
_LOG="$_SIMDIR/play.log"
_PID="$_SIMDIR/tts.pid"

# Create a slow fake TTS script
cat > "$_SIMDIR/sim_slow.sh" << '\''INNER'\''
#!/bin/bash
_SIMDIR="$1"
echo "$$" > "$_SIMDIR/tts.pid"
cleanup() {
    set +e
    pkill -P $$ 2>/dev/null
    echo "CLEANUP" >> "$_SIMDIR/play.log"
    [ -f "$_SIMDIR/tts.pid" ] && [ "$(cat "$_SIMDIR/tts.pid" 2>/dev/null)" = "$$" ] && rm -f "$_SIMDIR/tts.pid"
}
trap cleanup EXIT INT TERM
echo "PLAY" >> "$_SIMDIR/play.log"
sleep 30 &
_BG=$!
sleep 30   # simulate blocking API call
wait "$_BG" 2>/dev/null || true
INNER
chmod +x "$_SIMDIR/sim_slow.sh"

# Start it
bash "$_SIMDIR/sim_slow.sh" "$_SIMDIR" &
_SLOW=$!
disown $_SLOW 2>/dev/null

# Wait for it to be ready
for i in $(seq 1 30); do
    [ -f "$_PID" ] && grep -q PLAY "$_LOG" 2>/dev/null && break
    sleep 0.1
done

# Toggle: kill children then parent
_TARGET=$(cat "$_PID" 2>/dev/null)
[ -n "$_TARGET" ] && {
    pkill -P "$_TARGET" 2>/dev/null
    kill "$_TARGET" 2>/dev/null
    for i in 1 2 3 4 5; do
        kill -0 "$_TARGET" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$_TARGET" 2>/dev/null && kill -9 "$_TARGET" 2>/dev/null
}
sleep 0.3

# Report results
kill -0 "$_TARGET" 2>/dev/null && echo "target:alive" || echo "target:dead"
grep -q CLEANUP "$_LOG" 2>/dev/null && echo "cleanup:yes" || echo "cleanup:no"
[ -f "$_PID" ] && echo "pidfile:exists" || echo "pidfile:gone"

wait "$_SLOW" 2>/dev/null
' _ "$_SIMDIR" > "$_SIMDIR/result" 2>/dev/null

check "sim-toggle: target process is dead" \
    "yes" "$(grep -q 'target:dead' "$_SIMDIR/result" && echo "yes" || echo "no")"

check "sim-toggle: cleanup handler ran" \
    "yes" "$(grep -q 'cleanup:yes' "$_SIMDIR/result" && echo "yes" || echo "no")"

check "sim-toggle: PID file was removed by cleanup" \
    "yes" "$(grep -q 'pidfile:gone' "$_SIMDIR/result" && echo "yes" || echo "no")"

rm -rf "$_SIMDIR"

# ── 59. Simulation: rapid re-invocation doesn't overlap ──────────

section "Simulation: no overlapping voices on rapid re-invoke"

_SIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/speak11_sim_XXXXXXXXXX")

bash -c '
set +e
_SIMDIR="$1"
_LOG="$_SIMDIR/play.log"
_PID="$_SIMDIR/tts.pid"

cat > "$_SIMDIR/sim_voice.sh" << '\''INNER'\''
#!/bin/bash
_SIMDIR="$1"
echo "$$" > "$_SIMDIR/tts.pid"
cleanup() {
    set +e
    pkill -P $$ 2>/dev/null
    [ -f "$_SIMDIR/tts.pid" ] && [ "$(cat "$_SIMDIR/tts.pid" 2>/dev/null)" = "$$" ] && rm -f "$_SIMDIR/tts.pid"
}
trap cleanup EXIT INT TERM
echo "START:$$" >> "$_SIMDIR/play.log"
sleep 30 &
wait $! 2>/dev/null || true
echo "END:$$" >> "$_SIMDIR/play.log"
INNER
chmod +x "$_SIMDIR/sim_voice.sh"

# Instance A
bash "$_SIMDIR/sim_voice.sh" "$_SIMDIR" &
A=$!
disown $A 2>/dev/null
for i in $(seq 1 30); do [ -f "$_PID" ] && break; sleep 0.1; done

# Instance B: toggle-kills A
OLD=$(cat "$_PID" 2>/dev/null)
[ -n "$OLD" ] && {
    pkill -P "$OLD" 2>/dev/null
    kill "$OLD" 2>/dev/null
    for i in 1 2 3 4 5; do kill -0 "$OLD" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$OLD" 2>/dev/null && kill -9 "$OLD" 2>/dev/null
    rm -f "$_PID"
}
sleep 0.1

# Instance C
bash "$_SIMDIR/sim_voice.sh" "$_SIMDIR" &
C=$!
disown $C 2>/dev/null
for i in $(seq 1 30); do [ -f "$_PID" ] && break; sleep 0.1; done
sleep 0.1

# Report
kill -0 "$A" 2>/dev/null && echo "a:alive" || echo "a:dead"
kill -0 "$C" 2>/dev/null && echo "c:alive" || echo "c:dead"
STARTS=$(grep -c "^START:" "$_LOG" 2>/dev/null || true)
echo "starts:$STARTS"
PIDVAL=$(cat "$_PID" 2>/dev/null)
[ "$PIDVAL" = "$C" ] && echo "pidowner:c" || echo "pidowner:other"

# Cleanup
kill "$C" 2>/dev/null; wait "$C" 2>/dev/null; wait "$A" 2>/dev/null
' _ "$_SIMDIR" > "$_SIMDIR/result" 2>/dev/null

check "sim-overlap: instance A is dead" \
    "yes" "$(grep -q 'a:dead' "$_SIMDIR/result" && echo "yes" || echo "no")"

check "sim-overlap: instance C is alive" \
    "yes" "$(grep -q 'c:alive' "$_SIMDIR/result" && echo "yes" || echo "no")"

check "sim-overlap: exactly 2 instances started" \
    "yes" "$(grep -q 'starts:2' "$_SIMDIR/result" && echo "yes" || echo "no")"

check "sim-overlap: PID file contains C's PID" \
    "yes" "$(grep -q 'pidowner:c' "$_SIMDIR/result" && echo "yes" || echo "no")"

rm -rf "$_SIMDIR"

# ── 60. 429 + install-local fallback exits 0 on success ──────────

section "429 + install-local fallback exit code"

# When ElevenLabs returns 429, user installs local TTS, and local TTS
# succeeds, speak.sh should exit 0 (not fall through to exit 1).
_STUBS=$(mktemp -d)
_LOG="$_STUBS/osascript.log"

# security: return fake API key
printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"
# afplay: no-op
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
# afinfo: fake duration
cat > "$_STUBS/afinfo" << 'STUB'
#!/bin/bash
echo "estimated duration: 1.000000 sec"
STUB
# uname: return arm64 (required for install-local offer)
printf '#!/bin/bash\necho "arm64"\n' > "$_STUBS/uname"

# osascript: return "Install Local TTS" for the quota dialog
cat > "$_STUBS/osascript" << STUB
#!/bin/bash
case "\$*" in *"volume settings"*) echo "false"; exit 0;; esac
echo "\$*" >> "$_LOG"
echo "Install Local TTS"
STUB

# curl: return 429
cat > "$_STUBS/curl" << 'CURLSTUB'
#!/bin/bash
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && printf '{"detail":"quota_exceeded"}' > "$a"
    prev="$a"
done
printf "429"
CURLSTUB

# bash stub: intercept install-local.sh call and succeed
cat > "$_STUBS/bash" << STUB
#!/bin/bash
case "\$1" in
    *install-local*) exit 0 ;;  # simulate successful install
    *) /bin/bash "\$@" ;;
esac
STUB

# python3: handle mlx_audio (local TTS succeeds), block daemon, pass through json
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
    case "\$arg" in *tts_server.py) exit 1;; esac
done
/usr/bin/python3 "\$@"
STUB
chmod +x "$_STUBS"/*

check_exit "429 + install-local + local TTS succeeds → exits 0" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" VENV_PYTHON="'"$_STUBS"'/python3" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=elevenlabs bash "'"$SPEAK_SH"'"'

rm -rf "$_STUBS"

# ── 52. Empty text check performance ─────────────────────────────

section "Empty text check (no O(n^2) bash substitution)"

# speak.sh must NOT use ${TEXT//[[:space:]]/} which is O(n^2) in bash 3.2
# for large texts.  Use [[ =~ ]] instead.  (A comment mentioning the pattern is OK.)
check "speak.sh: no \${TEXT//[[:space:]]/} pattern in code" \
    "0" "$(grep -v '^ *#' "$SPEAK_SH" | grep -c 'TEXT//\[' || true)"

# speak.sh uses [[ =~ ]] regex match (builtin, no fork, short-circuits)
check "speak.sh: uses [[ =~ ]] for whitespace check" \
    "yes" "$(grep -q '\[\[ "\$TEXT" =~ \[^' "$SPEAK_SH" && echo "yes" || echo "no")"

# Functional: large text (6KB) with pipe completes in under 5 seconds
_STUBS=$(mktemp -d)
_TESTTMP=$(mktemp -d)
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
printf '#!/bin/bash\necho "estimated duration: 2.000000 sec"\n' > "$_STUBS/afinfo"
cat > "$_STUBS/python3" << PYSTUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        printf "RIFF" > "speak11.wav"
        exit 0
    fi
    case "\$arg" in *tts_server.py) exit 1;; esac
done
exit 1
PYSTUB
chmod +x "$_STUBS"/*

# Generate 6KB of text
_BIGTEXT=""
for _i in $(seq 1 100); do
    _BIGTEXT="${_BIGTEXT}This is sentence number ${_i} in a big text. "
done

_T0=$(date +%s)
printf '%s' "$_BIGTEXT" | env PATH="$_STUBS:$PATH" VENV_PYTHON="$_STUBS/python3" \
    TMPDIR="$_TESTTMP" TTS_BACKEND=local LOCAL_VOICE=af_heart \
    timeout 5 /bin/bash "$SPEAK_SH" >/dev/null 2>&1 || true
_T1=$(date +%s)
_ELAPSED=$(( ${_T1:-0} - ${_T0:-0} ))

check "large text (6KB) piped: completes within 5s (was 25s)" \
    "yes" "$([ "$_ELAPSED" -le 5 ] && echo "yes" || echo "no ($_ELAPSED s)")"

rm -rf "$_STUBS" "$_TESTTMP"

# ── 53. STATUS_FILE fractional epoch ─────────────────────────────

section "STATUS_FILE fractional epoch"

# STATUS_FILE epoch must be fractional (from _BASE_EPOCH which is set with perl Time::HiRes)
check "speak.sh: _BASE_EPOCH set with perl Time::HiRes" \
    "yes" "$(grep -q '_BASE_EPOCH=.*perl.*Time::HiRes' "$SPEAK_SH" && echo "yes" || echo "no")"

# Functional: STATUS_FILE first line has decimal point
_STUBS=$(mktemp -d)
_TESTTMP=$(mktemp -d)
printf '#!/bin/bash\necho "fake-key"\n' > "$_STUBS/security"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/afplay"
printf '#!/bin/bash\necho "estimated duration: 5.000000 sec"\n' > "$_STUBS/afinfo"
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

echo "Hello world." | \
    env PATH="$_STUBS:$PATH" VENV_PYTHON="$_STUBS/python3" TMPDIR="$_TESTTMP" TTS_BACKEND=auto \
    bash "$SPEAK_SH" >/dev/null 2>&1 || true

_STATUS_EPOCH=$(head -1 "$_TESTTMP/speak11_status" 2>/dev/null || echo "0")
check "STATUS_FILE epoch has fractional part" \
    "yes" "$(echo "$_STATUS_EPOCH" | grep -q '\.' && echo "yes" || echo "no (got: $_STATUS_EPOCH)")"

rm -rf "$_STUBS" "$_TESTTMP"

# ── 54. Respeak: ratio > 0.95 must check end of text ────────────

section "Respeak: ratio > 0.95 end-of-text check"

# Swift must NOT return full text just because ratio > 0.95 for the current sentence.
# It should only restart from beginning if approxCharPos is near end of full text.
check "Swift: no early return on ratio > 0.95 alone" \
    "no" "$(grep -q 'ratio > 0.95 { return text }' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# The ratio check should be AFTER computing approxCharPos, checking against text.count
check "Swift: end-of-text check uses approxCharPos" \
    "yes" "$(grep -q 'approxCharPos.*text.count\|resumePos.*text.count' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# ── 55. gc/cache-clear moved to idle time ────────────────────────

section "Daemon: gc/cache-clear after full text"

TTS_SERVER="$SCRIPT_DIR/tts_server.py"

# generate_audio try block (success path) should NOT have gc.collect or clear_cache
_GEN_TRY=$(awk '/^def generate_audio/{f=1} f{print} f && /^def [a-z_]/ && !/^def generate_audio/{f=0}' "$TTS_SERVER" | \
    awk '/^    try:/{f=1} f{print} f && /^    except/{f=0}')
check "generate_audio: no gc.collect in success path" \
    "0" "$(echo "$_GEN_TRY" | grep -c 'gc.collect' || true)"
check "generate_audio: no clear_cache in success path" \
    "0" "$(echo "$_GEN_TRY" | grep -c 'clear_cache' || true)"

# gc/cache cleanup should happen in handle_client (after response is sent)
_HC_BODY=$(awk '/^def handle_client/{f=1} f{print} f && /^def [a-z_]/ && !/^def handle_client/{f=0}' "$TTS_SERVER")
check "handle_client: gc.collect after response" \
    "yes" "$(echo "$_HC_BODY" | grep -q 'gc.collect' && echo "yes" || echo "no")"
check "handle_client: clear_cache after response" \
    "yes" "$(echo "$_HC_BODY" | grep -q 'clear_cache' && echo "yes" || echo "no")"

# ── 56. Bash JSON encoding (no Python fork per sentence) ──────────

section "Bash JSON encoding (no Python fork per sentence)"

# speak.sh must define a json_encode function (pure bash, no fork)
check "speak.sh: json_encode function defined" \
    "yes" "$(grep -q '^json_encode()' "$SPEAK_SH" && echo "yes" || echo "no")"

# run_elevenlabs_tts must NOT fork python3 for JSON encoding
check "speak.sh: run_elevenlabs_tts uses json_encode (no python3 -c json)" \
    "0" "$(sed -n '/^run_elevenlabs_tts() *{/,/^[a-z_]*() *{/p' "$SPEAK_SH" | grep -c 'python3 -c.*json' || true)"

# json_encode must handle quotes, backslashes, newlines, tabs
# Source the function from speak.sh (it's pure bash, safe to source this snippet)
eval "$(awk '/^json_encode\(\)/,/^}/' "$SPEAK_SH")" 2>/dev/null || true

if type json_encode &>/dev/null; then
    check "json_encode: plain text" \
        '"Hello world"' "$(json_encode "Hello world")"

    check "json_encode: quotes escaped" \
        '"He said \"hi\""' "$(json_encode 'He said "hi"')"

    check "json_encode: backslash escaped" \
        '"path\\to\\file"' "$(json_encode 'path\to\file')"

    check "json_encode: newline escaped" \
        '"line1\nline2"' "$(json_encode $'line1\nline2')"

    check "json_encode: tab escaped" \
        '"col1\tcol2"' "$(json_encode $'col1\tcol2')"

    check "json_encode: carriage return escaped" \
        '"a\rb"' "$(json_encode $'a\rb')"

    # Verify output is valid JSON by round-tripping through python
    _TEST_INPUT=$'She said "hello" and walked away.\nThen she turned back.'
    _JSON_OUT=$(json_encode "$_TEST_INPUT")
    check "json_encode: valid JSON (python round-trip)" \
        "yes" "$(echo "$_JSON_OUT" | python3 -c "import json,sys; json.loads(sys.stdin.read().strip())" 2>/dev/null && echo "yes" || echo "no")"
else
    check "json_encode: plain text" '"Hello world"' "function not found"
    check "json_encode: quotes escaped" '"He said \"hi\""' "function not found"
    check "json_encode: backslash escaped" '"path\\to\\file"' "function not found"
    check "json_encode: newline escaped" '"line1\nline2"' "function not found"
    check "json_encode: tab escaped" '"col1\tcol2"' "function not found"
    check "json_encode: carriage return escaped" '"a\rb"' "function not found"
    check "json_encode: valid JSON (python round-trip)" "yes" "function not found"
fi

# ── 57. Daemon request via Unix socket ────────────────────────────

section "Daemon request via Unix socket"

_TDR_BODY=$(sed -n '/^tts_daemon_request() *{/,/^[a-z_]*() *{/p' "$SPEAK_SH")

# Must use python socket (nc -U on macOS drops responses from Unix sockets)
check "speak.sh: tts_daemon_request uses python socket" \
    "yes" "$(echo "$_TDR_BODY" | grep -q 'socket.AF_UNIX\|SOCK_STREAM' && echo "yes" || echo "no")"

# JSON request built with json_encode (bash, no extra fork)
check "speak.sh: tts_daemon_request uses json_encode for request" \
    "yes" "$(echo "$_TDR_BODY" | grep -q 'json_encode' && echo "yes" || echo "no")"

# Response parsing uses bash string ops
check "speak.sh: tts_daemon_request parses response without jq" \
    "yes" "$(echo "$_TDR_BODY" | grep -q 'audio_file.*%%\|audio_file.*##' && echo "yes" || echo "no")"

# ── 58. WAV duration without afinfo (local mode) ─────────────────

section "WAV duration without afinfo (local mode)"

# play_audio should compute duration from WAV header for local files
# instead of forking afinfo + awk
check "speak.sh: play_audio uses stat for WAV duration" \
    "yes" "$(sed -n '/^play_audio() *{/,/^[a-z_]*() *{/p' "$SPEAK_SH" | grep -q 'wav_duration\|stat -f' && echo "yes" || echo "no")"

# Functional: create a real WAV file and verify duration calculation
_WAV_TMP=$(mktemp "${TMPDIR:-/tmp/}speak11_test_XXXXXXXXXX.wav")
# Create a minimal WAV file: 24kHz, 16-bit, mono, 2.4 seconds = 115200 samples
# Header: 44 bytes + data: 230400 bytes (115200 samples * 2 bytes) = 230444 total
python3 -c "
import struct, sys
sr = 24000; ch = 1; bps = 16; n = 115200
data_size = n * ch * (bps // 8)
with open(sys.argv[1], 'wb') as f:
    f.write(b'RIFF')
    f.write(struct.pack('<I', 36 + data_size))
    f.write(b'WAVEfmt ')
    f.write(struct.pack('<IHHIIHH', 16, 1, ch, sr, sr*ch*(bps//8), ch*(bps//8), bps))
    f.write(b'data')
    f.write(struct.pack('<I', data_size))
    f.write(b'\x00' * data_size)
" "$_WAV_TMP"

# Extract the WAV duration function and test it
eval "$(awk '/^wav_duration\(\)/,/^}/' "$SPEAK_SH")" 2>/dev/null || true
_CALC_DUR=$(type wav_duration &>/dev/null && wav_duration "$_WAV_TMP" 2>/dev/null || echo "fail")
# Should be close to 4.8 (230400 bytes of data / 48000 bytes per second)
# Actually: data_size=230400, bytes_per_sec=24000*1*2=48000, dur=230400/48000=4.800
check "wav_duration: calculates correct duration for 24kHz WAV" \
    "yes" "$(echo "$_CALC_DUR" | awk '{if ($1 >= 4.5 && $1 <= 5.1) print "yes"; else print "no"}')"
rm -f "$_WAV_TMP"

# ── 59. Tighter kill-wait loop ───────────────────────────────────

section "Toggle: tighter kill-wait loop"

# The kill-wait loop should use sleep 0.05 (not 0.1) for faster toggle response
check "speak.sh: kill-wait uses sleep 0.05" \
    "yes" "$(grep -q 'sleep 0.05' "$SPEAK_SH" && echo "yes" || echo "no")"

# Loop should check more times (10 iterations at 0.05s = 500ms budget)
check "speak.sh: kill-wait has 10 iterations" \
    "yes" "$(grep -q 'for _i in 1 2 3 4 5 6 7 8 9 10' "$SPEAK_SH" && echo "yes" || echo "no")"

# ── 60. Zero-fork epoch in play_audio ─────────────────────────────

section "Zero-fork epoch in play_audio (no per-sentence perl)"

# play_audio must NOT fork perl on every call — use cached epoch + $SECONDS
check "speak.sh: no perl fork in play_audio" \
    "0" "$(sed -n '/^play_audio() *{/,/^[a-z_]*() *{/p' "$SPEAK_SH" | grep -c 'perl' || true)"

# _BASE_EPOCH must be computed once before the pipeline loop
check "speak.sh: _BASE_EPOCH set before pipeline" \
    "yes" "$(grep -q '_BASE_EPOCH=' "$SPEAK_SH" && echo "yes" || echo "no")"

# play_audio should use SECONDS-based epoch (no fork)
check "speak.sh: play_audio uses SECONDS-based epoch" \
    "yes" "$(sed -n '/^play_audio() *{/,/^[a-z_]*() *{/p' "$SPEAK_SH" | grep -q 'SECONDS\|_BASE_EPOCH' && echo "yes" || echo "no")"

# ── 61. Zero-fork wav_duration ───────────────────────────────────

section "Zero-fork wav_duration (bash arithmetic, no bc)"

# wav_duration must NOT fork bc — use bash $(( )) arithmetic
check "speak.sh: wav_duration uses bash arithmetic (no bc)" \
    "0" "$(sed -n '/^wav_duration() *{/,/^}/p' "$SPEAK_SH" | grep -c '| *bc' || true)"

# Functional: verify wav_duration still calculates correct duration
eval "$(sed -n '/^wav_duration() *{/,/^}/p' "$SPEAK_SH")" 2>/dev/null || true
_WAV_TMP=$(mktemp "${TMPDIR:-/tmp/}speak11_test_XXXXXXXXXX.wav")
python3 -c "
import struct, sys
sr = 24000; ch = 1; bps = 16; n = 115200  # 4.8 seconds
data_size = n * ch * (bps // 8)
with open(sys.argv[1], 'wb') as f:
    f.write(b'RIFF')
    f.write(struct.pack('<I', 36 + data_size))
    f.write(b'WAVEfmt ')
    f.write(struct.pack('<IHHIIHH', 16, 1, ch, sr, sr*ch*(bps//8), ch*(bps//8), bps))
    f.write(b'data')
    f.write(struct.pack('<I', data_size))
    f.write(b'\x00' * data_size)
" "$_WAV_TMP"
if type wav_duration &>/dev/null; then
    _CALC_DUR=$(wav_duration "$_WAV_TMP" 2>/dev/null || echo "fail")
    # 230400 data bytes / 48000 bytes_per_sec = 4.800 seconds
    check "wav_duration: correct for 24kHz WAV (expect ~4.800)" \
        "yes" "$(echo "$_CALC_DUR" | awk '{if ($1 >= 4.5 && $1 <= 5.1) print "yes"; else print "no"}')"
else
    check "wav_duration: correct for 24kHz WAV (expect ~4.800)" "yes" "function not found"
fi
rm -f "$_WAV_TMP"

# ── 62. Respeak simulation ──────────────────────────────────────

section "Respeak: position-aware resumption (end-to-end simulation)"

# Simulate the full respeak pipeline:
# 1. speak.sh writes STATUS_FILE with per-sentence offset/len
# 2. Swift reads STATUS_FILE + TEXT_FILE, computes remaining text
# 3. Remaining text should start at roughly the correct sentence

_RESP_TMP=$(mktemp -d)
_RESP_TEXT="The morning light filtered through the kitchen window as she poured her first cup of coffee. Outside, the garden was coming alive with the first signs of spring and the birds were singing. She sat down at the table and opened her notebook to write. There were lists to make, plans to finalize, and a letter she had been meaning to write for weeks."

# Write TEXT_FILE
printf '%s' "$_RESP_TEXT" > "$_RESP_TMP/text"

# Simulate STATUS_FILE as if we're 50% through sentence 2
# Sentence 2: "Outside, the garden..." starts at offset 93, length 95
# ratio = 0.5 → approxCharPos = 93 + 95*0.5 ≈ 140
_now_epoch=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
_duration="4.000"
# elapsed = 2.0s → ratio = 2.0/4.0 = 0.5
_start_epoch=$(echo "$_now_epoch" | awk '{printf "%.3f", $1 - 2.0}')
printf '%s\n%s\n%s\n%s\n' "$_start_epoch" "$_duration" "93" "95" > "$_RESP_TMP/status"

# Run the Swift calculateRemainingText logic in a bash simulation
_sim_remaining() {
    local text="$1" status_file="$2"
    local lines start_time duration elapsed ratio
    IFS=$'\n' read -d '' -ra lines < "$status_file" || true
    start_time="${lines[0]}"
    duration="${lines[1]}"
    local char_offset="${lines[2]}"
    local sent_len="${lines[3]}"

    elapsed=$(echo "$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time') $start_time" | awk '{printf "%.3f", $1 - $2}')
    ratio=$(echo "$elapsed $duration" | awk '{r=$1/$2; if(r<0)r=0; if(r>1)r=1; printf "%.3f", r}')

    local text_len=${#text}
    [ "$text_len" -lt 100 ] && { echo "$text"; return; }

    local approx_pos
    if [ -n "$char_offset" ] && [ -n "$sent_len" ] && [ "$sent_len" -gt 0 ]; then
        approx_pos=$(echo "$char_offset $sent_len $ratio" | awk '{printf "%d", $1 + $2 * $3}')
    else
        approx_pos=$(echo "$text_len $ratio" | awk '{printf "%d", $1 * $2}')
    fi

    [ "$approx_pos" -ge $((text_len - 50)) ] && { echo "$text"; return; }

    # Find nearest sentence boundary at or after approx_pos
    local search_start=$((approx_pos > 20 ? approx_pos - 20 : 0))
    local tail="${text:$search_start}"
    local i best_pos=""
    for (( i=0; i<${#tail}; i++ )); do
        local abs_pos=$((search_start + i))
        [ "$abs_pos" -lt "$approx_pos" ] && continue
        local prev_char="${tail:$((i-1)):1}"
        local cur_char="${tail:$i:1}"
        if [ "$i" -gt 0 ] && [[ "$prev_char" == [.!?] ]] && [[ "$cur_char" == [[:space:]] ]]; then
            best_pos=$abs_pos
            break
        fi
        [ $((abs_pos - approx_pos)) -gt 200 ] && { best_pos=$approx_pos; break; }
    done
    [ -z "$best_pos" ] && best_pos=$approx_pos
    echo "${text:$best_pos}"
}

_REMAINING=$(_sim_remaining "$_RESP_TEXT" "$_RESP_TMP/status")

# The remaining text should NOT be the full text (that would mean restart)
check "respeak: remaining text is not full text (no restart)" \
    "yes" "$([ "$_REMAINING" != "$_RESP_TEXT" ] && echo "yes" || echo "no")"

# The remaining text should contain sentence 3+ ("She sat down" or "There were")
check "respeak: remaining text contains later sentences" \
    "yes" "$(echo "$_REMAINING" | grep -q 'She sat down\|There were' && echo "yes" || echo "no")"

# The remaining text should NOT start with sentence 1
check "respeak: remaining text does not contain first sentence" \
    "no" "$(echo "$_REMAINING" | grep -q 'morning light' && echo "yes" || echo "no")"

# Simulate near end of last sentence: offset=249, len=98, 90% through
_start_epoch2=$(echo "$_now_epoch" | awk '{printf "%.3f", $1 - 3.6}')
printf '%s\n%s\n%s\n%s\n' "$_start_epoch2" "$_duration" "249" "98" > "$_RESP_TMP/status"
_REMAINING2=$(_sim_remaining "$_RESP_TEXT" "$_RESP_TMP/status")

# Near end of last sentence should return full text (restart from beginning)
check "respeak: near end of text restarts from beginning" \
    "yes" "$([ "$_REMAINING2" = "$_RESP_TEXT" ] && echo "yes" || echo "no")"

# Simulate with 2-line STATUS_FILE (fallback, no offset/len)
printf '%s\n%s\n' "$_start_epoch" "$_duration" > "$_RESP_TMP/status"
_REMAINING3=$(_sim_remaining "$_RESP_TEXT" "$_RESP_TMP/status")

# Fallback should still work (uses text.count * ratio)
check "respeak: 2-line STATUS_FILE fallback works" \
    "yes" "$([ -n "$_REMAINING3" ] && echo "yes" || echo "no")"

rm -rf "$_RESP_TMP"

# ── 63. Fast mute check (CoreAudio CLI tool) ─────────────────────

section "Fast mute check (CoreAudio CLI tool)"

_AUDIO_SWIFT="$SCRIPT_DIR/speak11-audio.swift"

check "speak11-audio.swift exists" \
    "yes" "$([ -f "$_AUDIO_SWIFT" ] && echo "yes" || echo "no")"

check "speak11-audio.swift imports CoreAudio" \
    "yes" "$(grep -q 'import CoreAudio' "$_AUDIO_SWIFT" 2>/dev/null && echo "yes" || echo "no")"

check "speak11-audio.swift uses kAudioDevicePropertyMute" \
    "yes" "$(grep -q 'kAudioDevicePropertyMute' "$_AUDIO_SWIFT" 2>/dev/null && echo "yes" || echo "no")"

check "speak11-audio.swift handles is-muted subcommand" \
    "yes" "$(grep -q 'is-muted' "$_AUDIO_SWIFT" 2>/dev/null && echo "yes" || echo "no")"

check "speak11-audio.swift handles unmute subcommand" \
    "yes" "$(grep -q '"unmute"' "$_AUDIO_SWIFT" 2>/dev/null && echo "yes" || echo "no")"

check "speak.sh: mute check uses speak11-audio" \
    "yes" "$(grep -q 'speak11-audio' "$SPEAK_SH" && grep -q '_AUDIO_TOOL.*is-muted' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: unmute uses speak11-audio" \
    "yes" "$(grep -q 'speak11-audio' "$SPEAK_SH" && grep -q '_AUDIO_TOOL.*unmute' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: osascript mute fallback for missing binary" \
    "yes" "$(grep -q 'output muted of (get volume settings)' "$SPEAK_SH" && echo "yes" || echo "no")"

check "install.command: compiles speak11-audio.swift" \
    "yes" "$(grep -q 'speak11-audio.swift' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# In-process mute check in Speak11.swift (no fork when launched from app)
check "Speak11.swift: imports CoreAudio" \
    "yes" "$(grep -q 'import CoreAudio' "$SCRIPT_DIR/Speak11.swift" && echo "yes" || echo "no")"

check "Speak11.swift: has isOutputMuted function" \
    "yes" "$(grep -q 'func isOutputMuted' "$SCRIPT_DIR/Speak11.swift" && echo "yes" || echo "no")"

check "Speak11.swift: has unmuteOutput function" \
    "yes" "$(grep -q 'func unmuteOutput' "$SCRIPT_DIR/Speak11.swift" && echo "yes" || echo "no")"

check "Speak11.swift: checks mute in runSpeak" \
    "yes" "$(grep -q 'isOutputMuted' "$SCRIPT_DIR/Speak11.swift" && echo "yes" || echo "no")"

check "Speak11.swift: passes SPEAK11_MUTE_CHECKED to speak.sh" \
    "yes" "$(grep -q 'SPEAK11_MUTE_CHECKED' "$SCRIPT_DIR/Speak11.swift" && echo "yes" || echo "no")"

check "speak.sh: skips mute check when SPEAK11_MUTE_CHECKED=1" \
    "yes" "$(grep -q 'SPEAK11_MUTE_CHECKED' "$SPEAK_SH" && echo "yes" || echo "no")"

# Cmd+V paste support: dialogs with text fields must use .regular activation policy
check "Speak11.swift: API key dialog enables paste (regular activation)" \
    "yes" "$(awk '/func showAPIKeyDialog/,/^    }/' "$SCRIPT_DIR/Speak11.swift" | grep -q 'setActivationPolicy(.regular)' && echo "yes" || echo "no")"

check "Speak11.swift: custom voice dialog enables paste (regular activation)" \
    "yes" "$(awk '/func customVoice/,/^    }/' "$SCRIPT_DIR/Speak11.swift" | grep -q 'setActivationPolicy(.regular)' && echo "yes" || echo "no")"

check "Speak11.swift: dialogs restore accessory policy via defer" \
    "yes" "$(grep -c 'defer.*setActivationPolicy(.accessory)' "$SCRIPT_DIR/Speak11.swift" | awk '{print ($1 >= 2) ? "yes" : "no"}')"

# API key validation
check "Speak11.swift: validateAPIKey function exists" \
    "yes" "$(grep -q 'func validateAPIKey' "$SCRIPT_DIR/Speak11.swift" && echo "yes" || echo "no")"

check "Speak11.swift: validates key via /v1/user/subscription" \
    "yes" "$(awk '/func validateAPIKey/,/^    }/' "$SCRIPT_DIR/Speak11.swift" | grep -q 'v1/user/subscription' && echo "yes" || echo "no")"

check "Speak11.swift: showAPIKeyDialog calls validateAPIKey" \
    "yes" "$(awk '/func showAPIKeyDialog/,/^    }/' "$SCRIPT_DIR/Speak11.swift" | grep -q 'validateAPIKey' && echo "yes" || echo "no")"

check "Speak11.swift: showAPIKeyDialog loops on validation failure" \
    "yes" "$(awk '/func showAPIKeyDialog/,/^    }/' "$SCRIPT_DIR/Speak11.swift" | grep -q 'while true' && echo "yes" || echo "no")"

check "install.command: validate_api_key function exists" \
    "yes" "$(grep -q '^validate_api_key()' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command: validates via /v1/user/subscription" \
    "yes" "$(grep -q 'v1/user/subscription' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

check "install.command: prompt_api_key loops on failure" \
    "yes" "$(grep -q 'while true' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# ── Text normalization (PDF cleanup) ─────────────────────────────

section "Text normalization (PDF cleanup)"

# Source normalize_text from speak.sh; use venv python for ftfy support
VENV_PYTHON="${VENV_PYTHON:-$HOME/.local/share/speak11/venv/bin/python3}"
eval "$(awk '/^normalize_text\(\)/,/^}/' "$SPEAK_SH")" 2>/dev/null || true

if type normalize_text &>/dev/null; then
    # Hyphenation
    check "normalize: rejoin hyphenated word split" \
        "information" "$(normalize_text $'infor-\nmation')"

    check "normalize: hyphenation mid-sentence" \
        "end-of-line hyphenation works" "$(normalize_text $'end-of-line hy-\nphenation works')"

    # Line break rejoining
    check "normalize: rejoin mid-sentence line break" \
        "The quick brown fox jumped." "$(normalize_text $'The quick brown\nfox jumped.')"

    check "normalize: preserve break after period" \
        $'First sentence.\nSecond sentence.' "$(normalize_text $'First sentence.\nSecond sentence.')"

    check "normalize: preserve paragraph breaks (double newline)" \
        $'Paragraph one.\n\nParagraph two.' "$(normalize_text $'Paragraph one.\n\nParagraph two.')"

    check "normalize: preserve break after question mark" \
        $'He asked a question?\nThen left.' "$(normalize_text $'He asked a question?\nThen left.')"

    check "normalize: preserve break after exclamation" \
        $'Stop!\nDon'"'"'t move.' "$(normalize_text $'Stop!\nDon\'t move.')"

    check "normalize: preserve break after colon" \
        $'Note:\nThis is important.' "$(normalize_text $'Note:\nThis is important.')"

    # Roman numerals
    check "normalize: Section I -> Section 1" \
        "Section 1" "$(normalize_text "Section I")"

    check "normalize: Chapter IV -> Chapter 4" \
        "Chapter 4" "$(normalize_text "Chapter IV")"

    check "normalize: Part III of -> Part 3 of" \
        "Part 3 of" "$(normalize_text "Part III of")"

    check "normalize: standalone I unchanged (no label)" \
        "I went home" "$(normalize_text "I went home")"

    check "normalize: Section XIV -> Section 14" \
        "Section 14" "$(normalize_text "Section XIV")"

    check "normalize: Figure VII -> Figure 7" \
        "Figure 7" "$(normalize_text "Figure VII")"

    # Whitespace normalization
    check "normalize: collapse multiple spaces" \
        "Hello world." "$(normalize_text "Hello    world.")"

    check "normalize: strip zero-width spaces (U+200B)" \
        "Helloworld" "$(normalize_text $'Hello\xe2\x80\x8bworld')"

    check "normalize: non-breaking space to regular space" \
        "Hello world" "$(normalize_text $'Hello\xc2\xa0world')"

    check "normalize: strip trailing whitespace on lines" \
        $'Hello.\nWorld.' "$(normalize_text $'Hello.   \nWorld.')"

    # Punctuation collapse
    check "normalize: collapse ellipsis (many dots)" \
        "Wait... what" "$(normalize_text "Wait...... what")"

    check "normalize: three-dot ellipsis preserved" \
        "Wait... what" "$(normalize_text "Wait... what")"

    check "normalize: collapse repeated question marks" \
        "Really?" "$(normalize_text "Really???")"

    check "normalize: collapse repeated exclamation" \
        "Wow!" "$(normalize_text "Wow!!!")"

    check "normalize: em dash from triple hyphen" \
        "word -- word" "$(normalize_text "word --- word")"

    check "normalize: em dash from double hyphen" \
        "word -- word" "$(normalize_text "word -- word")"

    # Superscript exponents (footnote markers now read as exponents)
    check "normalize: superscript after word" \
        "the study to the 1 found" "$(normalize_text $'the study\xc2\xb9 found')"

    check "normalize: strip bracketed reference numbers" \
        "the study found" "$(normalize_text "the study [1] found")"

    check "normalize: strip bracketed multi-ref" \
        "as shown previously" "$(normalize_text "as shown [2,3] previously")"

    # Scientific citation references (PDF copy flattens superscripts to plain digits)
    check "normalize: bare citation range with en-dash" \
        "meteorite impacts." "$(normalize_text "meteorite impacts1–8.")"

    check "normalize: bare citation range with hyphen" \
        "meteorite impacts." "$(normalize_text "meteorite impacts1-8.")"

    check "normalize: bare single citation" \
        "was shown previously1" "$(normalize_text "was shown previously1")"

    check "normalize: bare citation comma list" \
        "the results were" "$(normalize_text "the results1,2,3 were")"

    check "normalize: bare citation comma+range" \
        "the results were" "$(normalize_text "the results1,3-5 were")"

    check "normalize: bracketed range with en-dash" \
        "the results were" "$(normalize_text "the results [1–8] were")"

    check "normalize: bracketed range with hyphen" \
        "the results were" "$(normalize_text "the results [1-8] were")"

    check "normalize: parenthetical author-year" \
        "the results were significant." "$(normalize_text "the results (Smith et al., 2020) were significant.")"

    check "normalize: parenthetical multi author-year" \
        "as shown before." "$(normalize_text "as shown (Smith 2020; Jones 2021) before.")"

    check "normalize: bare citation does not eat real numbers" \
        "measured 42 samples" "$(normalize_text "measured 42 samples")"

    check "normalize: year in text not stripped" \
        "In 2020 we found" "$(normalize_text "In 2020 we found")"

    check "normalize: real-world scientific sentence" \
        "Known as the 'ultimate semiconductor', cubic diamond has gained substantial interest both scientifically and industrially. Its polymorph, hexagonal diamond, is even more intriguing because of its fascinating properties associated with the meteorite impacts." \
        "$(normalize_text "Known as the 'ultimate semiconductor', cubic diamond has gained substantial interest both scientifically and industrially. Its polymorph, hexagonal diamond, is even more intriguing because of its fascinating properties associated with the meteorite impacts1–8.")"

    # Scientific symbols and units
    check "normalize: angstrom symbol" \
        "2.5 angstroms" "$(normalize_text $'2.5 \xc3\x85')"

    check "normalize: angstrom in context" \
        "bond length of 1.54 angstroms was" "$(normalize_text $'bond length of 1.54 \xc3\x85 was')"

    check "normalize: degree celsius" \
        "heated to 500 degrees Celsius" "$(normalize_text $'heated to 500 \xc2\xb0C')"

    check "normalize: degree fahrenheit" \
        "at 72 degrees Fahrenheit" "$(normalize_text $'at 72 \xc2\xb0F')"

    check "normalize: bare degree symbol" \
        "rotated 90 degrees" "$(normalize_text $'rotated 90\xc2\xb0')"

    check "normalize: plus-minus" \
        "3.5 plus or minus 0.2" "$(normalize_text $'3.5 \xc2\xb1 0.2')"

    check "normalize: multiplication sign" \
        "2 times 10" "$(normalize_text $'2 \xc3\x97 10')"

    check "normalize: approximately equal" \
        "approximately 3.14" "$(normalize_text $'\xe2\x89\x88 3.14')"

    check "normalize: less than or equal" \
        "x less than or equal to 5" "$(normalize_text $'x \xe2\x89\xa4 5')"

    check "normalize: greater than or equal" \
        "x greater than or equal to 5" "$(normalize_text $'x \xe2\x89\xa5 5')"

    check "normalize: micro prefix" \
        "50 micrometers" "$(normalize_text $'50 \xc2\xb5m')"

    check "normalize: micro alone" \
        "50 microseconds" "$(normalize_text $'50 \xc2\xb5s')"

    # Greek letters
    check "normalize: alpha" \
        "the alpha phase" "$(normalize_text $'the \xce\xb1 phase')"

    check "normalize: beta" \
        "beta decay" "$(normalize_text $'\xce\xb2 decay')"

    check "normalize: gamma" \
        "gamma rays" "$(normalize_text $'\xce\xb3 rays')"

    check "normalize: delta" \
        "delta function" "$(normalize_text $'\xce\xb4 function')"

    check "normalize: theta" \
        "angle theta" "$(normalize_text $'angle \xce\xb8')"

    check "normalize: lambda" \
        "wavelength lambda" "$(normalize_text $'wavelength \xce\xbb')"

    check "normalize: pi" \
        "pi radians" "$(normalize_text $'\xcf\x80 radians')"

    check "normalize: sigma" \
        "sigma bond" "$(normalize_text $'\xcf\x83 bond')"

    check "normalize: uppercase sigma" \
        "sigma notation" "$(normalize_text $'\xce\xa3 notation')"

    check "normalize: infinity" \
        "to infinity" "$(normalize_text $'to \xe2\x88\x9e')"

    check "normalize: rightward arrow" \
        "A to B" "$(normalize_text $'A \xe2\x86\x92 B')"

    check "normalize: leftward arrow" \
        "A from B" "$(normalize_text $'A \xe2\x86\x90 B')"

    check "normalize: bidirectional arrow" \
        "A to and from B" "$(normalize_text $'A \xe2\x86\x94 B')"

    # Common unit abbreviations that TTS may mangle
    check "normalize: micro-liter" \
        "50 microliters" "$(normalize_text $'50 \xc2\xb5L')"

    check "normalize: angstrom-1 (inverse)" \
        "5 angstroms inverse" "$(normalize_text $'5 \xc3\x85\xe2\x81\xbb\xc2\xb9')"

    # Unicode single-character unit symbols
    check "normalize: single-char degree celsius" \
        "at 500 degrees Celsius" "$(normalize_text $'at 500 \xe2\x84\x83')"

    check "normalize: single-char degree fahrenheit" \
        "at 72 degrees Fahrenheit" "$(normalize_text $'at 72 \xe2\x84\x89')"

    check "normalize: ohm sign" \
        "50 ohms" "$(normalize_text $'50 \xe2\x84\xa6')"

    check "normalize: h-bar" \
        "h-bar over 2" "$(normalize_text $'\xe2\x84\x8f over 2')"

    check "normalize: script l (liter)" \
        "5 liters" "$(normalize_text $'5 \xe2\x84\x93')"

    check "normalize: per mille" \
        "0.5 per mille" "$(normalize_text $'0.5 \xe2\x80\xb0')"

    check "normalize: angle sign" \
        "angle ABC" "$(normalize_text $'\xe2\x88\xa0 ABC')"

    check "normalize: parallel to" \
        "AB parallel to CD" "$(normalize_text $'AB \xe2\x88\xa5 CD')"

    check "normalize: perpendicular to" \
        "AB perpendicular to CD" "$(normalize_text $'AB \xe2\x8a\xa5 CD')"

    check "normalize: prime to apostrophe then DNA prime" \
        "5 prime" "$(normalize_text $'5\xe2\x80\xb2')"

    check "normalize: double prime to quote" \
        "5\"" "$(normalize_text $'5\xe2\x80\xb3')"

    # Ligatures (PDF copy artifacts)
    check "normalize: fi ligature" \
        "find" "$(normalize_text $'\xef\xac\x81nd')"

    check "normalize: fl ligature" \
        "flow" "$(normalize_text $'\xef\xac\x82ow')"

    check "normalize: ffi ligature" \
        "office" "$(normalize_text $'o\xef\xac\x83ce')"

    check "normalize: ffl ligature" \
        "waffle" "$(normalize_text $'wa\xef\xac\x84e')"

    check "normalize: ff ligature" \
        "effect" "$(normalize_text $'e\xef\xac\x80ect')"

    # Soft hyphen (invisible, causes TTS pause)
    check "normalize: soft hyphen stripped" \
        "information" "$(normalize_text $'infor\xc2\xadmation')"

    # Unicode minus sign
    check "normalize: unicode minus to hyphen" \
        "temperature was -5 degrees" "$(normalize_text $'temperature was \xe2\x88\x925 degrees')"

    # Thin/hair/figure spaces
    check "normalize: thin space to regular" \
        "25 kilograms" "$(normalize_text $'25\xe2\x80\x89kg')"

    check "normalize: hair space to regular" \
        "25 kilograms" "$(normalize_text $'25\xe2\x80\x8akg')"

    check "normalize: figure space to regular" \
        "25 kilograms" "$(normalize_text $'25\xe2\x80\x87kg')"

    # URLs and DOIs
    check "normalize: strip https URL" \
        "as shown." "$(normalize_text "as shown. https://doi.org/10.1038/s41586-021-03213-y")"

    check "normalize: strip http URL" \
        "visit for details." "$(normalize_text "visit http://example.com/path for details.")"

    check "normalize: strip doi prefix" \
        "published in Nature." "$(normalize_text "published in Nature. doi:10.1038/nature12345")"

    check "normalize: strip DOI prefix" \
        "published in Nature." "$(normalize_text "published in Nature. DOI: 10.1038/nature12345")"

    check "normalize: URL not eating surrounding text" \
        "See for more." "$(normalize_text "See https://example.com for more.")"

    # Private Use Area characters (math font garbage)
    check "normalize: strip PUA characters" \
        "the result is clear" "$(normalize_text $'the result \xee\x80\x80is clear')"

    # Ellipsis character
    check "normalize: ellipsis to three dots" \
        "wait..." "$(normalize_text $'wait\xe2\x80\xa6')"

    # Mojibake (UTF-8 misread as Latin-1)
    check "normalize: mojibake em dash" \
        "word -- word" "$(normalize_text $'word \xe2\x80\x94 word')"

    check "normalize: mojibake left double quote" \
        "the \"result\" here" "$(normalize_text $'the \xe2\x80\x9cresult\xe2\x80\x9d here')"

    # ftfy integration (real mojibake: UTF-8 bytes misread as Windows-1252)
    check "normalize: ftfy fixes curly quote mojibake" \
        "the \"result\" here" "$(normalize_text $'the \xc3\xa2\xc2\x80\xc2\x9cresult\xc3\xa2\xc2\x80\xc2\x9d here')"

    # Bullet/list markers
    check "normalize: strip bullet character" \
        "First item" "$(normalize_text $'\xe2\x80\xa2 First item')"

    check "normalize: strip dash list marker" \
        "First item" "$(normalize_text "- First item")"

    check "normalize: strip numbered list marker" \
        "First item" "$(normalize_text "1. First item")"

    check "normalize: strip numbered list with paren" \
        "First item" "$(normalize_text "1) First item")"

    # Passthrough
    check "normalize: plain text unchanged" \
        "Hello world." "$(normalize_text "Hello world.")"

    # Windows line endings (CRLF)
    check "normalize: CRLF converted to LF then joined" \
        "Hello world" "$(normalize_text $'Hello\r\nworld')"

    check "normalize: stray CR converted to LF" \
        "Hello world" "$(normalize_text $'Hello\rworld')"

    # Closing quote after period preserves break
    check "normalize: break after closing-quote+period" \
        $'She said "hello."\nThen left.' "$(normalize_text $'She said "hello."\nThen left.')"

    # Semicolon does NOT preserve break (not sentence-ending)
    check "normalize: semicolon line joined" \
        "first clause; second clause" "$(normalize_text $'first clause;\nsecond clause')"

    # Hyphenated compound words mid-line are NOT altered
    check "normalize: compound hyphen mid-line preserved" \
        "state-of-the-art method" "$(normalize_text "state-of-the-art method")"

    # Negative number not stripped as list marker
    check "normalize: negative number preserved" \
        "temperature was -5 degrees" "$(normalize_text "temperature was -5 degrees")"

    # Decimal number not stripped as list marker
    check "normalize: decimal number preserved" \
        "measured 3.5 kilograms" "$(normalize_text "measured 3.5 kg")"

    # Realistic PDF paragraph (combined artifacts)
    _PDF_INPUT=$'The infor-\nmation was presented in\nSection III of the docu-\nment. The results were\nstatistically significant.\n\nDr. Smith noted that the\ndata supports the hypothesis.'
    _PDF_EXPECT=$'The information was presented in Section 3 of the document. The results were statistically significant.\n\nDoctor Smith noted that the data supports the hypothesis.'
    check "normalize: realistic PDF paragraph" \
        "$_PDF_EXPECT" "$(normalize_text "$_PDF_INPUT")"

    # Subscript digits (chemistry: H₂O, CO₂)
    check "normalize: subscript digits H2O" \
        "water" "$(normalize_text $'H\xe2\x82\x82O')"

    check "normalize: subscript digits CO2" \
        "carbon dioxide" "$(normalize_text $'CO\xe2\x82\x82')"

    check "normalize: subscript digit range" \
        "glucose" "$(normalize_text $'C\xe2\x82\x86H\xe2\x82\x81\xe2\x82\x82O\xe2\x82\x86')"

    # Middle dot (interpunct)
    check "normalize: middle dot to space" \
        "kg m" "$(normalize_text $'kg\xc2\xb7m')"

    # Equilibrium arrow
    check "normalize: equilibrium arrow" \
        "A is in equilibrium with B" "$(normalize_text $'A \xe2\x87\x8c B')"

    # Angle brackets (Dirac notation)
    check "normalize: angle brackets stripped" \
        "psi phi" "$(normalize_text $'\xe2\x9f\xa8psi|phi\xe2\x9f\xa9')"

    # et al. bare citation (et al. period removed by _ABBR, then citations stripped)
    check "normalize: et al. bare citation stripped" \
        "Smith et al showed" "$(normalize_text "Smith et al.1-8 showed")"

    check "normalize: et al. bare citation en-dash" \
        "Smith et al showed" "$(normalize_text $'Smith et al.1\xe2\x80\x938 showed')"

    # Micro-prefix units
    check "normalize: micromolar" \
        "5 micromolar" "$(normalize_text $'5 \xc2\xb5M')"

    check "normalize: micrometer" \
        "5 micrometers" "$(normalize_text $'5 \xc2\xb5m')"

    check "normalize: micrograms" \
        "5 micrograms" "$(normalize_text $'5 \xc2\xb5g')"

    check "normalize: microseconds" \
        "5 microseconds" "$(normalize_text $'5 \xc2\xb5s')"

    check "normalize: micro standalone" \
        "5 micro-X" "$(normalize_text $'5 \xc2\xb5X')"

    # Greek letter spacing
    check "normalize: Greek alpha with spacing" \
        "the alpha phase" "$(normalize_text $'the \xce\xb1 phase')"

    check "normalize: Greek beta with spacing" \
        "the beta decay" "$(normalize_text $'the \xce\xb2 decay')"

    check "normalize: Greek lambda spelling" \
        "the lambda function" "$(normalize_text $'the \xce\xbb function')"

    # Ohm symbol after number
    check "normalize: ohm after number" \
        "50 ohms resistor" "$(normalize_text $'50 \xce\xa9 resistor')"

    # Superscript inverse (e.g., cm⁻¹)
    check "normalize: superscript inverse" \
        "cm inverse" "$(normalize_text $'cm\xe2\x81\xbb\xc2\xb9')"

    # Superscript digits expanded (not stripped)
    check "normalize: superscript squared" \
        "x squared" "$(normalize_text $'x\xc2\xb2')"

    # Space before punctuation cleanup
    check "normalize: no space before period" \
        "2.5 angstroms." "$(normalize_text $'2.5 \xc3\x85.')"

    # Space after opening bracket cleanup
    check "normalize: no space after opening paren" \
        "(see above)" "$(normalize_text "( see above)")"

    check "normalize: no space after opening bracket" \
        "[see above]" "$(normalize_text "[ see above]")"

    # SI prefix+unit abbreviations
    check "normalize: mm to millimeters" \
        "5 millimeters thick" "$(normalize_text "5 mm thick")"

    check "normalize: mm glued to number" \
        "5 millimeters thick" "$(normalize_text "5mm thick")"

    check "normalize: GPa to gigapascals" \
        "100 gigapascals pressure" "$(normalize_text "100 GPa pressure")"

    check "normalize: nm to nanometers" \
        "450 nanometers wavelength" "$(normalize_text "450 nm wavelength")"

    check "normalize: kHz to kilohertz" \
        "44 kilohertz sample rate" "$(normalize_text "44 kHz sample rate")"

    check "normalize: mg to milligrams" \
        "500 milligrams dose" "$(normalize_text "500 mg dose")"

    check "normalize: kDa to kilodaltons" \
        "70 kilodaltons protein" "$(normalize_text "70 kDa protein")"

    check "normalize: mM to millimolar" \
        "10 millimolar concentration" "$(normalize_text "10 mM concentration")"

    check "normalize: fs to femtoseconds" \
        "100 femtoseconds pulse" "$(normalize_text "100 fs pulse")"

    check "normalize: keV to kiloelectronvolts" \
        "5 kiloelectronvolts beam" "$(normalize_text "5 keV beam")"

    check "normalize: SI unit not in plain word" \
        "the mm is ambiguous" "$(normalize_text "the mm is ambiguous")"

    # Uncertainty notation (standard deviation in parentheses)
    check "normalize: uncertainty stripped" \
        "2.5179 angstroms" "$(normalize_text $'2.5179(4) \xc3\x85')"

    check "normalize: uncertainty multiple" \
        "a equals 2.518, c equals 4.183" \
        "$(normalize_text "a = 2.518(4), c = 4.183(2)")"

    # Miller indices
    check "normalize: Miller leading zero" \
        "the (0 0 2) peak" "$(normalize_text "the (002) peak")"

    check "normalize: Miller context word after" \
        "the (1 0 0) plane" "$(normalize_text "the (100) plane")"

    check "normalize: Miller context word before" \
        "plane (1 0 0) was observed" "$(normalize_text "plane (100) was observed")"

    check "normalize: Miller series" \
        "the (1 0 0), (0 0 2), (1 0 1)" \
        "$(normalize_text "the (100), (002), (101)")"

    check "normalize: Miller single no context" \
        "approximately (100) people" \
        "$(normalize_text "approximately (100) people")"

    # Academic abbreviations
    check "normalize: Fig to Figure" \
        "Figure 3 shows" "$(normalize_text "Fig. 3 shows")"

    check "normalize: Eq to Equation" \
        "see Equation 5" "$(normalize_text "see Eq. 5")"

    check "normalize: Ref to Reference" \
        "see Reference 12" "$(normalize_text "see Ref. 12")"

    check "normalize: eg expansion" \
        "metals (for example iron)" "$(normalize_text "metals (e.g. iron)")"

    check "normalize: ie expansion" \
        "that is ferromagnetic" "$(normalize_text "i.e. ferromagnetic")"

    # Equals sign
    check "normalize: equals sign spoken" \
        "x equals 10" "$(normalize_text "x = 10")"

    check "normalize: chained equals" \
        "a equals b equals 2.5" "$(normalize_text "a = b = 2.5")"

    # Math operators
    check "normalize: much less than" \
        "x much less than 10" "$(normalize_text "x << 10")"

    check "normalize: much greater than" \
        "x much greater than 10" "$(normalize_text "x >> 10")"

    check "normalize: tilde approximately" \
        "approximately 10 nanometers" "$(normalize_text "~10 nm")"

    # Set theory symbols
    check "normalize: element of" \
        "A in S" "$(normalize_text $'A \xe2\x88\x88 S')"

    check "normalize: subset" \
        "A subset of B" "$(normalize_text $'A \xe2\x8a\x82 B')"

    check "normalize: intersection" \
        "A intersection B" "$(normalize_text $'A \xe2\x88\xa9 B')"

    check "normalize: union" \
        "A union B" "$(normalize_text $'A \xe2\x88\xaa B')"

    check "normalize: therefore" \
        "therefore x" "$(normalize_text $'\xe2\x88\xb4 x')"

    # ── Abbreviation false positives (word-boundary safety) ──────
    check "normalize: which. not corrupted" \
        "which. is correct" "$(normalize_text "which. is correct")"

    check "normalize: each. not corrupted" \
        "each. of them" "$(normalize_text "each. of them")"

    check "normalize: search. not corrupted" \
        "search. found it" "$(normalize_text "search. found it")"

    check "normalize: approach. not corrupted" \
        "approach. was novel" "$(normalize_text "approach. was novel")"

    check "normalize: piano. not corrupted" \
        "the piano. was old" "$(normalize_text "the piano. was old")"

    check "normalize: insect. not corrupted" \
        "the insect. was tiny" "$(normalize_text "the insect. was tiny")"

    check "normalize: She said no. preserved" \
        "She said no. He agreed." "$(normalize_text "She said no. He agreed.")"

    check "normalize: freq. not corrupted by eq." \
        "freq. response" "$(normalize_text "freq. response")"

    # ── Fig.1-8 / Ref.2-5 citation ranges ───────────────────────
    check "normalize: Fig. 1-8 with range" \
        "Figures 1 through 8" "$(normalize_text "Fig. 1-8")"

    check "normalize: Figs.1-8 glued" \
        "Figures 1 through 8" "$(normalize_text "Figs.1-8")"

    check "normalize: Ref. 2-5" \
        "References 2 through 5" "$(normalize_text "Ref. 2-5")"

    check "normalize: Fig. 2 single" \
        "Figure 2" "$(normalize_text "Fig. 2")"

    check "normalize: Eq. 3 single" \
        "Equation 3" "$(normalize_text "Eq. 3")"

    # ── Bare citation false positives ────────────────────────────
    check "normalize: log2 preserved" \
        "log2 of the value" "$(normalize_text "log2 of the value")"

    check "normalize: mp3 preserved" \
        "mp3 file" "$(normalize_text "mp3 file")"

    check "normalize: sha256 preserved" \
        "sha256 algorithm" "$(normalize_text "sha256 algorithm")"

    check "normalize: ipv4 preserved" \
        "ipv4 addresses" "$(normalize_text "ipv4 addresses")"

    # ── Tilde edge case ──────────────────────────────────────────
    check "normalize: tilde before number is approximately" \
        "approximately 10" "$(normalize_text "~10")"

    check "normalize: tilde home path not mangled" \
        "~/Documents" "$(normalize_text "~/Documents")"

    # ── Superscript expansion (#1) ──────────────────────────────
    check "normalize: superscript cubed" \
        "x cubed" "$(normalize_text $'x\xc2\xb3')"

    check "normalize: superscript to the N" \
        "x to the 4" "$(normalize_text $'x\xe2\x81\xb4')"

    check "normalize: E=mc2" \
        "E equals mc squared" "$(normalize_text $'E = mc\xc2\xb2')"

    check "normalize: nm squared" \
        "5 nanometers squared" "$(normalize_text $'5 nm\xc2\xb2')"

    # ── Scientific notation (#2) ────────────────────────────────
    check "normalize: sci notation positive exponent" \
        "6.02 times 10 to the 23" \
        "$(normalize_text $'6.02 \xc3\x97 10\xc2\xb2\xc2\xb3')"

    check "normalize: sci notation negative exponent" \
        "1.5 times 10 to the negative 3" \
        "$(normalize_text $'1.5 \xc3\x97 10\xe2\x81\xbb\xc2\xb3')"

    check "normalize: sci notation bare" \
        "10 to the 6 cells" \
        "$(normalize_text $'10\xe2\x81\xb6 cells')"

    check "normalize: sci notation caret" \
        "2 times 10 to the negative 4" \
        "$(normalize_text $'2 \xc3\x97 10^-4')"

    check "normalize: superscript negative 2 (not just inverse)" \
        "cm to the negative 2" \
        "$(normalize_text $'cm\xe2\x81\xbb\xc2\xb2')"

    # ── Isotope notation (#10) ──────────────────────────────────
    check "normalize: uranium-238" \
        "uranium-238" "$(normalize_text $'\xc2\xb2\xc2\xb3\xe2\x81\xb8U')"

    check "normalize: carbon-12" \
        "carbon-12" "$(normalize_text $'\xc2\xb9\xc2\xb2C')"

    check "normalize: isotope not after word char" \
        "x squared C" "$(normalize_text $'x\xc2\xb2C')"

    # ── Greek mu micro-unit (#3) ────────────────────────────────
    check "normalize: Greek mu micrometers" \
        "5 micrometers" "$(normalize_text $'5 \xce\xbcm')"

    check "normalize: Greek mu micrograms" \
        "100 micrograms" "$(normalize_text $'100 \xce\xbcg')"

    # ── Oxidation states (#11) ──────────────────────────────────
    check "normalize: oxidation Fe(III)" \
        "Fe(3)" "$(normalize_text 'Fe(III)')"

    check "normalize: oxidation Cu(II)" \
        "Cu(2)" "$(normalize_text 'Cu(II)')"

    check "normalize: Complex IV" \
        "Complex 4" "$(normalize_text 'Complex IV')"

    # ── Numeric ranges (#12) ────────────────────────────────────
    check "normalize: en-dash range" \
        "5 to 10 nanometers" "$(normalize_text $'5\xe2\x80\x9310 nm')"

    check "normalize: year range" \
        "1990 to 2020" "$(normalize_text $'1990\xe2\x80\x932020')"

    check "normalize: hyphen range digits" \
        "pages 5-10" "$(normalize_text 'pages 5-10')"

    # ── Unicode fractions (#14) ─────────────────────────────────
    check "normalize: fraction half" \
        "one half dose" "$(normalize_text $'\xc2\xbd dose')"

    check "normalize: fraction three quarters" \
        "three quarters of" "$(normalize_text $'\xc2\xbe of')"

    # ── Abbreviations: et al., etc., Dr., Prof. (#8, #15) ──────
    check "normalize: et al period removed" \
        "Smith et al found" "$(normalize_text 'Smith et al. found')"

    check "normalize: etc expansion" \
        "iron, copper, et cetera" "$(normalize_text 'iron, copper, etc.')"

    check "normalize: Dr expansion" \
        "Doctor Smith" "$(normalize_text 'Dr. Smith')"

    check "normalize: Prof expansion" \
        "Professor Jones" "$(normalize_text 'Prof. Jones')"

    check "normalize: Mr expansion" \
        "Mister Brown" "$(normalize_text 'Mr. Brown')"

    # ── Additional operators ────────────────────────────────────
    check "normalize: less than or equal" \
        "p less than or equal to 0.05" "$(normalize_text 'p <= 0.05')"

    check "normalize: greater than or equal" \
        "x greater than or equal to 10" "$(normalize_text 'x >= 10')"

    check "normalize: not equal" \
        "x not equal to 0" "$(normalize_text 'x != 0')"

    # ── Logical/quantum symbols (#16, #17) ──────────────────────
    check "normalize: for all" \
        "for all x" "$(normalize_text $'\xe2\x88\x80x')"

    check "normalize: there exists" \
        "there exists y" "$(normalize_text $'\xe2\x88\x83y')"

    check "normalize: implies arrow" \
        "P implies Q" "$(normalize_text $'P \xe2\x87\x92 Q')"

    check "normalize: iff arrow" \
        "P if and only if Q" "$(normalize_text $'P \xe2\x87\x94 Q')"

    check "normalize: dagger" \
        "A dagger" "$(normalize_text $'A\xe2\x80\xa0')"

    check "normalize: up arrow" \
        "gene up" "$(normalize_text $'gene \xe2\x86\x91')"

    check "normalize: down arrow" \
        "expression down" "$(normalize_text $'expression \xe2\x86\x93')"

    check "normalize: logical not" \
        "not P" "$(normalize_text $'\xc2\xacP')"

    check "normalize: logical and" \
        "P and Q" "$(normalize_text $'P \xe2\x88\xa7 Q')"

    check "normalize: logical or" \
        "P or Q" "$(normalize_text $'P \xe2\x88\xa8 Q')"

    check "normalize: direct sum" \
        "A direct sum B" "$(normalize_text $'A \xe2\x8a\x95 B')"

    check "normalize: tensor product" \
        "A tensor product B" "$(normalize_text $'A \xe2\x8a\x97 B')"

    check "normalize: maps to" \
        "x maps to y" "$(normalize_text $'x \xe2\x86\xa6 y')"

    check "normalize: dot product" \
        "a dot b" "$(normalize_text $'a \xe2\x8b\x85 b')"

    # ── ppm/ppb/ppt (#18) ──────────────────────────────────────
    check "normalize: ppm" \
        "10 parts per million" "$(normalize_text '10 ppm')"

    check "normalize: ppb" \
        "5 parts per billion" "$(normalize_text '5 ppb')"

    # ── Base SI units (#13) ────────────────────────────────────
    check "normalize: eV" \
        "5 electron volts" "$(normalize_text '5 eV')"

    check "normalize: Hz" \
        "60 hertz" "$(normalize_text '60 Hz')"

    check "normalize: bare Pa" \
        "100 pascals" "$(normalize_text '100 Pa')"

    check "normalize: dB" \
        "20 decibels" "$(normalize_text '20 dB')"

    check "normalize: K kelvins" \
        "300 kelvins" "$(normalize_text '300 K')"

    check "normalize: V volts" \
        "1.5 volts" "$(normalize_text '1.5 V')"

    check "normalize: W watts" \
        "100 watts" "$(normalize_text '100 W')"

    check "normalize: J joules" \
        "4.2 joules" "$(normalize_text '4.2 J')"

    check "normalize: mol" \
        "2 moles" "$(normalize_text '2 mol')"

    # ── Domain units (#25-27) ──────────────────────────────────
    check "normalize: AU" \
        "5 astronomical units" "$(normalize_text '5 AU')"

    check "normalize: bp" \
        "500 base pairs" "$(normalize_text '500 bp')"

    check "normalize: atm" \
        "1 atmospheres" "$(normalize_text '1 atm')"

    check "normalize: kcal" \
        "200 kilocalories" "$(normalize_text '200 kcal')"

    check "normalize: rpm" \
        "3000 revolutions per minute" "$(normalize_text '3000 rpm')"

    check "normalize: Torr" \
        "760 torr" "$(normalize_text '760 Torr')"

    check "normalize: Da" \
        "150 daltons" "$(normalize_text '150 Da')"

    # ── Percentage (#24) ────────────────────────────────────────
    check "normalize: percentage" \
        "95 percent" "$(normalize_text '95%')"

    check "normalize: percentage decimal" \
        "99.9 percent" "$(normalize_text '99.9%')"

    # ── Greek compound spacing (#21) ────────────────────────────
    check "normalize: alpha-helix" \
        "alpha-helix" "$(normalize_text $'\xce\xb1-helix')"

    check "normalize: beta-sheet" \
        "beta-sheet" "$(normalize_text $'\xce\xb2-sheet')"

    # ── DNA prime (#30) ─────────────────────────────────────────
    check "normalize: 5 prime end" \
        "5 prime end" "$(normalize_text "5' end")"

    check "normalize: 3 prime end" \
        "3 prime end" "$(normalize_text "3' end")"

    # ── Remaining tilde to space (#22) ──────────────────────────
    check "normalize: tilde non-numeric becomes space" \
        "Smith (2020)" "$(normalize_text 'Smith~(2020)')"

    # ── Citation regex: tech terms with 4+ lowercase (#4 residual) ──
    check "normalize: sqlite3 preserved" \
        "sqlite3 database" "$(normalize_text 'sqlite3 database')"

    check "normalize: numpy2 preserved" \
        "numpy2 release" "$(normalize_text 'numpy2 release')"

    check "normalize: llama3 preserved" \
        "llama3 model" "$(normalize_text 'llama3 model')"

    check "normalize: bare citation still stripped" \
        "results showed" "$(normalize_text 'results1,2,3 showed')"

    check "normalize: month-year not stripped as citation" \
        "In the meeting (March 2024), we discussed results." \
        "$(normalize_text 'In the meeting (March 2024), we discussed results.')"

    # ── Chemical formula lookup table (#5) ──────────────────────
    check "normalize: H2O to water" \
        "water" "$(normalize_text 'H2O')"

    check "normalize: CO2 to carbon dioxide" \
        "carbon dioxide emissions" "$(normalize_text 'CO2 emissions')"

    check "normalize: NaCl to sodium chloride" \
        "sodium chloride" "$(normalize_text 'NaCl')"

    check "normalize: CH4 to methane" \
        "methane" "$(normalize_text 'CH4')"

    check "normalize: Fe2O3 to iron oxide" \
        "iron oxide" "$(normalize_text 'Fe2O3')"

    check "normalize: unknown formula untouched" \
        "CaMKII" "$(normalize_text 'CaMKII')"

    # ── Pipe character to space (#19) ────────────────────────────
    check "normalize: pipe to space" \
        "psi H phi" "$(normalize_text $'\xe2\x9f\xa8\xcf\x88|H|\xcf\x86\xe2\x9f\xa9')"

    # ── Journal abbreviations (#28 insurance) ───────────────────
    check "normalize: Nat. period removed" \
        "Nat Commun" "$(normalize_text 'Nat. Commun.')"

    check "normalize: Phys. Rev. Lett." \
        "Phys Rev Lett" "$(normalize_text 'Phys. Rev. Lett.')"

    check "normalize: Proc. Natl. Acad. Sci." \
        "Proc Natl Acad Sci" "$(normalize_text 'Proc. Natl. Acad. Sci.')"

    # ── Unit separator: slash to per ────────────────────────────
    check "normalize: mg/mL to per" \
        "5 milligrams per milliliter" "$(normalize_text '5 mg/mL')"

    check "normalize: m/s to per" \
        "10 m per s" "$(normalize_text '10 m/s')"

    check "normalize: km/h" \
        "100 kilometers per h" "$(normalize_text '100 km/h')"

    check "normalize: URL slash not affected" \
        "see" "$(normalize_text 'see https://example.com/path')"

    # ── R1: CAS numbers preserved ────────────────────────────────
    check "normalize: CAS water preserved" \
        "CAS 7732-18-5" "$(normalize_text 'CAS 7732-18-5')"

    check "normalize: CAS ethanol preserved" \
        "CAS 64-17-5" "$(normalize_text 'CAS 64-17-5')"

    # ── R2: Math subtraction not converted to range ──────────────
    check "normalize: subtraction 5-3" \
        "5-3 equals 2" "$(normalize_text '5-3 = 2')"

    check "normalize: negative inline math" \
        "n equals 10-5 equals 5" "$(normalize_text 'n = 10-5 = 5')"

    # ── R3: Tilde does not swallow adjacent chars ────────────────
    check "normalize: T~300K spacing" \
        "T approximately 300 kelvins" "$(normalize_text 'T~300K')"

    check "normalize: pH~7.4 spacing" \
        "pH approximately 7.4" "$(normalize_text 'pH~7.4')"

    # ── R4: wt%/vol%/at%/mol% expanded ──────────────────────────
    check "normalize: wt% expanded" \
        "20 percent by weight" "$(normalize_text '20 wt%')"

    check "normalize: vol% expanded" \
        "5 percent by volume" "$(normalize_text '5 vol%')"

    check "normalize: at% expanded" \
        "10 atomic percent" "$(normalize_text '10 at%')"

    check "normalize: mol% expanded" \
        "15 mole percent" "$(normalize_text '15 mol%')"

    # ── G3: Scientific notation variants ───────────────────
    check "normalize: uppercase X sci notation" \
        "1.5 times 10 to the 6" "$(normalize_text $'1.5 X 10\xe2\x81\xb6')"

    check "normalize: 3x10^5 no-space ASCII" \
        "3 times 10 to the 5" "$(normalize_text '3x10^5')"

    # ── G4: Superscript trailing space ───────────────────────────
    check "normalize: electron config spacing" \
        "1s squared 2s squared 2p to the 6" "$(normalize_text $'1s\xc2\xb22s\xc2\xb22p\xe2\x81\xb6')"

    check "normalize: x squared y spacing" \
        "x squared y" "$(normalize_text $'x\xc2\xb2y')"

    # ── G6: au removed from SI (ambiguous) ───────────────────────
    check "normalize: au not expanded" \
        "5 au" "$(normalize_text '5 au')"

    # ── G8: Arc-minutes and arc-seconds (DMS context) ──────────
    check "normalize: arc min+sec pair" \
        "15 arc minutes 42 arc seconds" "$(normalize_text $'15\xe2\x80\xb2 42\xe2\x80\xb3')"

    check "normalize: degrees minutes seconds" \
        "30 degrees 15 arc minutes 42 arc seconds" \
        "$(normalize_text $'30\xc2\xb0 15\xe2\x80\xb2 42\xe2\x80\xb3')"

    check "normalize: standalone prime unchanged" \
        "5 prime" "$(normalize_text $'5\xe2\x80\xb2')"

    # ── Cross-field robustness ───────────────────────────────────
    check "normalize: plain English passthrough" \
        "The quick brown fox jumped over the lazy dog." \
        "$(normalize_text 'The quick brown fox jumped over the lazy dog.')"

    check "normalize: filesystem path preserved" \
        "/usr/local/bin is in PATH" \
        "$(normalize_text '/usr/local/bin is in PATH')"

    check "normalize: shell pipe preserved" \
        "ls -la | grep foo" \
        "$(normalize_text 'ls -la | grep foo')"

    check "normalize: finance percent" \
        "The index fell 2.3 percent." \
        "$(normalize_text 'The index fell 2.3%.')"

    check "normalize: tech terms preserved" \
        "Install sqlite3 and numpy2 via pip." \
        "$(normalize_text 'Install sqlite3 and numpy2 via pip.')"

    check "normalize: CAS number preserved" \
        "CAS 7732-18-5" "$(normalize_text 'CAS 7732-18-5')"

    check "normalize: math subtraction preserved" \
        "10-5 equals 5" "$(normalize_text '10-5 = 5')"

    check "normalize: music notation passthrough" \
        "Op. 13 in C major" "$(normalize_text 'Op. 13 in C major')"
else
    check "normalize: function not found" "yes" "no"
fi

# Bash-only fallback: sed handles hyphen-newline when python3 is unavailable
# Source the function first, then call it with python3 removed from PATH
_NORM_FUNC=$(awk '/^normalize_text\(\)/,/^}/' "$SPEAK_SH")
_FSTUBS=$(mktemp -d)
ln -s /usr/bin/sed "$_FSTUBS/sed" 2>/dev/null || true
ln -s /usr/bin/printf "$_FSTUBS/printf" 2>/dev/null || true
_FALLBACK_RESULT=$(
    eval "$_NORM_FUNC" 2>/dev/null || true
    VENV_PYTHON=/dev/null/no_python
    PATH="$_FSTUBS"
    normalize_text $'infor-\nmation'
)
rm -rf "$_FSTUBS"
check "normalize: bash sed fallback rejoins hyphenated words" \
    "information" "$_FALLBACK_RESULT"

# Structural checks
check "speak.sh: normalize_text function defined" \
    "yes" "$(grep -q '^normalize_text()' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: normalize_text called after iconv" \
    "yes" "$(grep -q 'normalize_text' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: sed fallback for missing python" \
    "yes" "$(grep -q 'sed.*/-\$/' "$SPEAK_SH" && echo "yes" || echo "no")"

check "speak.sh: VENV_PYTHON set before normalize_text" \
    "yes" "$(awk '/^VENV_PYTHON=/{v=NR} /^normalize_text\(\)/{n=NR} END{print (v<n?"yes":"no")}' "$SPEAK_SH")"

check "speak.sh: no system python3 fallback in normalize_text" \
    "yes" "$(awk '/^normalize_text\(\)/,/^}/{if(/:-python3/) found=1} END{print found?"no":"yes"}' "$SPEAK_SH")"

check "speak.sh: no system python3 fallback in split_sentences" \
    "yes" "$(awk '/^split_sentences\(\)/,/^}/{if(/:-python3/) found=1} END{print found?"no":"yes"}' "$SPEAK_SH")"

check "speak.sh: no system python3 fallback in run_local_tts" \
    "yes" "$(awk '/^run_local_tts\(\)/,/^}/{if(/fallback.*python3|PY=python3/) found=1} END{print found?"no":"yes"}' "$SPEAK_SH")"

check "normalize.py: ftfy is required import (not try/except)" \
    "yes" "$(grep -q '^import.*ftfy' "$SCRIPT_DIR/normalize.py" && echo "yes" || echo "no")"

check "speak.sh: calls normalize.py" \
    "yes" "$(grep -q 'normalize\.py' "$SPEAK_SH" && echo "yes" || echo "no")"

check "normalize.py: exists and is executable-compatible" \
    "yes" "$([ -f "$SCRIPT_DIR/normalize.py" ] && head -1 "$SCRIPT_DIR/normalize.py" | grep -q 'python' && echo "yes" || echo "no")"

# ── LaTeX mode ───────────────────────────────────────────────────

section "LaTeX mode"

if type normalize_text &>/dev/null; then

    # ── Detection: LaTeX vs plain text ──
    # LaTeX input should be detected and processed through the LaTeX pipeline.
    # Plain text should pass through unchanged (no false positives).

    check "latex: detect \\begin{equation}" \
        "The equation: E equals m c squared." \
        "$(normalize_text '\begin{equation} E = mc^2 \end{equation}')"

    check "latex: detect inline math \$...\$" \
        "where alpha equals 5" \
        "$(normalize_text 'where $\alpha = 5$')"

    check "latex: plain text not detected as LaTeX" \
        "The quick brown fox jumped." \
        "$(normalize_text 'The quick brown fox jumped.')"

    check "latex: Windows path not detected as LaTeX" \
        "See C:\Users\smith\data.csv for details." \
        "$(normalize_text 'See C:\Users\smith\data.csv for details.')"

    # ── L1: Comment and preamble stripping ──

    check "latex: strip comments" \
        "Section: Hello. world." \
        "$(normalize_text '\section{Hello} % this is a comment
world.')"

    check "latex: preserve escaped percent" \
        "Section: Results. Achieved 100 percent accuracy." \
        "$(normalize_text '\section{Results}
Achieved 100\% accuracy.')"

    check "latex: strip preamble before \\begin{document}" \
        "Hello world." \
        "$(normalize_text '\documentclass{article}
\usepackage{amsmath}
\begin{document}
Hello world.
\end{document}')"

    # ── L2: Custom macro expansion ──

    check "latex: expand \\newcommand (0 args)" \
        "The the reals are nice." \
        "$(normalize_text '\newcommand{\R}{\mathbb{R}}
The $\R$ are nice.')"

    check "latex: expand \\newcommand (1 arg)" \
        "the vector x is small" \
        "$(normalize_text '\newcommand{\vect}[1]{\vec{#1}}
the $\vect{x}$ is small')"

    # ── L3: Environment handling ──

    check "latex: equation environment with label" \
        "Equation schrodinger: i h-bar partial over partial t psi equals H hat psi." \
        "$(normalize_text '\begin{equation}\label{eq:schrodinger}
i\hbar \frac{\partial}{\partial t} \psi = \hat{H} \psi
\end{equation}')"

    check "latex: align environment" \
        "The aligned equations: a equals b plus c; d equals e minus f." \
        "$(normalize_text '\begin{align}
a &= b + c \\
d &= e - f
\end{align}')"

    check "latex: itemize list" \
        "First item. Second item." \
        "$(normalize_text '\begin{itemize}
\item First item.
\item Second item.
\end{itemize}')"

    check "latex: enumerate list" \
        "1. First. 2. Second." \
        "$(normalize_text '\begin{enumerate}
\item First.
\item Second.
\end{enumerate}')"

    check "latex: figure with caption" \
        "Figure results: The main results." \
        "$(normalize_text '\begin{figure}
\includegraphics{plot.png}
\caption{The main results.}
\label{fig:results}
\end{figure}')"

    check "latex: table with caption" \
        "Table data: Summary of experiments." \
        "$(normalize_text '\begin{table}
\caption{Summary of experiments.}
\label{tab:data}
\begin{tabular}{cc}
a & b \\
c & d
\end{tabular}
\end{table}')"

    check "latex: theorem environment" \
        "Theorem. For all x in the reals, f of x is continuous." \
        "$(normalize_text '\begin{theorem}
For all $x \in \mathbb{R}$, $f(x)$ is continuous.
\end{theorem}')"

    check "latex: escaped dollar in env not treated as math" \
        'Theorem. The price is $5 to $10 per unit.' \
        "$(normalize_text '\begin{theorem}
The price is \$5 to \$10 per unit.
\end{theorem}')"

    check "latex: tikzpicture skipped" \
        "Before. Diagram omitted. After." \
        "$(normalize_text 'Before.
\begin{tikzpicture}
\draw (0,0) -- (1,1);
\end{tikzpicture}
After.')"

    check "latex: abstract environment" \
        "Abstract. We study the problem of X." \
        "$(normalize_text '\begin{abstract}
We study the problem of X.
\end{abstract}')"

    check "latex: proof environment" \
        "Proof. By contradiction. End of proof." \
        "$(normalize_text '\begin{proof}
By contradiction.
\end{proof}')"

    check "latex: bibliography skipped" \
        "Conclusion here. References omitted." \
        "$(normalize_text 'Conclusion here.
\begin{thebibliography}{99}
\bibitem{ref1} Author, Title, 2020.
\end{thebibliography}')"

    # ── L4: Text macro expansion ──

    check "latex: section headings" \
        "Section: Introduction. We begin here." \
        "$(normalize_text '\section{Introduction}
We begin here.')"

    check "latex: subsection" \
        "Subsection: Methods. We used X." \
        "$(normalize_text '\subsection{Methods}
We used X.')"

    check "latex: citations silenced" \
        "As shown previously, the result holds." \
        "$(normalize_text 'As shown previously~\cite{Smith2020}, the result holds.')"

    check "latex: cross-references expanded" \
        "See figure results for details." \
        "$(normalize_text 'See~\ref{fig:results} for details.')"

    check "latex: text formatting unwrapped" \
        "This is important text here." \
        "$(normalize_text 'This is \textbf{important} text \emph{here}.')"

    check "latex: footnote announced" \
        "Main text (footnote: extra detail) continues." \
        "$(normalize_text 'Main text\footnote{extra detail} continues.')"

    check "latex: special characters" \
        "Section: Test. AT&T costs \$5 and 100 percent done." \
        "$(normalize_text '\section{Test}
AT\&T costs \$5 and 100\% done.')"

    check "latex: tilde as non-breaking space" \
        "Section: Test. Doctor Smith et al" \
        "$(normalize_text '\section{Test}
Dr.~Smith et~al.')"

    check "latex: em-dash and en-dash" \
        "Section: Test. He said -- hello -- and left. Pages 5 to 10." \
        "$(normalize_text '\section{Test}
He said --- hello --- and left. Pages 5--10.')"

    check "latex: URLs removed" \
        "See for details." \
        "$(normalize_text 'See \url{https://example.com} for details.')"

    # ── L5: Math to spoken English ──

    check "latex: simple fraction" \
        "a over b" \
        "$(normalize_text '$\frac{a}{b}$')"

    check "latex: nested fraction" \
        "1 over 1 plus x over y" \
        "$(normalize_text '$\frac{1}{1 + \frac{x}{y}}$')"

    check "latex: cfrac continued fraction" \
        "a plus b over c plus d" \
        "$(normalize_text '$\cfrac{a+b}{c+d}$')"

    check "latex: left langle right rangle delimiters" \
        "psi | phi" \
        "$(normalize_text '$\left\langle \psi | \phi \right\rangle$')"

    check "latex: chained equals" \
        "Section: Test. a equals b equals c" \
        "$(normalize_text '\section{Test}
$a=b=c$')"

    check "latex: square root" \
        "square root of x plus 1" \
        "$(normalize_text '$\sqrt{x + 1}$')"

    check "latex: nth root" \
        "3-th root of 8" \
        "$(normalize_text '$\sqrt[3]{8}$')"

    check "latex: integral with limits" \
        "integral from 0 to infinity of e to the -x squared dx" \
        "$(normalize_text '$\int_0^{\infty} e^{-x^2} dx$')"

    check "latex: integral without limits" \
        "integral of f of x dx" \
        "$(normalize_text '$\int f(x) dx$')"

    check "latex: sum with limits" \
        "sum from n equals 1 to N of a sub n" \
        "$(normalize_text '$\sum_{n=1}^{N} a_n$')"

    check "latex: product" \
        "product from i equals 1 to n of x sub i" \
        "$(normalize_text '$\prod_{i=1}^{n} x_i$')"

    check "latex: limit" \
        "limit as x to 0 of sin x over x" \
        "$(normalize_text '$\lim_{x \to 0} \frac{\sin x}{x}$')"

    check "latex: superscripts" \
        "Section: Test. x squared plus y cubed plus z to the n" \
        "$(normalize_text '\section{Test}
$x^2 + y^3 + z^n$')"

    check "latex: subscripts" \
        "Section: Test. a sub i plus b sub jk" \
        "$(normalize_text '\section{Test}
$a_i + b_{jk}$')"

    check "latex: Greek letters" \
        "alpha plus beta equals gamma" \
        "$(normalize_text '$\alpha + \beta = \gamma$')"

    check "latex: decorated symbols" \
        "x hat plus y bar plus vector z" \
        "$(normalize_text '$\hat{x} + \bar{y} + \vec{z}$')"

    check "latex: matrix" \
        "the matrix with rows: a, b; c, d" \
        "$(normalize_text '$\begin{pmatrix} a & b \\ c & d \end{pmatrix}$')"

    check "latex: matrix inside equation environment" \
        "The equation: A equals the matrix with rows: 1, 0; 0, 1." \
        "$(normalize_text '\begin{equation} A = \begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix} \end{equation}')"

    check "latex: cases" \
        "cases: x, if x greater than or equal to 0; -x, otherwise" \
        "$(normalize_text '$\begin{cases} x & \text{if } x \geq 0 \\ -x & \text{otherwise} \end{cases}$')"

    check "latex: display equation announced" \
        "Section: Test. The equation: E equals m c squared." \
        "$(normalize_text '\section{Test}
\[ E = mc^2 \]')"

    check "latex: inline math not announced" \
        "Section: Test. where x squared plus 1 equals 0" \
        "$(normalize_text '\section{Test}
where $x^2 + 1 = 0$')"

    check "latex: relation operators" \
        "a less than or equal to b, c not equal to d" \
        "$(normalize_text '$a \leq b$, $c \neq d$')"

    check "latex: set notation" \
        "x in the reals" \
        "$(normalize_text '$x \in \mathbb{R}$')"

    check "latex: arrows" \
        "f: X to Y implies A" \
        "$(normalize_text '$f: X \to Y \Rightarrow A$')"

    check "latex: trig functions" \
        "sin squared x plus cos squared x equals 1" \
        "$(normalize_text '$\sin^2 x + \cos^2 x = 1$')"

    check "latex: binomial coefficient" \
        "n choose k" \
        "$(normalize_text '$\binom{n}{k}$')"

    check "latex: operatorname" \
        "div F equals 0" \
        "$(normalize_text '$\operatorname{div} F = 0$')"

    check "latex: dot notation (derivatives)" \
        "x dot plus y double dot" \
        "$(normalize_text '$\dot{x} + \ddot{y}$')"

    check "latex: underbrace" \
        "a plus b, that is c," \
        "$(normalize_text '$\underbrace{a + b}_{c}$')"

    check "latex: inverse and transpose" \
        "Section: Test. A inverse B transpose" \
        "$(normalize_text '\section{Test}
$A^{-1} B^{T}$')"

    # ── L4.5: Chemistry (mhchem) ──

    check "latex: \\ce{} simple formula" \
        "water" \
        "$(normalize_text '$\ce{H2O}$')"

    check "latex: \\ce{} reaction" \
        "carbon dioxide plus water to H2CO3" \
        "$(normalize_text '$\ce{CO2 + H2O -> H2CO3}$')"

    # ── L6: Residual cleanup ──

    check "latex: unknown commands stripped silently" \
        "The value x is large." \
        "$(normalize_text 'The \someunknowncommand{value} $x$ is \anothercmd large.')"

    check "latex: residual braces removed" \
        "Section: Test. hello world" \
        "$(normalize_text '\section{Test}
{hello} {world}')"

    check "latex: spacing commands removed from math" \
        "Section: Test. a plus b" \
        "$(normalize_text '\section{Test}
$a \, + \; b$')"

    check "latex: sizing commands removed from math" \
        "Section: Test. a over b" \
        "$(normalize_text '\section{Test}
$\left( \frac{a}{b} \right)$')"

    # ── Integration: partial selection (most common case) ──

    check "latex: paragraph with inline math" \
        "Section: Physics. We define the energy E equals m c squared where m is the mass and c is the speed of light." \
        "$(normalize_text '\section{Physics}
We define the energy $E = mc^2$ where $m$ is the mass and $c$ is the speed of light.')"

    check "latex: multi-paragraph with display math" \
        "Section: Math. Consider the integral. The equation: integral from 0 to 1 of x squared dx. This equals 1 over 3." \
        "$(normalize_text '\section{Math}
Consider the integral.
\[
\int_0^1 x^2 \, dx
\]
This equals $\frac{1}{3}$.')"

    # ── siunitx ──

    check "latex: SI plural (5 meters)" \
        "Section: Test. 5 meters" \
        "$(normalize_text '\section{Test}
\SI{5}{\meter}')"

    check "latex: SI singular (1 meter)" \
        "Section: Test. 1 meter" \
        "$(normalize_text '\section{Test}
\SI{1}{\meter}')"

    check "latex: SI compound (joules per mole per kelvin)" \
        "Section: Test. 8.314 joules per mole per kelvin" \
        "$(normalize_text '\section{Test}
\SI{8.314}{\joule\per\mole\per\kelvin}')"

    check "latex: SI multi-unit numerator (kilo gram meter)" \
        "Section: Test. 5 kilograms meters" \
        "$(normalize_text '\section{Test}
\SI{5}{\kilo\gram\meter}')"

    # ── Structural checks ──

    check "normalize.py: _is_latex function defined" \
        "yes" "$(grep -q '_is_latex' "$SCRIPT_DIR/normalize.py" && echo "yes" || echo "no")"

    check "normalize.py: _frontend_latex function defined" \
        "yes" "$(grep -q '_frontend_latex' "$SCRIPT_DIR/normalize.py" && echo "yes" || echo "no")"

else
    check "latex: normalize_text function not found" "yes" "no"
fi

# ── Markdown mode ────────────────────────────────────────────────

section "Markdown mode"

if type normalize_text &>/dev/null; then

    # ── Detection: Markdown vs plain text ──

    check "markdown: detect fenced code block" \
        "Code block omitted. Hello." \
        "$(normalize_text '```python
print("hi")
```
Hello.')"

    check "markdown: detect ATX heading + bold" \
        "Title: Introduction. This is important." \
        "$(normalize_text '# Introduction
This is **important**.')"

    check "markdown: plain text not detected as Markdown" \
        "Just a normal sentence." \
        "$(normalize_text 'Just a normal sentence.')"

    check "markdown: plain URL not misdetected as Markdown" \
        "See for details." \
        "$(normalize_text 'See https://example.com for details.')"

    # ── M1: YAML frontmatter + Obsidian comments ──

    check "markdown: YAML frontmatter stripped" \
        "Title: Introduction. Hello world." \
        "$(normalize_text '---
title: Introduction
date: 2024-01-01
tags: [test, demo]
---

# Introduction
Hello world.')"

    check "markdown: Obsidian comments stripped" \
        "Title: Test. Before. After." \
        "$(normalize_text '---
title: t
---

# Test
Before. %% This is a private comment %% After.')"

    # ── M2: Code blocks ──

    check "markdown: fenced code block omitted" \
        "Title: Test. Before. Code block omitted. After." \
        "$(normalize_text '---
title: t
---

# Test
Before.
```javascript
const x = 1;
console.log(x);
```
After.')"

    # ── M3: Headings ──

    check "markdown: H1 heading" \
        "Title: Introduction." \
        "$(normalize_text '---
title: t
---

# Introduction')"

    check "markdown: H2 heading" \
        "Section: Methods. We used X." \
        "$(normalize_text '---
title: t
---

## Methods
We used X.')"

    check "markdown: H3 heading" \
        "Subsection: Results. Data here." \
        "$(normalize_text '---
title: t
---

### Results
Data here.')"

    check "markdown: H4-H6 headings" \
        "Details. More info." \
        "$(normalize_text '---
title: t
---

#### Details
More info.')"

    # ── M4: Images ──

    check "markdown: image with alt text" \
        "Title: Test. Image: A nice plot." \
        "$(normalize_text '# Test
![A nice plot](image.png)')"

    check "markdown: image without alt text" \
        "Title: Test. Image." \
        "$(normalize_text '# Test
![](image.png)')"

    check "markdown: Obsidian image wikilink" \
        "Title: Test. Image." \
        "$(normalize_text '# Test
![[results.png]]')"

    # ── M5: Links + wikilinks ──

    check "markdown: markdown link" \
        "Title: Test. See the documentation for details." \
        "$(normalize_text '# Test
See the [documentation](https://example.com) for details.')"

    check "markdown: bare URL removed" \
        "Title: Test. See for details." \
        "$(normalize_text '---
title: t
---

# Test
See https://example.com for details.')"

    check "markdown: Obsidian wikilink" \
        "Title: Test. See My Note for details." \
        "$(normalize_text '# Test
See [[My Note]] for details.')"

    check "markdown: Obsidian wikilink with alias" \
        "Title: Test. See the note for details." \
        "$(normalize_text '# Test
See [[My Note|the note]] for details.')"

    # ── M6: Text formatting ──

    check "markdown: bold text" \
        "Title: Test. This is important." \
        "$(normalize_text '# Test
This is **important**.')"

    check "markdown: italic text (asterisks)" \
        "Title: Test. This is emphasized." \
        "$(normalize_text '---
title: t
---

# Test
This is *emphasized*.')"

    check "markdown: italic text (underscores)" \
        "Title: Test. This is emphasized." \
        "$(normalize_text '---
title: t
---

# Test
This is _emphasized_.')"

    check "markdown: italic does not corrupt star-lists" \
        "Title: Test. First item Second item" \
        "$(normalize_text '---
title: t
---

# Test
* First item
* Second item')"

    check "markdown: italic inside star-list preserved" \
        "Title: Test. Something emphasized here" \
        "$(normalize_text '---
title: t
---

# Test
* Something *emphasized* here')"

    check "markdown: underscores in technical identifiers preserved" \
        "Title: Test. The signal_to_noise_ratio and p_value are important." \
        "$(normalize_text '---
title: t
---

# Test
The signal_to_noise_ratio and p_value are important.')"

    check "markdown: strikethrough removed" \
        "Title: Test. This is old text." \
        "$(normalize_text '---
title: t
---

# Test
This is ~~old~~ text.')"

    check "markdown: inline code" \
        "Title: Test. Use the print function." \
        "$(normalize_text "# Test
Use the "'`'"print"'`'" function.")"

    check "markdown: inline code with dollar sign not treated as math" \
        "Title: Test. Compare x and y variables." \
        "$(normalize_text "# Test
Compare "'`$x$`'" and "'`$y$`'" variables.")"

    # ── M6b: Footnotes and tags ──

    check "markdown: inline footnote ref stripped" \
        "Title: Test. This is a claim." \
        "$(normalize_text '---
title: t
---

# Test
This is a claim[^1].')"

    check "markdown: footnote definition" \
        "Title: Test. (footnote: See Smith 2020 for details.)" \
        "$(normalize_text '---
title: t
---

# Test
[^1]: See Smith 2020 for details.')"

    check "markdown: Obsidian tag stripped" \
        "Title: Test. Important finding." \
        "$(normalize_text '---
title: t
---

# Test
Important finding. #research')"

    # ── M7: Math (reuse _math_to_speech) ──

    check "markdown: inline math dollar" \
        "Title: Test. The value x squared plus 1." \
        "$(normalize_text '---
title: t
---

# Test
The value $x^2 + 1$.')"

    check "markdown: display math" \
        "Title: Test. The equation: E equals m c squared." \
        "$(normalize_text '---
title: t
---

# Test
$$E = mc^2$$')"

    # ── M8: Block elements ──

    check "markdown: GFM table omitted" \
        "Title: Test. Before. Table omitted. After." \
        "$(normalize_text '---
title: t
---

# Test
Before.
| Name | Value |
|------|-------|
| a    | 1     |
| b    | 2     |
After.')"

    check "markdown: Obsidian callout" \
        "Title: Test. Note: Important. Pay attention to this." \
        "$(normalize_text '---
title: t
---

# Test
> [!note] Important
> Pay attention to this.')"

    check "markdown: blockquote" \
        "Title: Test. Quote: To be or not to be." \
        "$(normalize_text '# Test
> To be or not to be.')"

    check "markdown: unordered list" \
        "Title: Test. First item. Second item." \
        "$(normalize_text '# Test
- First item.
- Second item.')"

    check "markdown: ordered list" \
        "Title: Test. 1. First. 2. Second." \
        "$(normalize_text '# Test
1. First.
2. Second.')"

    check "markdown: horizontal rule" \
        $'Title: Test. Above.\n\nBelow.' \
        "$(normalize_text '---
title: t
---

# Test
Above.

---

Below.')"

    # ── M9: HTML tags stripped ──

    check "markdown: HTML tags stripped" \
        "Title: Test. Hello world." \
        "$(normalize_text '---
title: t
---

# Test
<div class="note">Hello</div> <em>world</em>.')"

    # ── M10: Cleanup ──

    check "markdown: paragraph breaks preserved" \
        $'Title: Test. First paragraph.\n\nSecond paragraph.' \
        "$(normalize_text '---
title: t
---

# Test
First paragraph.

Second paragraph.')"

    # ── Integration ──

    check "markdown: full Obsidian note" \
        $'Title: My Research Note.\n\nSection: Background.\n\nThe energy E equals m c squared is fundamental.\n\nSection: Results.\n\nOur data shows alpha equals 0.05.\n\nImage: Results plot.\n\nSee Methods for the full procedure.' \
        "$(normalize_text '---
title: My Research Note
tags: [physics, research]
---

# My Research Note

## Background

The energy $E = mc^2$ is fundamental.

## Results

Our data shows $\alpha = 0.05$.

![Results plot](results.png)

See [[Methods|Methods]] for the full procedure.')"

    # ── Structural checks ──

    check "normalize.py: _is_markdown function defined" \
        "yes" "$(grep -q '_is_markdown' "$SCRIPT_DIR/normalize.py" && echo "yes" || echo "no")"

    check "normalize.py: _frontend_markdown function defined" \
        "yes" "$(grep -q '_frontend_markdown' "$SCRIPT_DIR/normalize.py" && echo "yes" || echo "no")"

else
    check "markdown: normalize_text function not found" "yes" "no"
fi

# ── Back-end (cross-frontend) ────────────────────────────────────

section "Back-end (cross-frontend)"

if type normalize_text &>/dev/null; then

    # Wrappers that force detection to a specific front-end.
    latex_wrap() { printf '\\usepackage{amsmath}\n\\newcommand{\\z}{x}\n%s' "$1"; }
    md_wrap()    { printf -- '---\ntitle: t\n---\n\n# X\n%s' "$1"; }

    # Parametric back-end test: same input through PDF and Markdown front-ends.
    # LaTeX front-end skipped: it garbles Unicode characters that weren't in the
    # original LaTeX source. Only use for inputs without PDF-only artifacts.
    check_backend() {
        local desc="$1" expected="$2" input="$3"
        check "backend: $desc (PDF)"    "$expected" "$(normalize_text "$input")"
        local md_result
        md_result="$(normalize_text "$(md_wrap "$input")")"
        # Strip wrapper prefix "Title: X. " from MD result.
        md_result="${md_result#Title: X. }"
        check "backend: $desc (MD)"     "$expected" "$md_result"
    }

    # ── Wrapper validation: empty input ──

    check "backend: empty PDF"    "" "$(normalize_text '')"
    check "backend: empty LaTeX"  "" "$(normalize_text "$(latex_wrap '')")"
    check "backend: empty MD"     "Title: X." "$(normalize_text "$(md_wrap '')")"

    # Helper to produce Unicode strings (bash 3.2 lacks $'\u...' support).
    _u() { "$VENV_PYTHON" -c "import sys; sys.stdout.write('$1')"; }

    # ── Phase 0: Typographic normalization ──

    check_backend "smart double quotes" \
        '"hello"' \
        "$(_u '\u201chello\u201d')"

    check_backend "smart single quotes" \
        "'world'" \
        "$(_u '\u2018world\u2019')"

    check_backend "ellipsis" \
        "and then..." \
        "$(_u 'and then\u2026')"

    check_backend "Unicode minus to hyphen" \
        "x - y" \
        "$(_u 'x \u2212 y')"

    # ── Phase A: Chemicals ──

    check_backend "water formula" \
        "water" \
        "H2O"

    check_backend "carbon dioxide" \
        "carbon dioxide" \
        "CO2"

    check_backend "sodium chloride" \
        "sodium chloride" \
        "NaCl"

    # ── Phase B: Abbreviations ──

    check_backend "Figure abbreviation" \
        "Figure 1 shows the data." \
        "Fig. 1 shows the data."

    check_backend "Equation abbreviation" \
        "Equation 2 gives the result." \
        "Eq. 2 gives the result."

    check_backend "e.g. expansion" \
        "for example, X" \
        "e.g., X"

    check_backend "i.e. expansion" \
        "that is, Y" \
        "i.e., Y"

    check_backend "et al expansion" \
        "Smith et al found" \
        "Smith et al. found"

    # ── Phase B: Math operators ──

    check_backend "equals sign" \
        "x equals 5" \
        "x = 5"

    check_backend "percentage" \
        "95 percent" \
        "95%"

    # ── Phase B: Numeric ranges ──

    check_backend "en-dash range" \
        "5 to 10" \
        "$(_u '5\u201310')"

    # ── Phase C: Units ──

    check_backend "kilopascals" \
        "100 kilopascals" \
        "100 kPa"

    check_backend "nanometers" \
        "500 nanometers" \
        "500 nm"

    check_backend "degrees Celsius" \
        "25 degrees Celsius" \
        "$(_u '25\u00b0C')"

    check_backend "kilocalories" \
        "2000 kilocalories" \
        "2000 kcal"

    check_backend "denominator singular (per mole)" \
        "5 joules per mole" \
        "5 J/mol"

    check_backend "unit slash no false positive on s/he" \
        "s/he is here" \
        "s/he is here"

    # ── Phase C: Greek letters ──

    check_backend "alpha letter" \
        "The alpha value." \
        "$(_u 'The \u03b1 value.')"

    check_backend "alpha with tonos diacritic" \
        "The alpha value." \
        "$(_u 'The \u03ac value.')"

    check_backend "final sigma spoken as sigma" \
        "The sigma value." \
        "$(_u 'The \u03c2 value.')"

    check_backend "beta letter" \
        "The beta value." \
        "$(_u 'The \u03b2 value.')"

    # ── Phase C: Symbols ──

    check_backend "plus or minus" \
        "5 plus or minus 1" \
        "$(_u '5 \u00b1 1')"

    check_backend "times symbol" \
        "3 times 4" \
        "$(_u '3 \u00d7 4')"

    check_backend "infinity" \
        "to infinity" \
        "$(_u 'to \u221e')"

    # ── Edge cases: no false positives in detection ──

    check "detection: plain English" \
        "The quick brown fox jumped over the lazy dog." \
        "$(normalize_text 'The quick brown fox jumped over the lazy dog.')"

    check "detection: web page text" \
        "Welcome to our website. Click here to learn more." \
        "$(normalize_text 'Welcome to our website. Click here to learn more.')"

    check "detection: number with hash not expanded" \
        "Issue #42 is important." \
        "$(normalize_text 'Issue #42 is important.')"

    # ── Regression: = double-expansion through LaTeX ──
    # Both inline math = and prose = should each produce exactly one "equals".
    check "latex: no double-expansion of equals" \
        "Section: Test. The value x equals 5. where a equals b" \
        "$(normalize_text '\section{Test}
The value $x = 5$.
where a = b')"

    # ── LaTeX special chars survive L4-L6 pipeline ──
    check "latex: ampersand survives pipeline" \
        "Section: Test. AT&T costs \$5." \
        "$(normalize_text '\section{Test}
AT\&T costs \$5.')"

    # ── Python normalization path actually works (not just sed fallback) ──
    # The sed fallback only does hyphen-rejoining; it cannot expand abbreviations.
    # If Fig. -> Figure, the Python path is working.
    check "normalize: Python path active (not sed fallback)" \
        "Figure 1 shows results." \
        "$(normalize_text 'Fig. 1 shows results.')"

else
    check "backend: normalize_text function not found" "yes" "no"
fi

# ── Summary ──────────────────────────────────────────────────────

printf "\n────────────────────────────────────────────\n"
printf "  %d passed, %d failed\n\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
