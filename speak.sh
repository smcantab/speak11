#!/bin/bash
# speak.sh — Speak11 for macOS
# Select text in any app, press your hotkey, hear it spoken.
#
# Supports three backend modes:
#   - elevenlabs  — cloud API (requires API key)
#   - local       — mlx-audio / Kokoro (runs on Apple Silicon)
#   - auto        — tries ElevenLabs first, falls back to local silently
#
# Requirements: afplay (built into macOS), curl (for ElevenLabs), python3

# ── Configuration ──────────────────────────────────────────────────

# Save env vars before sourcing config (source overwrites same-named vars).
_ENV_TTS_BACKEND="${TTS_BACKEND:-}"
_ENV_TTS_BACKENDS_INSTALLED="${TTS_BACKENDS_INSTALLED:-}"
_ENV_LOCAL_VOICE="${LOCAL_VOICE:-}"
_ENV_LOCAL_LANG="${LOCAL_LANG:-}"

# Load settings written by the menu bar settings app.
_CONFIG="$HOME/.config/speak11/config"
[ -f "$_CONFIG" ] && source "$_CONFIG"

# Priority: environment variable > config file > hardcoded default.
TTS_BACKEND="${_ENV_TTS_BACKEND:-${TTS_BACKEND:-auto}}"
TTS_BACKENDS_INSTALLED="${_ENV_TTS_BACKENDS_INSTALLED:-${TTS_BACKENDS_INSTALLED:-elevenlabs}}"
LOCAL_VOICE="${_ENV_LOCAL_VOICE:-${LOCAL_VOICE:-af_heart}}"
LOCAL_LANG="${_ENV_LOCAL_LANG:-${LOCAL_LANG:-a}}"

# ElevenLabs settings (loaded when needed — both "elevenlabs" and "auto" modes)
if [ "$TTS_BACKEND" = "elevenlabs" ] || [ "$TTS_BACKEND" = "auto" ]; then
    ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:-$(security find-generic-password -a "speak11" -s "speak11-api-key" -w 2>/dev/null)}"
    VOICE_ID="${ELEVENLABS_VOICE_ID:-${VOICE_ID:-pFZP5JQG7iQjIQuC4Bku}}"
    MODEL_ID="${ELEVENLABS_MODEL_ID:-${MODEL_ID:-eleven_flash_v2_5}}"
    STABILITY="${STABILITY:-0.5}"
    SIMILARITY_BOOST="${SIMILARITY_BOOST:-0.75}"
    STYLE="${STYLE:-0.0}"
    USE_SPEAKER_BOOST="${USE_SPEAKER_BOOST:-true}"
fi

SPEED="${SPEED:-1.0}"

# ── Toggle: stop playback if already running ───────────────────────
PID_FILE="${TMPDIR:-/tmp}/speak11_tts.pid"
TEXT_FILE="${TMPDIR:-/tmp}/speak11_text"
STATUS_FILE="${TMPDIR:-/tmp}/speak11_status"
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
if [ -t 0 ]; then
    TEXT=$(pbpaste 2>/dev/null)
else
    TEXT=$(cat /dev/stdin)
    if [ -z "${TEXT//[[:space:]]/}" ]; then
        TEXT=$(pbpaste 2>/dev/null)
    fi
fi

if [ -z "${TEXT//[[:space:]]/}" ]; then
    exit 0
fi

# Save text for live settings preview (position-aware respeak)
printf '%s' "$TEXT" > "$TEXT_FILE"

# ── Preflight checks ───────────────────────────────────────────────
if [ "$TTS_BACKEND" = "elevenlabs" ]; then
    if [ -z "$ELEVENLABS_API_KEY" ]; then
        osascript -e 'display dialog "ElevenLabs API key not found." & return & return & "Run install.command to store your key, or set the ELEVENLABS_API_KEY environment variable." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
        exit 1
    fi
fi

if ! command -v python3 &>/dev/null; then
    osascript -e 'display dialog "python3 is required but not found." & return & return & "Install Xcode Command Line Tools: xcode-select --install" with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
    exit 1
fi

# ── Shared state ─────────────────────────────────────────────────
TMP_FILE=""
TMP_DIR=""
PLAY_PID=""

cleanup() {
    set +e  # bash 3.2: trap failures override exit code under set -e
    rm -f "$TMP_FILE" "$PID_FILE"
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Local TTS helper ────────────────────────────────────────────
# Generates audio using mlx-audio / Kokoro. Sets TMP_FILE on success.
# Returns 0 on success, 1 on failure.
run_local_tts() {
    rm -f "$TMP_FILE"  # clean up ElevenLabs temp file if falling back
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp/}speak11_tts_XXXXXXXXXX")
    python3 -m mlx_audio.tts.generate \
        --model mlx-community/Kokoro-82M-bf16 \
        --text "$TEXT" \
        --voice "${LOCAL_VOICE:-af_heart}" \
        --speed "$SPEED" \
        --lang_code "${LOCAL_VOICE:0:1}" \
        --output_path "$TMP_DIR" \
        --file_prefix speak11 \
        --audio_format wav \
        --join_audio 2>/dev/null
    TMP_FILE="$TMP_DIR/speak11.wav"
    [ -s "$TMP_FILE" ]
}

# ── Play audio helper ──────────────────────────────────────────
# Writes playback status (for live settings preview), then plays the audio.
play_audio() {
    local duration
    duration=$(afinfo "$TMP_FILE" 2>/dev/null | awk '/estimated duration/{print $3}')
    printf '%s\n%s\n' "$(date +%s)" "${duration:-0}" > "$STATUS_FILE"
    afplay "$TMP_FILE" &
    PLAY_PID=$!
    echo "$PLAY_PID" > "$PID_FILE"
    wait "$PLAY_PID"
}

# ── Auto-mode resolution ──────────────────────────────────────────
if [ "$TTS_BACKEND" = "auto" ]; then
    TTS_BACKENDS_INSTALLED="both"  # auto always enables fallback
    if [ -z "$ELEVENLABS_API_KEY" ]; then
        # No API key available — go straight to local TTS
        TTS_BACKEND="local"
    fi
fi

# ── Generate audio ───────────────────────────────────────────────

if [ "$TTS_BACKEND" = "local" ]; then
    # ── Local TTS (mlx-audio / Kokoro) ───────────────────────────
    if ! run_local_tts; then
        osascript -e 'display dialog "Local TTS generation failed." & return & return & "Make sure mlx-audio is installed: pip3 install mlx-audio" with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
        exit 1
    fi
else
    # ── ElevenLabs (cloud API) ───────────────────────────────────

    # Escape text for JSON — python3 handles arbitrary Unicode safely
    JSON_TEXT=$(python3 -c "import json, sys; print(json.dumps(sys.stdin.read()))" <<< "$TEXT")
    if [ $? -ne 0 ] || [ -z "$JSON_TEXT" ]; then
        osascript -e 'display dialog "Failed to encode the selected text as JSON." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
        exit 1
    fi

    TMP_FILE=$(mktemp "${TMPDIR:-/tmp/}speak11_tts_XXXXXXXXXX")
    if [ -z "$TMP_FILE" ] || [ ! -f "$TMP_FILE" ]; then
        osascript -e 'display dialog "Failed to create a temporary file. Check that /tmp is writable." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
        exit 1
    fi

    # Capture both curl exit code and HTTP response code
    set +e
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
    CURL_EXIT=$?
    set -e

    # ── Network failure (offline, DNS, timeout) ──────────────────
    if [ $CURL_EXIT -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
        if [ "$TTS_BACKENDS_INSTALLED" = "both" ]; then
            if run_local_tts; then
                play_audio
                exit 0
            fi
            # Local fallback also failed (e.g. model not yet downloaded)
            osascript -e 'display dialog "Could not reach ElevenLabs, and local TTS also failed." & return & return & "The Kokoro model may need to download first — try again while online." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
            exit 1
        fi
        osascript -e 'display dialog "Could not reach ElevenLabs." & return & return & "Check your internet connection, or install local TTS for offline use." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
        exit 1
    fi

    # ── HTTP 429 (quota exceeded) ────────────────────────────────
    if [ "$HTTP_CODE" = "429" ]; then
        # If both backends are installed, fall back silently
        if [ "$TTS_BACKENDS_INSTALLED" = "both" ]; then
            if run_local_tts; then
                play_audio
                exit 0
            fi
            # Local fallback also failed
            osascript -e 'display dialog "ElevenLabs quota exceeded, and local TTS also failed." & return & return & "Make sure mlx-audio is installed: pip3 install mlx-audio" with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
            exit 1
        fi
        # ElevenLabs only — offer to install local TTS
        if [ "$(uname -m)" = "arm64" ]; then
            QUOTA_RESULT=$(osascript -e 'button returned of (display dialog "You'\''ve hit your ElevenLabs quota." & return & return & "Install mlx-audio for free local TTS, or upgrade your ElevenLabs plan." with title "Speak11" buttons {"Not Now", "Install Local TTS"} default button "Install Local TTS" with icon caution)' 2>/dev/null || true)
            if [ "$QUOTA_RESULT" = "Install Local TTS" ]; then
                if bash "$SCRIPT_DIR/install-local.sh" 2>/dev/null; then
                    osascript -e 'display dialog "Local TTS installed and ready." & return & return & "Your backend has been switched to local." with title "Speak11" buttons {"OK"} default button "OK"' 2>/dev/null
                    if run_local_tts; then
                        play_audio
                    fi
                else
                    osascript -e 'display dialog "Failed to install mlx-audio." & return & return & "You can install it manually: pip3 install mlx-audio" with title "Speak11" buttons {"OK"} default button "OK" with icon caution' 2>/dev/null
                fi
                exit 0
            fi
        fi
        # "Not Now" or Intel Mac — fall through to generic error handler
    fi

    # ── Handle other errors ──────────────────────────────────────
    if [ "$HTTP_CODE" != "200" ]; then
        SAFE_ERROR=$(cat "$TMP_FILE" 2>/dev/null \
            | head -c 300 \
            | tr -d '\000-\037"\\')
        osascript -e "display dialog \"ElevenLabs API error (HTTP ${HTTP_CODE}):\" & return & return & \"${SAFE_ERROR:-Unknown error}\" with title \"Speak11\" buttons {\"OK\"} default button \"OK\" with icon caution"
        exit 1
    fi

    if [ ! -s "$TMP_FILE" ]; then
        osascript -e 'display dialog "ElevenLabs returned an empty audio response." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
        exit 1
    fi
fi

# ── Play audio ─────────────────────────────────────────────────────
play_audio
