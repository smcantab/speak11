#!/bin/bash
# install-local.sh — Install mlx-audio for local TTS in Speak11
#
# Creates a Python venv at ~/.local/share/speak11/venv with mlx-audio and
# all dependencies.  Requires Python 3.10+ — if none is found on the system,
# a standalone build is downloaded automatically.
#
# Called by install.command (during setup), speak.sh (on quota hit), or the
# menu bar settings app (when selecting a backend that needs local TTS).
# Updates ~/.config/speak11/config to reflect the new backend.

set -eo pipefail

VENV_DIR="$HOME/.local/share/speak11/venv"

# ── Apple Silicon check ──────────────────────────────────────────
if [ "$(uname -m)" != "arm64" ]; then
    echo "Local TTS requires Apple Silicon (M1 or later)." >&2
    exit 1
fi

# ── Find Python 3.10+ ───────────────────────────────────────────
find_python() {
    # Check common locations for Python 3.10+
    for py in python3.13 python3.12 python3.11 python3.10 \
              /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 \
              /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10 \
              /opt/homebrew/bin/python3 \
              /usr/local/bin/python3.13 /usr/local/bin/python3.12 \
              /usr/local/bin/python3.11 /usr/local/bin/python3.10 \
              /usr/local/bin/python3 \
              /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
              /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
              /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
              /Library/Frameworks/Python.framework/Versions/3.10/bin/python3 \
              "$HOME/.pyenv/versions"/3.*/bin/python3 \
              "$HOME/miniconda3/bin/python3" \
              "$HOME/anaconda3/bin/python3"; do
        local p
        p=$(command -v "$py" 2>/dev/null || echo "$py")
        [ -x "$p" ] || continue
        local ver
        ver=$("$p" -c "import sys; print(sys.version_info >= (3,10))" 2>/dev/null) || continue
        if [ "$ver" = "True" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# ── Download standalone Python ────────────────────────────────────
# If no system Python 3.10+ exists, fetch a standalone build from
# python-build-standalone (Astral).  ~17 MB download, ~80 MB extracted.
STANDALONE_DIR="$HOME/.local/share/speak11/python"
STANDALONE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260211/cpython-3.12.12+20260211-aarch64-apple-darwin-install_only.tar.gz"
STANDALONE_SHA256="20d98bd10cf59e3c16dc4e44b57be351b250fc1089e95b2839f440f79413ed47"

download_python() {
    # Return cached standalone if already downloaded
    if [ -x "$STANDALONE_DIR/bin/python3" ]; then
        local ver
        ver=$("$STANDALONE_DIR/bin/python3" -c "import sys; print(sys.version_info >= (3,10))" 2>/dev/null) || true
        if [ "$ver" = "True" ]; then
            echo "$STANDALONE_DIR/bin/python3"
            return 0
        fi
    fi

    echo "Downloading standalone Python 3.12…" >&2
    local tmp_tar
    tmp_tar=$(mktemp /tmp/speak11-python-XXXXXX)

    if ! curl -fSL --progress-bar -o "$tmp_tar" "$STANDALONE_URL"; then
        rm -f "$tmp_tar"
        echo "Failed to download standalone Python. Check your internet connection and try again." >&2
        return 1
    fi

    # Verify SHA256
    local actual_sha
    actual_sha=$(shasum -a 256 "$tmp_tar" | awk '{print $1}')
    if [ "$actual_sha" != "$STANDALONE_SHA256" ]; then
        rm -f "$tmp_tar"
        echo "SHA256 mismatch for standalone Python download." >&2
        echo "  Expected: $STANDALONE_SHA256" >&2
        echo "  Got:      $actual_sha" >&2
        return 1
    fi

    # Extract — archive contains python/ directory
    mkdir -p "$STANDALONE_DIR"
    if ! tar -xzf "$tmp_tar" -C "$STANDALONE_DIR" --strip-components=1; then
        rm -f "$tmp_tar"
        echo "Failed to extract standalone Python." >&2
        return 1
    fi
    rm -f "$tmp_tar"

    if [ -x "$STANDALONE_DIR/bin/python3" ]; then
        echo "$STANDALONE_DIR/bin/python3"
        return 0
    else
        echo "Failed to extract standalone Python." >&2
        return 1
    fi
}

PYTHON=$(find_python) || true

if [ -z "$PYTHON" ]; then
    echo "No Python 3.10+ found on system. Downloading standalone Python…"
    PYTHON=$(download_python) || true
    if [ -z "$PYTHON" ]; then
        echo "Failed to set up Python." >&2
        exit 1
    fi
fi

echo "Using $("$PYTHON" --version 2>&1) at $PYTHON"

# ── Create / update venv ─────────────────────────────────────────
if [ -d "$VENV_DIR" ] && "$VENV_DIR/bin/python3" -c "import mlx_audio" 2>/dev/null; then
    echo "mlx-audio venv already exists."
else
    echo "Creating Python venv at $VENV_DIR…"
    rm -rf "$VENV_DIR"
    "$PYTHON" -m venv "$VENV_DIR"

    echo "Installing mlx-audio and dependencies…"
    set +e
    "$VENV_DIR/bin/pip" install --upgrade pip 2>&1
    "$VENV_DIR/bin/pip" install mlx-audio soundfile sounddevice scipy loguru \
        "misaki==0.8.4" num2words spacy phonemizer espeakng_loader 2>&1
    pip_exit=$?
    set -e
    if [ $pip_exit -ne 0 ]; then
        echo "Failed to install mlx-audio." >&2
        rm -rf "$VENV_DIR"
        exit 1
    fi
    echo "mlx-audio installed."
fi

# ── Download Kokoro model ──────────────────────────────────────
# Pre-download the model so first use is instant and works offline.
if ! "$VENV_DIR/bin/python3" -c "from huggingface_hub import try_to_load_from_cache; assert try_to_load_from_cache('mlx-community/Kokoro-82M-bf16', 'config.json') is not None" 2>/dev/null; then
    echo "Downloading Kokoro voice model (~350 MB)…"
    set +e
    "$VENV_DIR/bin/python3" -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/Kokoro-82M-bf16')" 2>&1
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
    # Mark local as installed — don't change the active backend (caller decides)
    if grep -q '^TTS_BACKENDS_INSTALLED=' "$_CONFIG"; then
        sed -i '' 's/^TTS_BACKENDS_INSTALLED=.*/TTS_BACKENDS_INSTALLED="both"/' "$_CONFIG"
    else
        printf 'TTS_BACKENDS_INSTALLED="both"\n' >> "$_CONFIG"
    fi
else
    # Create config with auto backend (degrades to local if no API key)
    cat > "$_CONFIG" << 'EOF'
TTS_BACKEND="auto"
TTS_BACKENDS_INSTALLED="both"
LOCAL_VOICE="bf_lily"
SPEED="1.00"
LOCAL_SPEED="1.00"
EOF
fi

echo "Config updated: local TTS available."
