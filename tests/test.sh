#!/bin/bash
# test.sh — Test suite for Speak11
#
# Usage:
#   bash tests/test.sh           # all tests (Swift compile included, ~20s)
#   bash tests/test.sh --fast    # skip slow Swift compile test

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEAK_SH="$SCRIPT_DIR/speak.sh"
SETTINGS_SWIFT="$SCRIPT_DIR/Speak11Settings.swift"
FAST=false
[[ "${1:-}" == "--fast" ]] && FAST=true

PASS=0
FAIL=0

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

# ── 6. API key guard ─────────────────────────────────────────────

section "API key guard"

# Stubs: security returns nothing (simulates no Keychain entry); osascript is
# a no-op so the error dialog doesn't pop up; curl must not be called at all.
_STUBS=$(mktemp -d)
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"   # no Keychain entry
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/osascript"  # suppress dialogs
printf '#!/bin/bash\nexit 0\n' > "$_STUBS/curl"       # must never be reached
chmod +x "$_STUBS/security" "$_STUBS/osascript" "$_STUBS/curl"

# Pipe non-empty text so the script gets past the blank-text guard and
# reaches the API key check.  Expect exit 1 (key not found).
check_exit "empty ELEVENLABS_API_KEY with no Keychain entry → exits 1" 1 \
    bash -c 'echo "hello world" | env PATH="'"$_STUBS"':$PATH" ELEVENLABS_API_KEY="" TTS_BACKEND=elevenlabs bash "'"$SPEAK_SH"'"'

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
# Verify _CFG_BACKEND= appears at column 0 (no leading spaces = top-level code).
check "config write is not nested inside settings if block" \
    "yes" "$(grep -m1 '_CFG_BACKEND=' "$SCRIPT_DIR/install.command" | grep -q '^[^ ]' && echo "yes" || echo "no")"

# Bug B: Done dialog must condition the "model downloaded" message on mlx_ok.
# Check that mlx_ok appears within 3 lines before the "Kokoro voice model" line.
check "done dialog conditions model message on mlx_ok" \
    "yes" "$(grep -B3 'Kokoro voice model' "$SCRIPT_DIR/install.command" | grep -q 'mlx_ok' && echo "yes" || echo "no")"

# ── 9. uninstall.command syntax ──────────────────────────────

section "uninstall.command syntax"

check "bash syntax valid" "0" "$(bash -n "$SCRIPT_DIR/uninstall.command" 2>/dev/null; echo $?)"

# ── 10. Swift source structure ────────────────────────────────────

section "Speak11Settings.swift structure"

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

section "Speak11Settings.swift compile"

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

# ── 11. TTS_BACKEND / LOCAL_VOICE / LOCAL_LANG config priority ────

section "TTS_BACKEND / LOCAL_VOICE / LOCAL_LANG config priority"

resolve_backend_config() {
    local conf="$1" env_backend="${2:-}" env_voice="${3:-}" env_lang="${4:-}"
    (
        unset TTS_BACKEND LOCAL_VOICE LOCAL_LANG
        [ -n "$env_backend" ] && export TTS_BACKEND="$env_backend"
        [ -n "$env_voice" ] && export LOCAL_VOICE="$env_voice"
        [ -n "$env_lang" ] && export LOCAL_LANG="$env_lang"
        # Save env vars before source can overwrite them
        _ENV_TTS_BACKEND="${TTS_BACKEND:-}"
        _ENV_LOCAL_VOICE="${LOCAL_VOICE:-}"
        _ENV_LOCAL_LANG="${LOCAL_LANG:-}"
        _CONFIG="$conf"
        [ -f "$_CONFIG" ] && source "$_CONFIG"
        # Priority: env var > config file > hardcoded default
        TTS_BACKEND="${_ENV_TTS_BACKEND:-${TTS_BACKEND:-auto}}"
        LOCAL_VOICE="${_ENV_LOCAL_VOICE:-${LOCAL_VOICE:-af_heart}}"
        LOCAL_LANG="${_ENV_LOCAL_LANG:-${LOCAL_LANG:-a}}"
        echo "${TTS_BACKEND}|${LOCAL_VOICE}|${LOCAL_LANG}"
    )
}

TMPCONF=$(mktemp)
printf 'TTS_BACKEND="local"\nLOCAL_VOICE="am_adam"\nLOCAL_LANG="b"\n' > "$TMPCONF"

check "no config → backend defaults to auto" \
    "auto" "$(resolve_backend_config /nonexistent | cut -d'|' -f1)"
check "no config → local voice defaults to af_heart" \
    "af_heart" "$(resolve_backend_config /nonexistent | cut -d'|' -f2)"
check "no config → local lang defaults to a" \
    "a" "$(resolve_backend_config /nonexistent | cut -d'|' -f3)"
check "config sets backend=local" \
    "local" "$(resolve_backend_config "$TMPCONF" | cut -d'|' -f1)"
check "config sets local voice=am_adam" \
    "am_adam" "$(resolve_backend_config "$TMPCONF" | cut -d'|' -f2)"
check "config sets local lang=b" \
    "b" "$(resolve_backend_config "$TMPCONF" | cut -d'|' -f3)"
check "env var overrides config backend" \
    "elevenlabs" "$(resolve_backend_config "$TMPCONF" "elevenlabs" | cut -d'|' -f1)"
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
        prev=""
        for a in "\$@"; do
            if [ "\$prev" = "--output_path" ]; then
                mkdir -p "\$a"
                printf "RIFF" > "\$a/speak11.wav"
            fi
            prev="\$a"
        done
        exit 0
    fi
done
/usr/bin/python3 "\$@"
PYSTUB
chmod +x "$_STUBS/security" "$_STUBS/osascript" "$_STUBS/afplay" "$_STUBS/python3"

check_exit "TTS_BACKEND=local with no API key → exits 0 (key not needed)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=local LOCAL_VOICE=af_heart bash "'"$SPEAK_SH"'"'

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

# python3 stub: track mlx_audio calls, pass through json calls
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        touch "$_MARKERS/mlx_called"
        prev=""
        for a in "\$@"; do
            if [ "\$prev" = "--output_path" ]; then
                mkdir -p "\$a"
                printf "RIFF" > "\$a/speak11.wav"
            fi
            prev="\$a"
        done
        exit 0
    fi
done
/usr/bin/python3 "\$@"
STUB

chmod +x "$_STUBS/security" "$_STUBS/osascript" "$_STUBS/afplay" "$_STUBS/curl" "$_STUBS/python3"

# Test: local backend routes to mlx_audio, not curl
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=local bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true
check "local backend → curl NOT called" \
    "no" "$([ -f "$_MARKERS/curl_called" ] && echo "yes" || echo "no")"
check "local backend → mlx_audio called" \
    "yes" "$([ -f "$_MARKERS/mlx_called" ] && echo "yes" || echo "no")"

# Test: elevenlabs backend routes to curl, not mlx_audio
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=elevenlabs bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true
check "elevenlabs backend → curl called" \
    "yes" "$([ -f "$_MARKERS/curl_called" ] && echo "yes" || echo "no")"
check "elevenlabs backend → mlx_audio NOT called" \
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

bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=elevenlabs bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true

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
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=elevenlabs bash "'"$SPEAK_SH"'"'

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
/usr/bin/python3 "$@"
PYSTUB
chmod +x "$_STUBS"/*

check_exit "local TTS generation failure → exits 1" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=local bash "'"$SPEAK_SH"'"'

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

# python3: handle mlx_audio (for fallback) and pass through json calls
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        touch "$_MARKERS/mlx_fallback_called"
        prev=""
        for a in "\$@"; do
            if [ "\$prev" = "--output_path" ]; then
                mkdir -p "\$a"
                printf "RIFF" > "\$a/speak11.wav"
            fi
            prev="\$a"
        done
        exit 0
    fi
done
/usr/bin/python3 "\$@"
STUB

chmod +x "$_STUBS"/*

# Test: 429 + both installed → silent fallback to local (no dialog)
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
check_exit "429 + both installed → exits 0 (silent fallback)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=both bash "'"$SPEAK_SH"'"'
check "429 + both → local TTS called as fallback" \
    "yes" "$([ -f "$_MARKERS/mlx_fallback_called" ] && echo "yes" || echo "no")"
check "429 + both → no dialog shown (silent)" \
    "no" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: network failure (curl exits non-zero) + both installed → silent fallback
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
printf '#!/bin/bash\nexit 7\n' > "$_STUBS/curl"   # exit 7 = connection refused
chmod +x "$_STUBS/curl"

check_exit "network failure + both installed → exits 0 (silent fallback)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=both bash "'"$SPEAK_SH"'"'
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
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=both bash "'"$SPEAK_SH"'"'
check "429 + both + local fails → error dialog shown" \
    "yes" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: network failure + both + local TTS FAILS → error dialog
rm -f "$_LOG"
printf '#!/bin/bash\nexit 7\n' > "$_STUBS/curl"
chmod +x "$_STUBS/curl"

check_exit "network failure + both + local fails → exits 1" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=both bash "'"$SPEAK_SH"'"'
check "network failure + both + local fails → error dialog shown" \
    "yes" "$([ -s "$_LOG" ] && echo "yes" || echo "no")"

# Test: network failure + elevenlabs only → error dialog, not fallback
rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
check_exit "network failure + elevenlabs only → exits 1" 1 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=elevenlabs TTS_BACKENDS_INSTALLED=elevenlabs bash "'"$SPEAK_SH"'"'
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

# Functional test: run speak.sh with ElevenLabs backend and verify files are created
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
    env PATH="$_STUBS:$PATH" TMPDIR="$_TESTTMP" TTS_BACKEND=elevenlabs \
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
        prev=""
        for a in "\$@"; do
            if [ "\$prev" = "--output_path" ]; then
                mkdir -p "\$a"
                printf "RIFF" > "\$a/speak11.wav"
            fi
            prev="\$a"
        done
        exit 0
    fi
done
/usr/bin/python3 "\$@"
PYSTUB
chmod +x "$_STUBS"/*

echo "Local TTS test sentence." | \
    env PATH="$_STUBS:$PATH" TMPDIR="$_TESTTMP" TTS_BACKEND=local LOCAL_VOICE=af_heart \
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

# python3 stub: track mlx_audio calls
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        touch "$_MARKERS/mlx_called"
        prev=""
        for a in "\$@"; do
            if [ "\$prev" = "--output_path" ]; then
                mkdir -p "\$a"
                printf "RIFF" > "\$a/speak11.wav"
            fi
            prev="\$a"
        done
        exit 0
    fi
done
/usr/bin/python3 "\$@"
STUB
chmod +x "$_STUBS"/*

# Test: auto + API key → ElevenLabs
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=auto bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true
check "auto + API key → curl called (ElevenLabs)" \
    "yes" "$([ -f "$_MARKERS/curl_called" ] && echo "yes" || echo "no")"
check "auto + API key → mlx_audio NOT called" \
    "no" "$([ -f "$_MARKERS/mlx_called" ] && echo "yes" || echo "no")"

# Test: auto + no API key → local
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"
chmod +x "$_STUBS/security"
bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=auto ELEVENLABS_API_KEY="" bash "'"$SPEAK_SH"'"' >/dev/null 2>&1 || true
check "auto + no API key → curl NOT called" \
    "no" "$([ -f "$_MARKERS/curl_called" ] && echo "yes" || echo "no")"
check "auto + no API key → mlx_audio called (local)" \
    "yes" "$([ -f "$_MARKERS/mlx_called" ] && echo "yes" || echo "no")"

# Test: auto + no API key → exits 0 (no error dialog)
rm -f "$_MARKERS/curl_called" "$_MARKERS/mlx_called"
check_exit "auto + no API key → exits 0 (silent local)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=auto ELEVENLABS_API_KEY="" bash "'"$SPEAK_SH"'"'

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

# python3: handle mlx_audio for fallback
cat > "$_STUBS/python3" << STUB
#!/bin/bash
for arg in "\$@"; do
    if [ "\$arg" = "mlx_audio.tts.generate" ]; then
        touch "$_MARKERS/mlx_fallback_called"
        prev=""
        for a in "\$@"; do
            if [ "\$prev" = "--output_path" ]; then
                mkdir -p "\$a"
                printf "RIFF" > "\$a/speak11.wav"
            fi
            prev="\$a"
        done
        exit 0
    fi
done
/usr/bin/python3 "\$@"
STUB
chmod +x "$_STUBS"/*

rm -f "$_MARKERS/mlx_fallback_called" "$_LOG"
check_exit "auto + network failure → exits 0 (falls back)" 0 \
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=auto bash "'"$SPEAK_SH"'"'
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
    bash -c 'echo "hello" | env PATH="'"$_STUBS"':$PATH" TTS_BACKEND=auto bash "'"$SPEAK_SH"'"'
check "auto + 429 → local TTS called" \
    "yes" "$([ -f "$_MARKERS/mlx_fallback_called" ] && echo "yes" || echo "no")"

rm -rf "$_STUBS"

# ── 22. Auto-derive lang_code from voice ─────────────────────────

section "Auto-derive lang_code from voice"

# speak.sh should derive lang_code from the voice prefix, not use LOCAL_LANG
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
            if [ "\$prev" = "--output_path" ]; then
                mkdir -p "\$a"
                printf "RIFF" > "\$a/speak11.wav"
            fi
            prev="\$a"
        done
        exit 0
    fi
done
/usr/bin/python3 "\$@"
PYSTUB
chmod +x "$_STUBS"/*

# Test with American voice → should derive lang_code "a"
echo "test" | env PATH="$_STUBS:$PATH" TMPDIR="$_TESTTMP" TTS_BACKEND=local LOCAL_VOICE=af_heart \
    bash "$SPEAK_SH" >/dev/null 2>&1 || true
check "af_heart → lang_code 'a'" \
    "a" "$(cat "$_TESTTMP/captured_lang" 2>/dev/null)"

# Test with British voice → should derive lang_code "b"
rm -f "$_TESTTMP/captured_lang"
echo "test" | env PATH="$_STUBS:$PATH" TMPDIR="$_TESTTMP" TTS_BACKEND=local LOCAL_VOICE=bf_emma \
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

check "Swift: cachedCredits property exists" \
    "yes" "$(grep -q 'cachedCredits' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

check "Swift: pickLanguage removed" \
    "yes" "$(! grep -q 'func pickLanguage' "$SETTINGS_SWIFT" && echo "yes" || echo "no")"

# ── 24. install.command auto backend ─────────────────────────────

section "install.command auto backend"

check "install.command sets auto for Both choice" \
    "yes" "$(grep -q '_CFG_BACKEND="auto"' "$SCRIPT_DIR/install.command" && echo "yes" || echo "no")"

# ── Summary ──────────────────────────────────────────────────────

printf "\n────────────────────────────────────────────\n"
printf "  %d passed, %d failed\n\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
