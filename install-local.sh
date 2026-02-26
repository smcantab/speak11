#!/bin/bash
# install-local.sh — Install mlx-audio for local TTS in Speak11
#
# Called by install.command (during setup) or speak.sh (on ElevenLabs quota hit).
# Updates ~/.config/speak11/config to reflect the new backend.

set -eo pipefail

# ── Apple Silicon check ──────────────────────────────────────────
if [ "$(uname -m)" != "arm64" ]; then
    echo "Local TTS requires Apple Silicon (M1 or later)." >&2
    exit 1
fi

# ── Skip if already installed ────────────────────────────────────
if python3 -c "import mlx_audio" 2>/dev/null; then
    echo "mlx-audio is already installed."
else
    set +e
    pip3 install mlx-audio 2>&1
    pip_exit=$?
    set -e
    if [ $pip_exit -ne 0 ]; then
        echo "Failed to install mlx-audio." >&2
        exit 1
    fi
    echo "mlx-audio installed."
fi

# ── Download Kokoro model ──────────────────────────────────────
# Pre-download the model so first use is instant and works offline.
if ! python3 -c "from huggingface_hub import try_to_load_from_cache; assert try_to_load_from_cache('mlx-community/Kokoro-82M-bf16', 'config.json') is not None" 2>/dev/null; then
    echo "Downloading Kokoro voice model (~350 MB)…"
    set +e
    python3 -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/Kokoro-82M-bf16')" 2>&1
    dl_exit=$?
    set -e
    if [ $dl_exit -ne 0 ]; then
        echo "Warning: model download failed. It will download on first use." >&2
    else
        echo "Kokoro model downloaded."
    fi
else
    echo "Kokoro model already cached."
fi

# ── Update config ────────────────────────────────────────────────
_CONFIG="$HOME/.config/speak11/config"
mkdir -p "$(dirname "$_CONFIG")"

if [ -f "$_CONFIG" ]; then
    # Update TTS_BACKENDS_INSTALLED to "both" if config exists
    if grep -q '^TTS_BACKENDS_INSTALLED=' "$_CONFIG"; then
        sed -i '' 's/^TTS_BACKENDS_INSTALLED=.*/TTS_BACKENDS_INSTALLED="both"/' "$_CONFIG"
    else
        printf 'TTS_BACKENDS_INSTALLED="both"\n' >> "$_CONFIG"
    fi
    # Set active backend to local
    if grep -q '^TTS_BACKEND=' "$_CONFIG"; then
        sed -i '' 's/^TTS_BACKEND=.*/TTS_BACKEND="local"/' "$_CONFIG"
    else
        printf 'TTS_BACKEND="local"\n' >> "$_CONFIG"
    fi
else
    # Create config with local backend
    cat > "$_CONFIG" << 'EOF'
TTS_BACKEND="local"
TTS_BACKENDS_INSTALLED="both"
LOCAL_VOICE="af_heart"
LOCAL_LANG="a"
SPEED="1.00"
EOF
fi

echo "Config updated: backend set to local."
