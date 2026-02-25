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
    bash -c 'echo "hello world" | env PATH="'"$_STUBS"':$PATH" ELEVENLABS_API_KEY="" bash "'"$SPEAK_SH"'"'

rm -rf "$_STUBS"

# ── 7. speak.sh shellcheck / syntax ──────────────────────────────

section "speak.sh syntax"

check "bash syntax valid" "0" "$(bash -n "$SPEAK_SH" 2>/dev/null; echo $?)"

if command -v shellcheck &>/dev/null; then
    check "shellcheck passes" "0" "$(shellcheck -S warning "$SPEAK_SH" 2>/dev/null; echo $?)"
else
    printf "  SKIP  shellcheck not installed\n"
fi

# ── 8. install.command syntax ─────────────────────────────────────

section "install.command syntax"

check "bash syntax valid" "0" "$(bash -n "$SCRIPT_DIR/install.command" 2>/dev/null; echo $?)"

# ── 9. uninstall.command syntax ──────────────────────────────

section "uninstall.command syntax"

check "bash syntax valid" "0" "$(bash -n "$SCRIPT_DIR/uninstall.command" 2>/dev/null; echo $?)"

# ── 10. Swift compile (slow ~15s) ────────────────────────────────

section "Speak11Settings.swift"

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

# ── Summary ──────────────────────────────────────────────────────

printf "\n────────────────────────────────────────────\n"
printf "  %d passed, %d failed\n\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
