#!/bin/bash
# speak.sh — Speak11 for macOS
# Select text in any app, press your hotkey, hear it spoken.
#
# Requirements: curl, afplay (built into macOS)
# Setup: Set your API key and preferred voice below.

# ── Configuration ──────────────────────────────────────────────────
# Get your API key from: https://elevenlabs.io → Profile → API Keys
ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:-$(security find-generic-password -a "speak11" -s "speak11-api-key" -w 2>/dev/null)}"

# Load settings written by the menu bar settings app.
# Priority: environment variable > config file > hardcoded default.
_CONFIG="$HOME/.config/speak11/config"
[ -f "$_CONFIG" ] && source "$_CONFIG"

# Voice ID — edit via the menu bar app, or override with an env var.
# Browse voices at: https://elevenlabs.io/voice-library
VOICE_ID="${ELEVENLABS_VOICE_ID:-${VOICE_ID:-pFZP5JQG7iQjIQuC4Bku}}"

# Model — Flash v2.5 for lowest latency, Multilingual v2 for best quality
MODEL_ID="${ELEVENLABS_MODEL_ID:-${MODEL_ID:-eleven_flash_v2_5}}"

# Voice settings — edit via the menu bar app or set env vars directly
STABILITY="${STABILITY:-0.5}"
SIMILARITY_BOOST="${SIMILARITY_BOOST:-0.75}"
STYLE="${STYLE:-0.0}"
USE_SPEAKER_BOOST="${USE_SPEAKER_BOOST:-true}"
SPEED="${SPEED:-1.0}"

# ── Toggle: stop playback if already running ───────────────────────
PID_FILE="${TMPDIR:-/tmp}/elevenlabs_tts.pid"
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null
        rm -f "$PID_FILE"
        exit 0
    fi
    rm -f "$PID_FILE"  # stale PID, clean up and continue
fi

# ── Read selected text ─────────────────────────────────────────────
# Three cases:
#   1. Terminal (tty): direct invocation — read clipboard as-is
#   2. Services/pipe: text passed via stdin — use that
#   3. Settings app hotkey (⌥⇧/): stdin is empty (not a tty, no content) —
#      the settings app already simulated ⌘C via CGEvent before launching
#      this script, so the clipboard holds the current selection. Read it.
if [ -t 0 ]; then
    TEXT=$(pbpaste 2>/dev/null)
else
    TEXT=$(cat /dev/stdin)
    if [ -z "${TEXT//[[:space:]]/}" ]; then
        TEXT=$(pbpaste 2>/dev/null)
    fi
fi

# Exit silently if nothing was selected (bash command substitution already
# strips trailing newlines, so an all-whitespace selection still needs a check)
if [ -z "${TEXT//[[:space:]]/}" ]; then
    exit 0
fi

# ── Preflight checks ───────────────────────────────────────────────
if [ -z "$ELEVENLABS_API_KEY" ]; then
    osascript -e 'display dialog "ElevenLabs API key not found." & return & return & "Run install.command to store your key, or set the ELEVENLABS_API_KEY environment variable." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    osascript -e 'display dialog "python3 is required but not found." & return & return & "Install Xcode Command Line Tools: xcode-select --install" with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
    exit 1
fi

# ── Temp file for audio ────────────────────────────────────────────
TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/elevenlabs_tts_XXXXXXXXXX.mp3")
if [ -z "$TMP_FILE" ] || [ ! -f "$TMP_FILE" ]; then
    osascript -e 'display dialog "Failed to create a temporary file. Check that /tmp is writable." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
    exit 1
fi

PLAY_PID=""

cleanup() {
    rm -f "$TMP_FILE" "$PID_FILE"
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── Escape text for JSON ───────────────────────────────────────────
# python3 is the only safe way to handle arbitrary Unicode, control chars, etc.
JSON_TEXT=$(python3 -c "import json, sys; print(json.dumps(sys.stdin.read()))" <<< "$TEXT")
if [ $? -ne 0 ] || [ -z "$JSON_TEXT" ]; then
    osascript -e 'display dialog "Failed to encode the selected text as JSON." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
    exit 1
fi

# ── Call ElevenLabs streaming API ─────────────────────────────────
HTTP_CODE=$(curl -s -w "%{http_code}" \
    --max-time 30 \
    -o "$TMP_FILE" \
    -X POST \
    "https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}/stream" \
    -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
        \"text\": ${JSON_TEXT},
        \"model_id\": \"${MODEL_ID}\",
        \"voice_settings\": {
            \"stability\": ${STABILITY},
            \"similarity_boost\": ${SIMILARITY_BOOST},
            \"style\": ${STYLE},
            \"use_speaker_boost\": ${USE_SPEAKER_BOOST},
            \"speed\": ${SPEED}
        }
    }")

# ── Handle errors ──────────────────────────────────────────────────
if [ "$HTTP_CODE" != "200" ]; then
    # Sanitize the response body: truncate, strip control chars and quotes so
    # it can be safely embedded in an AppleScript string literal.
    SAFE_ERROR=$(cat "$TMP_FILE" 2>/dev/null \
        | head -c 300 \
        | tr -d '\000-\037"\\')
    osascript -e "display dialog \"ElevenLabs API error (HTTP ${HTTP_CODE}):\" & return & return & \"${SAFE_ERROR:-Unknown error}\" with title \"Speak11\" buttons {\"OK\"} default button \"OK\" with icon caution"
    exit 1
fi

# Verify the response actually contains audio data before trying to play it
if [ ! -s "$TMP_FILE" ]; then
    osascript -e 'display dialog "ElevenLabs returned an empty audio response." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
    exit 1
fi

# ── Play audio ─────────────────────────────────────────────────────
afplay "$TMP_FILE" &
PLAY_PID=$!
echo "$PLAY_PID" > "$PID_FILE"
wait "$PLAY_PID"
