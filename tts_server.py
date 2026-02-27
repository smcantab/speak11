#!/usr/bin/env python3
"""Persistent TTS daemon for Speak11.

Keeps the Kokoro model loaded in memory and serves TTS requests over a Unix
socket.

Two modes:
  Default:   started on-demand by speak.sh; auto-shuts down after idle timeout.
  --managed: started by the Settings app; no idle timeout, shuts down when
             the parent process exits (or on SIGTERM).
"""

import fcntl
import json
import os
import signal
import socket
import sys
import tempfile
import threading
import time
import traceback

# ── Paths ────────────────────────────────────────────────────────────

DATA_DIR = os.path.expanduser("~/.local/share/speak11")
SOCKET_PATH = os.path.join(DATA_DIR, "tts.sock")
PID_FILE = os.path.join(DATA_DIR, "tts_server.pid")
LOCK_FILE = os.path.join(DATA_DIR, "tts_server.lock")
LOG_FILE = os.path.join(DATA_DIR, "tts.log")

# Idle timeout in seconds.  Override with SPEAK11_IDLE_TIMEOUT env var.
IDLE_TIMEOUT = int(os.environ.get("SPEAK11_IDLE_TIMEOUT", "300"))

# ── Logging ──────────────────────────────────────────────────────────


def log(msg):
    """Append a timestamped line to the shared log file."""
    try:
        with open(LOG_FILE, "a") as f:
            f.write(
                f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] tts_server: {msg}\n"
            )
    except OSError:
        pass


# ── Globals ──────────────────────────────────────────────────────────

model = None
last_request_time = time.time()
server_socket = None
shutdown_event = threading.Event()
managed_mode = False

# ── Model ────────────────────────────────────────────────────────────


def load_tts_model():
    """Load Kokoro model into memory."""
    global model
    from mlx_audio.tts.utils import load_model

    log("loading model mlx-community/Kokoro-82M-bf16")
    model = load_model("mlx-community/Kokoro-82M-bf16")
    log("model loaded")


def warmup_pipeline():
    """Run a short generation to pre-cache the language pipeline.

    The first generation for each language initializes a KokoroPipeline
    (phonemizer, espeak-ng).  This adds ~400ms overhead.  Running a short
    warmup after model load eliminates that penalty for real requests.
    """
    try:
        log("warming up pipeline")
        for _ in model.generate(text=".", voice="bf_lily", speed=1.0, lang_code="b"):
            pass
        log("pipeline warm")
    except Exception as e:
        log(f"warmup failed (non-fatal): {e}")


def generate_audio(text, voice, speed, lang_code):
    """Generate a WAV file from text.  Returns the file path."""
    import gc

    import mlx.core as mx
    import numpy as np
    from mlx_audio.audio_io import write as audio_write

    tmp_dir = tempfile.mkdtemp(prefix="speak11_tts_")
    out_path = os.path.join(tmp_dir, "speak11.wav")

    try:
        results = model.generate(
            text=text,
            voice=voice,
            speed=float(speed),
            lang_code=lang_code,
        )

        segments = []
        sample_rate = None
        for result in results:
            segments.append(np.array(result.audio))
            sample_rate = result.sample_rate

        if not segments or sample_rate is None:
            raise RuntimeError("model produced no audio")

        audio = np.concatenate(segments) if len(segments) > 1 else segments[0]
        audio_write(out_path, audio, sample_rate, format="wav")

        if not os.path.isfile(out_path) or os.path.getsize(out_path) == 0:
            raise RuntimeError("audio file empty after write")

        # Release MLX metal buffers so memory doesn't accumulate
        del segments, audio
        gc.collect()
        mx.metal.clear_cache()

        return out_path

    except Exception:
        # Clean up temp dir and metal buffers on failure
        import shutil

        shutil.rmtree(tmp_dir, ignore_errors=True)
        gc.collect()
        mx.metal.clear_cache()
        raise


# ── Client handler ───────────────────────────────────────────────────


def handle_client(conn):
    """Read one JSON request, generate audio, send JSON response."""
    global last_request_time
    last_request_time = time.time()

    try:
        data = b""
        conn.settimeout(10)
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break

        if not data.strip():
            return

        request = json.loads(data.decode("utf-8").strip())
        text = request.get("text", "")
        voice = request.get("voice", "bf_lily")
        speed = request.get("speed", "1.00")
        lang_code = request.get("lang_code", "b")

        log(f"request: text_len={len(text)} voice={voice} speed={speed} lang={lang_code}")

        audio_file = generate_audio(text, voice, speed, lang_code)

        response = json.dumps({"status": "ok", "audio_file": audio_file})
        conn.sendall((response + "\n").encode("utf-8"))
        log(f"response: {audio_file}")

    except Exception as e:
        log(f"error: {e}\n{traceback.format_exc()}")
        try:
            response = json.dumps({"status": "error", "message": str(e)})
            conn.sendall((response + "\n").encode("utf-8"))
        except OSError:
            pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


# ── Idle watchdog ────────────────────────────────────────────────────


def idle_watchdog():
    """Background thread: shuts down after IDLE_TIMEOUT of inactivity."""
    while not shutdown_event.is_set():
        remaining = IDLE_TIMEOUT - (time.time() - last_request_time)
        if remaining <= 0:
            log(f"idle for {IDLE_TIMEOUT}s, shutting down")
            do_shutdown()
            return
        shutdown_event.wait(min(remaining + 0.5, 10))


# ── Parent watchdog (managed mode) ───────────────────────────────────


def parent_watchdog():
    """Background thread: shuts down if the parent process dies.

    In managed mode the daemon is a child of the Settings app.  Normal quit
    sends SIGTERM, but if the app crashes the daemon becomes an orphan
    (reparented to PID 1 / launchd).  This watchdog detects that.
    """
    parent_pid = os.getppid()
    if parent_pid <= 1:
        log("already orphaned at startup, shutting down")
        do_shutdown()
        return
    log(f"parent watchdog started (parent pid={parent_pid})")
    while not shutdown_event.is_set():
        if os.getppid() != parent_pid:
            log(f"parent died (was {parent_pid}, now {os.getppid()}), shutting down")
            do_shutdown()
            return
        shutdown_event.wait(2)


# ── Shutdown ─────────────────────────────────────────────────────────


def do_shutdown():
    """Clean shutdown: close socket, remove files, exit."""
    shutdown_event.set()
    if server_socket is not None:
        try:
            server_socket.close()
        except OSError:
            pass
    for path in (SOCKET_PATH, PID_FILE):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    log("shutdown complete")
    os._exit(0)


def handle_signal(signum, _frame):
    log(f"received signal {signum}")
    do_shutdown()


# ── Main ─────────────────────────────────────────────────────────────


def main():
    global server_socket, managed_mode

    managed_mode = "--managed" in sys.argv[1:]

    os.makedirs(DATA_DIR, exist_ok=True)

    # Acquire exclusive lock — guarantees at most one daemon runs.
    # The lock is held for the lifetime of the process and released
    # automatically on exit (even on crash or SIGKILL).
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # Another daemon already holds the lock — exit cleanly.
        sys.exit(0)

    # Write PID file (safe — we hold the lock)
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    # Remove stale socket
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    # Clean up orphaned temp dirs from previous interrupted generations
    import glob
    import shutil

    for d in glob.glob(os.path.join(tempfile.gettempdir(), "speak11_tts_*")):
        try:
            shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass

    # Signal handlers for clean shutdown
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Load model (slow — speak.sh waits for the socket to appear)
    load_tts_model()

    # Warm up the pipeline so the first real request is fast
    warmup_pipeline()

    # Start watchdog
    if managed_mode:
        watchdog = threading.Thread(target=parent_watchdog, daemon=True)
    else:
        watchdog = threading.Thread(target=idle_watchdog, daemon=True)
    watchdog.start()

    # Create socket — this signals readiness to speak.sh (it polls for the
    # socket file to appear).
    server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server_socket.bind(SOCKET_PATH)
    server_socket.listen(2)
    server_socket.settimeout(5)

    mode_str = "managed" if managed_mode else f"idle timeout {IDLE_TIMEOUT}s"
    log(f"listening on {SOCKET_PATH} ({mode_str})")

    # Accept loop
    while not shutdown_event.is_set():
        try:
            conn, _ = server_socket.accept()
            handle_client(conn)
        except socket.timeout:
            continue
        except OSError:
            if not shutdown_event.is_set():
                log("socket error in accept loop")
            break

    do_shutdown()


if __name__ == "__main__":
    main()
