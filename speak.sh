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
_ENV_LOCAL_SPEED="${LOCAL_SPEED:-}"
_ENV_SPEED="${SPEED:-}"

# Load settings written by the menu bar settings app.
_CONFIG="$HOME/.config/speak11/config"
[ -f "$_CONFIG" ] && source "$_CONFIG"

# Priority: environment variable > config file > hardcoded default.
TTS_BACKEND="${_ENV_TTS_BACKEND:-${TTS_BACKEND:-auto}}"
TTS_BACKENDS_INSTALLED="${_ENV_TTS_BACKENDS_INSTALLED:-${TTS_BACKENDS_INSTALLED:-elevenlabs}}"
LOCAL_VOICE="${_ENV_LOCAL_VOICE:-${LOCAL_VOICE:-bf_lily}}"

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

SPEED="${_ENV_SPEED:-${SPEED:-1.0}}"
LOCAL_SPEED="${_ENV_LOCAL_SPEED:-${LOCAL_SPEED:-1.0}}"

# ── Validate numeric config values ───────────────────────────────
# Prevents malformed JSON if config is manually edited with bad values.
_validate_num() { [[ "$2" =~ ^[0-9]*\.?[0-9]+$ ]] && echo "$2" || echo "$3"; }
SPEED=$(_validate_num SPEED "$SPEED" "1.0")
LOCAL_SPEED=$(_validate_num LOCAL_SPEED "$LOCAL_SPEED" "1.0")
if [ "$TTS_BACKEND" = "elevenlabs" ] || [ "$TTS_BACKEND" = "auto" ]; then
    STABILITY=$(_validate_num STABILITY "$STABILITY" "0.5")
    SIMILARITY_BOOST=$(_validate_num SIMILARITY_BOOST "$SIMILARITY_BOOST" "0.75")
    STYLE=$(_validate_num STYLE "$STYLE" "0.0")
    case "$USE_SPEAKER_BOOST" in true|false) ;; *) USE_SPEAKER_BOOST="true" ;; esac
fi

# ── Auto-mode resolution ──────────────────────────────────────────
# Must run before preflight checks so the python3 guard knows the
# resolved backend (auto → local when there is no API key).
if [ "$TTS_BACKEND" = "auto" ]; then
    TTS_BACKENDS_INSTALLED="both"  # auto always enables fallback
    if [ -z "$ELEVENLABS_API_KEY" ]; then
        # No API key available — go straight to local TTS
        TTS_BACKEND="local"
    fi
fi

# ── Toggle: stop playback if already running ───────────────────────
PID_FILE="${TMPDIR:-/tmp}/speak11_tts.pid"
TEXT_FILE="${TMPDIR:-/tmp}/speak11_text"
STATUS_FILE="${TMPDIR:-/tmp}/speak11_status"
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        # Kill children first (curl, python, afplay) so bash can handle SIGTERM
        pkill -P "$OLD_PID" 2>/dev/null
        kill "$OLD_PID" 2>/dev/null
        # Wait for process to die (up to 0.5s, checking every 50ms)
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.05
        done
        # Force-kill if still alive (e.g. stuck in subprocess)
        kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null
        # Only remove PID file if it still belongs to the process we killed
        # (a new instance may have started and written its PID while we waited)
        [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$OLD_PID" ] && rm -f "$PID_FILE"
        exit 0
    fi
    rm -f "$PID_FILE"  # stale PID, clean up and continue
fi

# ── Read selected text ─────────────────────────────────────────────
if [ -t 0 ]; then
    TEXT=$(pbpaste 2>/dev/null)
else
    TEXT=$(cat /dev/stdin)
    # Bash 3.2: ${TEXT//[[:space:]]/} is O(n^2) — use regex match instead
    if ! [[ "$TEXT" =~ [^[:space:]] ]]; then
        TEXT=$(pbpaste 2>/dev/null)
    fi
fi

if ! [[ "$TEXT" =~ [^[:space:]] ]]; then
    exit 0
fi

# Strip invalid Unicode (unpaired surrogates from PDFs, etc.)
TEXT=$(printf '%s' "$TEXT" | iconv -f UTF-8 -t UTF-8//IGNORE)

# ── Normalize clipboard/PDF text for TTS ──────────────────────────
# Cleans artifacts from PDF copy-paste so TTS engines read text naturally.
# Single python call (~30ms); falls back to bash sed if python is absent.
normalize_text() {
    local py="${VENV_PYTHON:-python3}"
    [ -x "$py" ] 2>/dev/null || py=python3
    local result
    if command -v "$py" >/dev/null 2>&1 && \
       result=$(printf '%s' "$1" | "$py" -c "
import re, sys, unicodedata as _ud

t = sys.stdin.read()

# ── Phase 1: Encoding and character normalization ─────────────
# Fix mojibake (UTF-8 bytes misread as Latin-1/Windows-1252).
try:
    import ftfy
    t = ftfy.fix_text(t)
except ImportError:
    pass
# Line endings: CRLF and stray CR to LF.
t = t.replace('\r\n', '\n').replace('\r', '\n')
# Invisible characters: zero-width, soft hyphens, PUA (math font garbage).
t = re.sub(r'[\u200b\u200c\u200d\ufeff\u00ad]', '', t)
t = re.sub(r'[\ue000-\uf8ff]', '', t)
# Ligatures from PDF fonts: ffi/ffl before fi/fl to avoid partial match.
t = t.replace('\ufb00','ff').replace('\ufb03','ffi').replace('\ufb04','ffl')
t = t.replace('\ufb01','fi').replace('\ufb02','fl')
# Typographic characters to ASCII equivalents.
t = t.replace('\u2212', '-')                            # minus sign
t = t.replace('\u2026', '...')                          # ellipsis
t = t.replace('\u201c','\x22').replace('\u201d','\x22') # smart double quotes
t = t.replace('\u2018','\x27').replace('\u2019','\x27') # smart single quotes
t = t.replace('\u00b7', ' ')                            # middle dot (kg-m)
t = t.replace('\u2032','\x27').replace('\u2033','\x22') # prime / double prime
# Exotic whitespace to regular space.
t = re.sub(r'[\u00a0\u2007\u2009\u200a\u202f\u205f]', ' ', t)
# Unicode subscript digits to regular digits (chemistry: H₂O -> H2O).
t = re.sub(r'[\u2080-\u2089]', lambda m: chr(ord(m.group())-0x2050), t)
# Strip trailing whitespace on each line.
t = re.sub(r'[ \t]+$', '', t, flags=re.MULTILINE)

# ── Phase 2: Line and paragraph structure ─────────────────────
# Rejoin hyphenated word splits at line ends.
t = re.sub(r'(\w)-\n(\w)', r'\1\2', t)
# Protect paragraph breaks (2+ newlines), rejoin the rest.
t = re.sub(r'\n{2,}', '\x00', t)
t = re.sub(r'(?<![.!?:\x22\x27])\n', ' ', t)
t = t.replace('\x00', '\n\n')

# ── Phase 3: Noise removal ────────────────────────────────────
# URLs and DOIs.
t = re.sub(r'https?://\S+', '', t)
t = re.sub(r'(?i)\bdoi:\s*\S+', '', t)
# Citation references (scientific papers).
# Bare citations glued to words: impacts1-8, results1,2,3, shown1.
t = re.sub(r'(?<=[a-z])\d+(?:\s*[,\u2013\u2014-]\s*\d+)*(?=[\s.,;:?!\x27\x22)\]]|$)', '', t)
# Citations after abbreviation period: et al.1-8.
t = re.sub(r'(?<=et al\.)\d+(?:\s*[,\u2013\u2014-]\s*\d+)*', '', t)
# Bracketed refs: [1], [1,2,3], [1-8].
t = re.sub(r'\s*\[\d+(?:\s*[,;\u2013\u2014-]\s*\d+)*\]\s*', ' ', t)
# Parenthetical author-year: (Smith et al., 2020), (Smith 2020; Jones 2021).
t = re.sub(r'\s*\((?:[A-Z][a-z]+(?:\s+(?:et\s+al\.|and\s+[A-Z][a-z]+))?(?:,?\s*\d{4})\s*(?:;\s*[A-Z][a-z]+(?:\s+(?:et\s+al\.|and\s+[A-Z][a-z]+))?(?:,?\s*\d{4})\s*)*)\)\s*', ' ', t)
# Superscript minus+digit (Å⁻¹ -> inverse; before superscript stripping).
t = re.sub(r'\u207b[\xb9\xb2\xb3\u2074-\u2079\u2070]+', lambda m: ' inverse' if m.start()>0 else 'inverse', t)
# Remaining superscript digits.
t = re.sub(r'[\xb9\xb2\xb3\u2074-\u2079\u2070\u00b9]+', '', t)
# Uncertainty notation: 2.5179(4) -> 2.5179 (standard deviation in parens).
t = re.sub(r'(\d\.\d+)\(\d+\)', r'\1', t)
# Miller indices: parenthesized digit groups read digit-by-digit.
def _mill(m):
    return '(' + ' '.join(m.group(1)) + ')'
# Leading zeros are unambiguous: (002), (010) are never regular numbers.
t = re.sub(r'\(0(\d{1,2})\)', lambda m: '(' + ' '.join('0'+m.group(1)) + ')', t)
# Context words before or after expand remaining 3-digit parens.
t = re.sub(r'\b(planes?|reflections?|peaks?|indexed|facets?|diffraction|surfaces?|Miller|directions?)\s+\((\d{3})\)',
    lambda m: m.group(1) + ' (' + ' '.join(m.group(2)) + ')', t)
t = re.sub(r'\((\d{3})\)\s+(planes?|reflections?|peaks?|indexed|facets?|diffraction|surfaces?|Miller|directions?)\b',
    lambda m: '(' + ' '.join(m.group(1)) + ') ' + m.group(2), t)
# Series of 2+ parenthesized digit groups (some may already be expanded).
_MILL_PAREN = r'\(\d(?:\s?\d){0,2}\)'
def _miller_series(m):
    return re.sub(r'\((\d{1,3})\)', _mill, m.group())
t = re.sub(_MILL_PAREN + r'(?:\s*,\s*(?:and\s+)?' + _MILL_PAREN + r'){1,}', _miller_series, t)
# Bullet and list markers at line start.
t = re.sub(r'^[\u2022\u2023\u25e6\u2043\u2219] +', '', t, flags=re.MULTILINE)
t = re.sub(r'^- +', '', t, flags=re.MULTILINE)
t = re.sub(r'^\d+[.)]\s+', '', t, flags=re.MULTILINE)

# ── Phase 4: Dash and punctuation normalization ───────────────
t = re.sub(r' ?[\u2014\u2013] ?', ' -- ', t)  # em/en-dash
t = re.sub(r' ?-{2,3} ?', ' -- ', t)           # ASCII double/triple dash
t = re.sub(r'\.{4,}', '...', t)                # excessive dots
t = re.sub(r'\?{2,}', '?', t)
t = re.sub(r'!{2,}', '!', t)
# Common academic abbreviations.
_ABBR = {'Fig.':'Figure','Figs.':'Figures','fig.':'figure','figs.':'figures',
  'Eq.':'Equation','Eqs.':'Equations','eq.':'equation','eqs.':'equations',
  'Ref.':'Reference','Refs.':'References','ref.':'reference','refs.':'references',
  'Sect.':'Section','sect.':'section','Ch.':'Chapter','ch.':'chapter',
  'Vol.':'Volume','vol.':'volume','No.':'Number','no.':'number',
  'Suppl.':'Supplementary','suppl.':'supplementary',
  'approx.':'approximately','vs.':'versus','e.g.':'for example','i.e.':'that is'}
for _a,_w in sorted(_ABBR.items(), key=lambda x: -len(x[0])):
    t = t.replace(_a, _w)
# Math operators (TTS engines often skip or mispronounce these).
t = re.sub(r' = ', ' equals ', t)
t = re.sub(r' << ', ' much less than ', t)
t = re.sub(r' >> ', ' much greater than ', t)
t = t.replace('~', 'approximately ')

# ── Phase 5: Scientific symbols and units ─────────────────────
# Single-character symbols to spoken form.
_SYM = {
  '\u00c5':' angstroms ', '\u212b':' angstroms ',
  '\u00b1':' plus or minus ', '\u00d7':' times ',
  '\u2248':' approximately ',
  '\u2264':' less than or equal to ','\u2265':' greater than or equal to ',
  '\u221e':' infinity ', '\u221a':' square root of ',
  '\u2192':' to ', '\u2190':' from ', '\u2194':' to and from ',
  '\u21cc':' is in equilibrium with ',
  '\u2260':' not equal to ', '\u2261':' equivalent to ',
  '\u221d':' proportional to ',
  '\u2202':' partial ', '\u2211':' sum of ', '\u220f':' product of ',
  '\u222b':' integral of ', '\u2207':' del ', '\u2205':' empty set ',
  '\u2103':' degrees Celsius ', '\u2109':' degrees Fahrenheit ',
  '\u210f':' h-bar ', '\u2113':' liters ', '\u2030':' per mille ',
  '\u2220':' angle ', '\u2225':' parallel to ',
  '\u22a5':' perpendicular to ',
  '\u2208':' in ', '\u2209':' not in ',
  '\u2282':' subset of ', '\u2283':' superset of ',
  '\u2286':' subset of ', '\u2287':' superset of ',
  '\u2229':' intersection ', '\u222a':' union ',
  '\u2234':' therefore ', '\u2235':' because ',
  '\u27e8':'', '\u27e9':''}  # mathematical angle brackets (Dirac bra-ket)
for _s,_w in _SYM.items():
    t = t.replace(_s, _w)
# Degree+letter units (must precede bare degree).
t = re.sub(r'\u00b0C\b', 'degrees Celsius', t)
t = re.sub(r'\u00b0F\b', 'degrees Fahrenheit', t)
t = re.sub(r'\u00b0K\b', 'degrees Kelvin', t)
t = re.sub(r'(?<=\d)\u00b0(?=\s|$|[.,;:?!])', ' degrees', t)
# Micro prefix (µ followed by unit letter).
_UUNIT = {'m':'meters','L':'liters','l':'liters','g':'grams','s':'seconds',
  'A':'amperes','V':'volts','W':'watts','F':'farads','H':'henrys','S':'siemens',
  'T':'teslas','Pa':'pascals','J':'joules','N':'newtons','K':'kelvins',
  'mol':'moles','Hz':'hertz','Ohm':'ohms','\u03a9':'ohms','M':'molar'}
for _u,_w in sorted(_UUNIT.items(), key=lambda x: -len(x[0])):
    t = t.replace('\u00b5'+_u, 'micro'+_w)
if '\u00b5' in t:
    t = re.sub(r'\u00b5(\w)', r'micro-\1', t)
# SI prefix+unit abbreviations after numbers (TTS mumbles these).
_SI = {'GPa':'gigapascals','MPa':'megapascals','kPa':'kilopascals','hPa':'hectopascals',
  'GHz':'gigahertz','MHz':'megahertz','kHz':'kilohertz',
  'GW':'gigawatts','MW':'megawatts','kW':'kilowatts','mW':'milliwatts',
  'MeV':'megaelectronvolts','keV':'kiloelectronvolts','GeV':'gigaelectronvolts',
  'kV':'kilovolts','mV':'millivolts',
  'mL':'milliliters','dL':'deciliters',
  'nm':'nanometers','mm':'millimeters','cm':'centimeters','km':'kilometers',
  'mg':'milligrams','kg':'kilograms','ng':'nanograms','pg':'picograms',
  'ns':'nanoseconds','ms':'milliseconds','ps':'picoseconds','fs':'femtoseconds',
  'kJ':'kilojoules','MJ':'megajoules',
  'mM':'millimolar','nM':'nanomolar','pM':'picomolar',
  'kDa':'kilodaltons','MDa':'megadaltons',
  'mA':'milliamperes'}
for _u,_w in sorted(_SI.items(), key=lambda x: -len(x[0])):
    t = re.sub(r'(?<=\d)\s*' + _u + r'\b', ' ' + _w, t)
# Ohm: number + Ω (ftfy normalizes U+2126 to Greek omega).
t = re.sub(r'(?<=\d)\s*[\u2126\u03a9](?=\s|$|[.,;:?!)])', ' ohms', t)
# Greek letters via unicodedata (all 24, upper and lower).
_GREEK_FIX = {'lamda':'lambda'}
def _greek(m):
    c = m.group(0)
    n = _ud.name(c, '')
    if 'GREEK' in n and 'LETTER' in n:
        w = n.split()[-1].lower()
        return ' ' + _GREEK_FIX.get(w, w) + ' '
    return c
t = re.sub(r'[\u0391-\u03c9]', _greek, t)
# Roman numerals after labels (Section III -> Section 3).
_R = {r: str(i) for i, r in enumerate(
    ['','I','II','III','IV','V','VI','VII','VIII','IX','X',
     'XI','XII','XIII','XIV','XV','XVI','XVII','XVIII','XIX','XX'], 0) if r}
t = re.sub(
    r'\b(Section|Chapter|Part|Article|Item|Figure|Table|Act|Vol|No)(\s+)((?:X{0,3})(?:IX|IV|V?I{0,3}))\b',
    lambda m: m.group(1)+m.group(2)+_R.get(m.group(3),m.group(3)), t)

# ── Phase 6: Final cleanup ────────────────────────────────────
t = re.sub(r' {2,}', ' ', t)                    # collapse multiple spaces
t = re.sub(r' +([.,;:?!)\]])', r'\1', t)        # space before punctuation
t = re.sub(r'([\(\[]) +', r'\1', t)             # space after opening bracket
t = t.strip()
sys.stdout.write(t)
" 2>/dev/null); then
        printf '%s' "$result"
    else
        # Python unavailable -- bash-only fallback: rejoin hyphenated line-end splits
        printf '%s' "$1" | sed -e '/-$/{' -e 'N' -e 's/-\n//' -e '}'
    fi
}
TEXT=$(normalize_text "$TEXT")

# ── Mute check ────────────────────────────────────────────────────
# When launched from Speak11.app, the mute check is done in-process via
# CoreAudio (microseconds). SPEAK11_MUTE_CHECKED=1 signals this.
# Standalone: speak11-audio CLI (35ms) or osascript fallback (80-500ms).
if [ "${SPEAK11_MUTE_CHECKED:-}" != "1" ]; then
    _AUDIO_TOOL="$SCRIPT_DIR/speak11-audio"
    [ -x "$_AUDIO_TOOL" ] || _AUDIO_TOOL="$HOME/.local/bin/speak11-audio"
    if [ -x "$_AUDIO_TOOL" ]; then
        _is_muted() { "$_AUDIO_TOOL" is-muted; }
        _unmute()   { "$_AUDIO_TOOL" unmute 2>/dev/null; }
    else
        _is_muted() { osascript -e 'output muted of (get volume settings)' 2>/dev/null | grep -q 'true'; }
        _unmute()   { osascript -e 'set volume without output muted' 2>/dev/null; }
    fi
    if _is_muted; then
        mute_result=$(osascript -e 'button returned of (display dialog "Your Mac is muted." with title "Speak11" buttons {"Cancel", "Unmute & Play"} default button "Unmute & Play" with icon caution)' 2>/dev/null) || exit 0
        if [ "$mute_result" = "Unmute & Play" ]; then
            _unmute
        fi
    fi
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

# python3 is used for sentence splitting (local mode uses VENV_PYTHON);
# split_sentences falls back to unsplit text if python3 is missing, so
# this is not fatal — removed the hard exit.

# ── Shared state ─────────────────────────────────────────────────
TMP_FILE=""
TMP_DIR=""
PLAY_PID=""
_CURL_PID=""
_DAEMON_PID=""
_PREV_TMP_FILE=""
_PREV_TMP_DIR=""

# Write our PID so the toggle can kill the entire process (not just afplay).
echo "$$" > "$PID_FILE"

cleanup() {
    set +e  # bash 3.2: trap failures override exit code under set -e
    # Kill all child processes (afplay, curl, python subprocesses)
    [ -n "$_CURL_PID" ] && kill "$_CURL_PID" 2>/dev/null
    # Daemon request/direct fallback runs in a subshell — kill its children
    # (python3) first, then the subshell itself.
    [ -n "$_DAEMON_PID" ] && { pkill -P "$_DAEMON_PID" 2>/dev/null; kill "$_DAEMON_PID" 2>/dev/null; }
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" 2>/dev/null
    pkill -P $$ 2>/dev/null
    rm -f "$TMP_FILE" "$_PREV_TMP_FILE" "${TMP_FILE}.code"
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    [ -n "$_PREV_TMP_DIR" ] && rm -rf "$_PREV_TMP_DIR"
    # Only remove PID file if it's ours (another instance may have overwritten it)
    [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE"
}
# EXIT: clean up on normal exit. INT/TERM: clean up AND exit immediately
# (without `exit`, bash resumes after the trap handler → script keeps running).
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Sentence splitter ────────────────────────────────────────────
# Split text into sentences for streaming playback. Uses whichever
# python is available (VENV_PYTHON for local-only, system python3 otherwise).
split_sentences() {
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
    # Protect common abbreviations: replace their period with a placeholder
    # so the sentence-boundary regex does not split on them.
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
" <<< "$1" 2>/dev/null || printf '0\t%d\t%s\n' "${#1}" "$1"
}

# ── Local TTS helper ────────────────────────────────────────────
# Generates audio using mlx-audio / Kokoro. Sets TMP_FILE on success.
# Returns 0 on success, 1 on failure.
#
# Uses a persistent TTS daemon (tts_server.py) that keeps the model in
# memory for near-instant response.  Falls back to direct invocation if
# the daemon is unavailable.
VENV_PYTHON="${VENV_PYTHON:-$HOME/.local/share/speak11/venv/bin/python3}"

LOG_FILE="$HOME/.local/share/speak11/tts.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
TTS_SOCK="${TTS_SOCK:-$HOME/.local/share/speak11/tts.sock}"

# Start the TTS daemon if not already running.
# The daemon uses flock internally — if another daemon is already running,
# the new process exits immediately (code 0) and we wait for the existing
# daemon's socket instead.
start_tts_daemon() {
    local PY="$1"
    "$PY" "$SCRIPT_DIR/tts_server.py" </dev/null >> "$LOG_FILE" 2>&1 &
    local daemon_pid=$!
    # Wait for socket to appear (model loading can take 5-30s)
    local i=0
    while [ $i -lt 60 ]; do
        [ -S "$TTS_SOCK" ] && return 0
        if ! kill -0 "$daemon_pid" 2>/dev/null; then
            # Our daemon exited.  Two possibilities:
            #  a) Lock conflict — another daemon is running (exit 0).
            #     Its socket may not exist yet (still loading model).
            #  b) Real error (exit non-zero) — no daemon available.
            wait "$daemon_pid" 2>/dev/null
            local daemon_exit=$?
            if [ "$daemon_exit" -eq 0 ]; then
                # Lock conflict: wait for the other daemon's socket.
                while [ $i -lt 60 ]; do
                    [ -S "$TTS_SOCK" ] && return 0
                    sleep 0.5
                    i=$((i + 1))
                done
            fi
            return 1
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1  # timed out
}

# Send a TTS request to the daemon.  Prints audio file path on stdout.
tts_daemon_request() {
    local text_json voice="${_VOICE:-bf_lily}" speed="${_SPEED:-1.00}" lang="${_LANG:-b}"
    text_json=$(json_encode "$TEXT")
    local req="{\"text\":${text_json},\"voice\":\"${voice}\",\"speed\":\"${speed}\",\"lang_code\":\"${lang}\"}"
    # nc -U on macOS silently drops responses from Unix sockets.
    # Use a python one-liner for reliable socket I/O (one fork, same as nc).
    local resp
    resp=$("${VENV_PYTHON:-python3}" -c "
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.settimeout(120)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode()+b'\n')
d=b''
while True:
    c=s.recv(4096)
    if not c:break
    d+=c
    if b'\n' in d:break
s.close()
sys.stdout.write(d.decode().strip())
" "$_SOCK" "$req" 2>/dev/null) || return 1
    # Parse audio_file from JSON response with bash string ops.
    # Python json.dumps adds a space after ":", so strip it.
    local audio_file="${resp#*\"audio_file\":}"
    audio_file="${audio_file# }"
    audio_file="${audio_file#\"}"
    audio_file="${audio_file%%\"*}"
    if [ -n "$audio_file" ] && [ -f "$audio_file" ]; then
        printf '%s' "$audio_file"
    else
        local msg="${resp#*\"message\":}"
        msg="${msg# }"
        msg="${msg#\"}"
        msg="${msg%%\"*}"
        printf '%s\n' "${msg:-daemon error}" >&2
        return 1
    fi
}

run_local_tts() {
    local PY="${VENV_PYTHON}"
    [ -x "$PY" ] || PY=python3  # fallback to system python
    {
        printf "\n[%s] run_local_tts\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        echo "PY=$PY  VOICE=${LOCAL_VOICE:-bf_lily}  SPEED=$LOCAL_SPEED"
    } >> "$LOG_FILE" 2>/dev/null

    # Run a daemon request in background so `wait` is interruptible by SIGTERM
    # (same pattern as curl — bash 3.2 defers signals during foreground $()).
    # Sets caller's `audio_file` on success via dynamic scoping.
    _daemon_request_bg() {
        local _req_out
        _req_out=$(mktemp "${TMPDIR:-/tmp/}speak11_req_XXXXXXXXXX") || return 1
        _SOCK="$TTS_SOCK" _VOICE="${LOCAL_VOICE:-bf_lily}" \
            _SPEED="$LOCAL_SPEED" _LANG="${LOCAL_VOICE:0:1}" \
            tts_daemon_request > "$_req_out" 2>> "$LOG_FILE" &
        _DAEMON_PID=$!
        wait "$_DAEMON_PID" 2>/dev/null
        [ $? -eq 0 ] && audio_file=$(cat "$_req_out" 2>/dev/null)
        _DAEMON_PID=""
        rm -f "$_req_out"
    }

    local audio_file=""

    # Attempt 1: connect to existing daemon
    if [ -S "$TTS_SOCK" ]; then
        _daemon_request_bg
    fi

    # Attempt 2: start daemon and retry
    if [ -z "$audio_file" ] || [ ! -s "$audio_file" ]; then
        if start_tts_daemon "$PY" 2>> "$LOG_FILE"; then
            _daemon_request_bg
        fi
    fi

    # Success via daemon
    if [ -n "$audio_file" ] && [ -s "$audio_file" ]; then
        TMP_FILE="$audio_file"
        TMP_DIR="$(dirname "$audio_file")"
        echo "daemon: $audio_file" >> "$LOG_FILE" 2>/dev/null
        return 0
    fi

    # Fallback: direct invocation (cold start, slow but reliable)
    echo "daemon unavailable, falling back to direct invocation" >> "$LOG_FILE" 2>/dev/null
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp/}speak11_tts_XXXXXXXXXX")
    (cd "$TMP_DIR" && "$PY" -m mlx_audio.tts.generate \
        --model mlx-community/Kokoro-82M-bf16 \
        --text "$TEXT" \
        --voice "${LOCAL_VOICE:-bf_lily}" \
        --speed "$LOCAL_SPEED" \
        --lang_code "${LOCAL_VOICE:0:1}" \
        --file_prefix speak11 \
        --audio_format wav \
        --join_audio 2>> "$LOG_FILE") &
    _DAEMON_PID=$!
    wait "$_DAEMON_PID" 2>/dev/null
    _DAEMON_PID=""
    TMP_FILE="$TMP_DIR/speak11.wav"
    [ -s "$TMP_FILE" ]
}

# ── Play audio helper ──────────────────────────────────────────
# Starts playback in the background. Call wait_audio before the next play_audio.
# This overlap lets the next sentence generate while the current one plays.
play_audio() {
    local duration
    # Use wav_duration for local WAV files (no fork), afinfo for cloud audio
    if [[ "$TMP_FILE" == *.wav ]]; then
        duration=$(wav_duration "$TMP_FILE" 2>/dev/null)
    fi
    [ -z "$duration" ] && duration=$(afinfo "$TMP_FILE" 2>/dev/null | awk '/estimated duration/{print $3}')
    # Epoch from cached base + $SECONDS offset (zero fork per sentence).
    # _BASE_EPOCH (e.g. "1772511783.546") was set once before the pipeline loop.
    local _epoch_int=$(( ${_BASE_EPOCH%%.*} + SECONDS - _BASE_SECONDS ))
    printf '%s.%s\n%s\n%s\n%s\n' "$_epoch_int" "${_BASE_EPOCH#*.}" "${duration:-0}" "${1:-0}" "${2:-0}" > "$STATUS_FILE"
    afplay "$TMP_FILE" &
    PLAY_PID=$!
}

wait_audio() {
    if [ -n "$PLAY_PID" ]; then
        wait "$PLAY_PID" 2>/dev/null || true
        PLAY_PID=""
    fi
}

# ── JSON encoding (pure bash — no fork) ──────────────────────────
json_encode() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

# ── WAV duration from file size (no afinfo/bc fork) ──────────────
# Kokoro outputs 24kHz mono 16-bit WAV: bytes_per_sec = 48000.
wav_duration() {
    local bytes
    bytes=$(stat -f%z "$1" 2>/dev/null) || return 1
    local ms=$(( (bytes - 44) * 1000 / 48000 ))
    printf '%d.%03d' "$((ms / 1000))" "$((ms % 1000))"
}

# ── ElevenLabs single-sentence helper ─────────────────────────────
# Sends one sentence to the ElevenLabs API. Sets TMP_FILE on success.
# Returns 0 on success, 1 on failure. Sets HTTP_CODE and CURL_EXIT.
#
# curl runs in the background so that SIGTERM can interrupt the `wait`
# immediately — bash 3.2 cannot handle signals while a foreground
# command substitution ($()) is running.
run_elevenlabs_tts() {
    local sentence="$1"
    JSON_TEXT=$(json_encode "$sentence")
    if [ -z "$JSON_TEXT" ]; then
        return 1
    fi

    TMP_FILE=$(mktemp "${TMPDIR:-/tmp/}speak11_tts_XXXXXXXXXX")
    [ -z "$TMP_FILE" ] || [ ! -f "$TMP_FILE" ] && return 1

    local code_file="${TMP_FILE}.code"
    curl -s -w "%{http_code}" \
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
        }" > "$code_file" &
    _CURL_PID=$!
    wait "$_CURL_PID" 2>/dev/null
    CURL_EXIT=$?
    _CURL_PID=""
    HTTP_CODE=$(cat "$code_file" 2>/dev/null)
    rm -f "$code_file"
    [ $CURL_EXIT -eq 0 ] && [ "$HTTP_CODE" = "200" ] && [ -s "$TMP_FILE" ]
}

# ── Generate and play audio (sentence by sentence) ───────────────
# Split text into sentences so:
#   - Local: first sentence plays quickly (avoids long phonemization)
#   - Cloud: only played sentences are billed (cancel saves credits)
_SENTENCES=$(split_sentences "$TEXT")

# Cache epoch once so play_audio doesn't fork perl on every sentence.
# play_audio uses: _BASE_EPOCH + (SECONDS - _BASE_SECONDS)
_BASE_EPOCH=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
_BASE_SECONDS=$SECONDS

if [ "$TTS_BACKEND" = "local" ]; then
    # ── Local TTS (mlx-audio / Kokoro) ───────────────────────────
    # Pipeline: generate next sentence while the current one plays,
    # so there is no audible gap between sentences.
    _SAVED_TEXT="$TEXT"
    _FIRST=true
    while IFS=$'\t' read -r _OFFSET _SENT_LEN _SENTENCE; do
        [ -z "$_SENTENCE" ] && continue
        TEXT="$_SENTENCE"
        run_local_tts
        _ok=$?
        if $_FIRST && [ $_ok -ne 0 ]; then
            osascript -e 'display dialog "Local TTS generation failed." & return & return & "Re-run the Speak11 installer to repair the local TTS setup." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
            exit 1
        fi
        if [ $_ok -eq 0 ]; then
            wait_audio
            [ -n "$_PREV_TMP_FILE" ] && rm -f "$_PREV_TMP_FILE"
            [ -n "$_PREV_TMP_DIR" ] && rm -rf "$_PREV_TMP_DIR"
            _FIRST=false
            _PREV_TMP_FILE="$TMP_FILE"
            _PREV_TMP_DIR="$TMP_DIR"
            play_audio "$_OFFSET" "$_SENT_LEN"
        fi
    done <<< "$_SENTENCES"
    wait_audio
    TEXT="$_SAVED_TEXT"
else
    # ── ElevenLabs (cloud API) ───────────────────────────────────
    # Pipeline: generate next sentence while the current one plays.
    _FIRST=true
    while IFS=$'\t' read -r _OFFSET _SENT_LEN _SENTENCE; do
        [ -z "$_SENTENCE" ] && continue
        if ! run_elevenlabs_tts "$_SENTENCE"; then
            break  # first sentence → error handler below; later → exit silently
        fi
        wait_audio
        [ -n "$_PREV_TMP_FILE" ] && rm -f "$_PREV_TMP_FILE"
        _FIRST=false
        _PREV_TMP_FILE="$TMP_FILE"
        play_audio "$_OFFSET" "$_SENT_LEN"
    done <<< "$_SENTENCES"
    wait_audio

    # If the first sentence failed, handle the error (429, network, etc.)
    if $_FIRST; then
        # ── Network failure (offline, DNS, timeout) ──────────────
        if [ $CURL_EXIT -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
            if [ "$TTS_BACKENDS_INSTALLED" = "both" ]; then
                rm -f "$TMP_FILE"; TMP_FILE=""
                if run_local_tts; then
                    play_audio
                    wait_audio
                    exit 0
                fi
                osascript -e 'display dialog "Could not reach ElevenLabs, and local TTS also failed." & return & return & "The Kokoro model may need to download first — try again while online." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
                exit 1
            fi
            osascript -e 'display dialog "Could not reach ElevenLabs." & return & return & "Check your internet connection, or install local TTS for offline use." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
            exit 1
        fi

        # ── HTTP 429 (quota exceeded) ────────────────────────────
        if [ "$HTTP_CODE" = "429" ]; then
            if [ "$TTS_BACKENDS_INSTALLED" = "both" ]; then
                rm -f "$TMP_FILE"; TMP_FILE=""
                if run_local_tts; then
                    play_audio
                    wait_audio
                    exit 0
                fi
                osascript -e 'display dialog "ElevenLabs quota exceeded, and local TTS also failed." & return & return & "Re-run the Speak11 installer to repair the local TTS setup." with title "Speak11" buttons {"OK"} default button "OK" with icon caution'
                exit 1
            fi
            if [ "$(uname -m)" = "arm64" ]; then
                QUOTA_RESULT=$(osascript -e 'button returned of (display dialog "You'\''ve hit your ElevenLabs quota." & return & return & "Install mlx-audio for free local TTS, or upgrade your ElevenLabs plan." with title "Speak11" buttons {"Not Now", "Install Local TTS"} default button "Install Local TTS" with icon caution)' 2>/dev/null || true)
                if [ "$QUOTA_RESULT" = "Install Local TTS" ]; then
                    if bash "$SCRIPT_DIR/install-local.sh" 2>/dev/null; then
                        osascript -e 'display dialog "Local TTS installed and ready." & return & return & "Future requests will fall back to local when ElevenLabs is unavailable." with title "Speak11" buttons {"OK"} default button "OK"' 2>/dev/null
                        rm -f "$TMP_FILE"; TMP_FILE=""
                        if run_local_tts; then
                            play_audio
                            wait_audio
                            exit 0
                        fi
                    else
                        osascript -e 'display dialog "Could not install local TTS." & return & return & "An internet connection is required for the first install.\nPlease check your connection and try again." with title "Speak11" buttons {"OK"} default button "OK" with icon caution' 2>/dev/null
                    fi
                fi
                exit 1
            fi
        fi

        # ── Handle other errors ──────────────────────────────────
        if [ "$HTTP_CODE" != "200" ]; then
            SAFE_ERROR=$(cat "$TMP_FILE" 2>/dev/null \
                | head -c 300 \
                | tr -d '\000-\037"\\')
            osascript -e "display dialog \"ElevenLabs API error (HTTP ${HTTP_CODE}):\" & return & return & \"${SAFE_ERROR:-Unknown error}\" with title \"Speak11\" buttons {\"OK\"} default button \"OK\" with icon caution"
            exit 1
        fi
    fi
fi
