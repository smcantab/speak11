#!/bin/bash
# ── Speak11 profiling utility ───────────────────────────────────────
# Usage: bash tests/profile.sh [--components] [text]
#
# Runs speak.sh end-to-end with high-resolution timestamps on every
# command (via bash -x + PS4), then extracts phase timings from the
# trace. This is the same technique that found the O(n^2) bash
# substitution bottleneck.
#
# --components: also run isolated micro-benchmarks comparing old vs new
#               implementations (json_encode vs python3, etc.)
#
# Playback is stubbed (afplay replaced with sleep 0.1) so the profile
# measures generation time without waiting for audio.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEAK_SH="$SCRIPT_DIR/speak.sh"
DATA_DIR="$HOME/.local/share/speak11"

# ── Helpers ──────────────────────────────────────────────────────────

now() {
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time'
}

elapsed_ms() {
    local start="$1" end="$2"
    echo "$end $start" | awk '{printf "%.1f", ($1 - $2) * 1000}'
}

fmt_ms() {
    local ms="$1"
    if echo "$ms" | awk '{exit ($1 < 10) ? 0 : 1}'; then
        printf "\033[32m%7s ms\033[0m" "$ms"  # green: fast
    elif echo "$ms" | awk '{exit ($1 < 100) ? 0 : 1}'; then
        printf "\033[33m%7s ms\033[0m" "$ms"  # yellow: moderate
    else
        printf "\033[31m%7s ms\033[0m" "$ms"  # red: slow
    fi
}

# ── Parse args ───────────────────────────────────────────────────────

COMPONENTS=false
TEXT=""
for arg in "$@"; do
    case "$arg" in
        --components) COMPONENTS=true ;;
        *) [ -z "$TEXT" ] && TEXT="$arg" ;;
    esac
done

[ -z "$TEXT" ] && TEXT='The morning light filtered through the kitchen window as she poured her first cup of coffee. Outside, the garden was coming alive with the first signs of spring. She could hear the birds singing in the old oak tree, the same tree her grandfather had planted decades ago.

She sat down at the table and opened her notebook. There were lists to make, plans to finalize, and a letter she had been meaning to write for weeks. The letter was the hardest part. How do you say goodbye to someone who shaped everything about the way you see the world?

Dr. Smith had suggested she try writing it out, even if she never sent it. "Sometimes the act of writing is enough," he had said during their last session. Mrs. Johnson from next door had given similar advice, though in her characteristically blunt way: "Just write the damn thing and be done with it."

The pen felt heavy in her hand. She started with the easy parts -- the memories that made her smile. The Sunday morning pancakes. The way he always hummed off-key while washing the dishes. The bedtime stories that never quite ended the same way twice, because he could never remember where he had left off.

But then came the harder parts. The arguments that went nowhere. The long silences that stretched across dinner tables. The promises that were made and broken and made again, each time with a little less conviction. She had learned, eventually, that love and disappointment could exist in the same space, occupying the same heart without canceling each other out.

The coffee grew cold as she wrote. Page after page, the words came faster than she expected. By the time she looked up, the morning light had shifted, and the shadows in the kitchen had moved. The letter was done. She folded it carefully, slid it into an envelope, and wrote his name on the front.

She would not send it. But she felt lighter. Dr. Smith was right. Sometimes the act of writing is enough.'

printf "\n\033[1mSpeak11 Performance Profile\033[0m\n"
printf "═══════════════════════════════════════════════════════════\n"
printf "  Text: %d chars\n" "${#TEXT}"
printf "═══════════════════════════════════════════════════════════\n\n"

# ══════════════════════════════════════════════════════════════════════
# END-TO-END: run speak.sh with bash -x and high-res PS4 timestamps
# ══════════════════════════════════════════════════════════════════════

printf "\033[1mEnd-to-end pipeline (bash -x trace)\033[0m\n"
printf "───────────────────────────────────────────────────────────\n"

# Stubs: replace afplay with a no-op so we don't wait for audio
_STUBS=$(mktemp -d)
printf '#!/bin/bash\nsleep 0.01 &\necho $!\n' > "$_STUBS/afplay"
chmod +x "$_STUBS/afplay"
# osascript stub: mute check returns false
printf '#!/bin/bash\necho "false"\n' > "$_STUBS/osascript"
chmod +x "$_STUBS/osascript"
# security stub: no API key
printf '#!/bin/bash\nexit 1\n' > "$_STUBS/security"
chmod +x "$_STUBS/security"
# afinfo stub: fake duration
printf '#!/bin/bash\necho "   estimated duration: 3.000000 sec"\n' > "$_STUBS/afinfo"
chmod +x "$_STUBS/afinfo"

_TRACE=$(mktemp)

# Run speak.sh with -x tracing. PS4 prefixes each traced line with a
# high-resolution timestamp. stdout (TTS model output) goes to /dev/null.
# stderr gets the trace log.
# Use a temp file for input to avoid pipe (which prevents stderr redirect).
_INPUT=$(mktemp)
printf '%s' "$TEXT" > "$_INPUT"
TTS_BACKEND=local SPEAK11_MUTE_CHECKED=1 SPEAK11_NO_QUEUE_PLAYER=1 PATH="$_STUBS:$PATH" \
    PS4='+$(/usr/bin/perl -MTime::HiRes=time -e "printf q{%.6f }, time") ' \
    bash -x "$SPEAK_SH" < "$_INPUT" >"$_TRACE.out" 2>"$_TRACE" || true
rm -f "$_INPUT" "$_TRACE.out"

rm -rf "$_STUBS"

# ── Parse trace for phase timestamps ─────────────────────────────────
# Each line looks like: +1741234567.890123 command...
# We find the first occurrence of key patterns to mark phase boundaries.

_first_ts() {
    # Return the timestamp of the first line matching pattern
    local line
    line=$(grep -m1 "$1" "$_TRACE" 2>/dev/null || true)
    [ -n "$line" ] && echo "$line" | awk '{print $1}' | tr -d '+' || true
}

# Phase markers (in execution order)
T_START=$(_first_ts 'TEXT=')                          # text read from stdin/pbpaste
T_VALIDATE=$(_first_ts '\[\[.*=~.*\[:space:\]')       # whitespace check
T_ICONV=$(_first_ts 'iconv')                          # UTF-8 cleanup
T_MUTE=$(_first_ts '_AUDIO_TOOL=\|output muted\|osascript')  # mute check
T_SPLIT=$(_first_ts 'split_sentences')                 # sentence splitting
T_FIRST_GEN=$(_first_ts 'tts_daemon_request\|run_local_tts\|run_elevenlabs_tts')  # first TTS
T_FIRST_PLAY=$(_first_ts 'play_audio')                 # first play_audio call
T_LAST_LINE=$(tail -1 "$_TRACE" | awk '{print $1}' | tr -d '+')  # end of script

printf "\n"

# Print phase timings
_print_phase() {
    local label="$1" t_start="$2" t_end="$3"
    if [ -n "$t_start" ] && [ -n "$t_end" ]; then
        printf "   %-30s %s\n" "$label:" "$(fmt_ms "$(elapsed_ms "$t_start" "$t_end")")"
    fi
}

_print_phase "Text read + validate"     "$T_START"      "$T_ICONV"
_print_phase "iconv UTF-8 cleanup"      "$T_ICONV"      "$T_MUTE"
_print_phase "Mute check"               "$T_MUTE"       "$T_SPLIT"
_print_phase "Sentence splitting"       "$T_SPLIT"      "$T_FIRST_GEN"
_print_phase "First TTS generation"     "$T_FIRST_GEN"  "$T_FIRST_PLAY"

# Warn if daemon was bypassed (fallback to cold model load)
if grep -q 'falling back to direct invocation' "$_TRACE" 2>/dev/null; then
    printf "   \033[31m⚠  DAEMON BYPASSED — fell back to cold model load\033[0m\n"
fi

if [ -n "$T_START" ] && [ -n "$T_FIRST_PLAY" ]; then
    _ttfa=$(elapsed_ms "$T_START" "$T_FIRST_PLAY")
    printf "   \033[1m%-30s %s\033[0m\n" "TIME TO FIRST AUDIO:" "$(fmt_ms "$_ttfa")"
fi

_print_phase "Total pipeline"           "$T_START"      "$T_LAST_LINE"

# Count sentences
_NPLAY=$(grep -c 'play_audio' "$_TRACE" 2>/dev/null || echo "0")
printf "   Sentences:                      %s\n" "$_NPLAY"

# Per-sentence timing: time between successive play_audio calls
printf "\n   Per-sentence generation times:\n"
_play_times=()
while IFS= read -r _ts; do
    [ -n "$_ts" ] && _play_times+=("$_ts")
done < <(grep 'play_audio' "$_TRACE" | awk '{print $1}' | tr -d '+')
for (( _i=1; _i<${#_play_times[@]}; _i++ )); do
    _ms=$(elapsed_ms "${_play_times[_i-1]}" "${_play_times[_i]}")
    printf "     sentence %2d: %s\n" "$((_i+1))" "$(fmt_ms "$_ms")"
done

rm -f "$_TRACE"

# ══════════════════════════════════════════════════════════════════════
# COMPONENT BENCHMARKS (optional, --components flag)
# ══════════════════════════════════════════════════════════════════════

if $COMPONENTS; then
    printf "\n\n\033[1mComponent benchmarks (old vs new)\033[0m\n"
    printf "───────────────────────────────────────────────────────────\n"

    eval "$(sed -n '/^json_encode() *{/,/^}/p' "$SPEAK_SH")" 2>/dev/null || true
    eval "$(sed -n '/^wav_duration() *{/,/^}/p' "$SPEAK_SH")" 2>/dev/null || true

    _SENT="She sat down at the table and opened her notebook."

    # JSON encoding
    printf "\n\033[1mJSON encoding (10 calls)\033[0m\n"
    if type json_encode &>/dev/null; then
        t0=$(now); for _ in $(seq 10); do json_encode "$_SENT" >/dev/null; done; t1=$(now)
        printf "   json_encode (bash):            %s\n" "$(fmt_ms "$(elapsed_ms "$t0" "$t1")")"
    fi
    t0=$(now); for _ in $(seq 10); do python3 -c "import json,sys;print(json.dumps(sys.stdin.read()))" <<< "$_SENT" >/dev/null; done; t1=$(now)
    printf "   python3 json.dumps:            %s\n" "$(fmt_ms "$(elapsed_ms "$t0" "$t1")")"

    # WAV duration
    printf "\n\033[1mWAV duration (10 calls)\033[0m\n"
    _W=$(mktemp "${TMPDIR:-/tmp/}speak11_prof_XXXXXXXXXX.wav")
    python3 -c "
import struct,sys;sr=24000;ch=1;bps=16;n=sr*5;ds=n*ch*(bps//8)
with open(sys.argv[1],'wb') as f:
    f.write(b'RIFF');f.write(struct.pack('<I',36+ds));f.write(b'WAVEfmt ')
    f.write(struct.pack('<IHHIIHH',16,1,ch,sr,sr*ch*(bps//8),ch*(bps//8),bps))
    f.write(b'data');f.write(struct.pack('<I',ds));f.write(b'\x00'*ds)
" "$_W" 2>/dev/null
    if type wav_duration &>/dev/null; then
        t0=$(now); for _ in $(seq 10); do wav_duration "$_W" >/dev/null 2>&1; done; t1=$(now)
        printf "   wav_duration (stat+bc):        %s\n" "$(fmt_ms "$(elapsed_ms "$t0" "$t1")")"
    fi
    t0=$(now); for _ in $(seq 10); do afinfo "$_W" 2>/dev/null | awk '/estimated duration/{print $3}' >/dev/null; done; t1=$(now)
    printf "   afinfo + awk:                  %s\n" "$(fmt_ms "$(elapsed_ms "$t0" "$t1")")"
    rm -f "$_W"

    # Daemon communication
    printf "\n\033[1mDaemon request (1 sentence)\033[0m\n"
    TTS_SOCK="$DATA_DIR/tts.sock"
    if [ -S "$TTS_SOCK" ] && type json_encode &>/dev/null; then
        _E=$(json_encode "$_SENT")
        _REQ="{\"text\":${_E},\"voice\":\"bf_lily\",\"speed\":\"1.00\",\"lang_code\":\"b\"}"

        t0=$(now); _R=$(printf '%s\n' "$_REQ" | nc -U "$TTS_SOCK" 2>/dev/null) || true; t1=$(now)
        printf "   nc -U:                         %s\n" "$(fmt_ms "$(elapsed_ms "$t0" "$t1")")"
        _AF="${_R#*\"audio_file\":\"}"; _AF="${_AF%%\"*}"; [ -f "$_AF" ] && rm -rf "$(dirname "$_AF")"

        t0=$(now)
        printf '%s' "$_SENT" | _SOCK="$TTS_SOCK" _VOICE="bf_lily" _SPEED="1.00" _LANG="b" \
            python3 -c "
import json,socket,sys,os;text=sys.stdin.read()
req=json.dumps({'text':text,'voice':os.environ['_VOICE'],'speed':os.environ['_SPEED'],'lang_code':os.environ['_LANG']})
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(120);s.connect(os.environ['_SOCK'])
s.sendall((req+'\n').encode());d=b''
while True:
    c=s.recv(4096)
    if not c:break
    d+=c
    if b'\n' in d:break
s.close();r=json.loads(d.decode().strip())
if r.get('status')=='ok':print(r['audio_file'])
" 2>/dev/null || true
        t1=$(now)
        printf "   python3 socket:                %s\n" "$(fmt_ms "$(elapsed_ms "$t0" "$t1")")"
    else
        printf "   \033[33mDaemon not running\033[0m\n"
    fi
fi

printf "\n═══════════════════════════════════════════════════════════\n"
printf "\033[1mLegend:\033[0m  \033[32m< 10ms\033[0m  \033[33m10-100ms\033[0m  \033[31m> 100ms\033[0m\n"
printf "═══════════════════════════════════════════════════════════\n\n"
