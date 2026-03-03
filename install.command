#!/bin/bash
# install.command — Speak11 installer for macOS
# Double-click this file in Finder to run.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
SERVICES_DIR="$HOME/Library/Services"
WORKFLOW_NAME="Speak Selection.workflow"

# Guard Terminal.app-specific AppleScript (user may use iTerm2, Warp, etc.)
_IS_TERMINAL_APP=false
[ "$TERM_PROGRAM" = "Apple_Terminal" ] && _IS_TERMINAL_APP=true

# ── Single-instance guard ─────────────────────────────────────────
_LOCKDIR="/tmp/speak11_install.lock"
if ! mkdir "$_LOCKDIR" 2>/dev/null; then
    _holder_pid=$(cat "$_LOCKDIR/pid" 2>/dev/null)
    if [ -n "$_holder_pid" ] && kill -0 "$_holder_pid" 2>/dev/null; then
        osascript -e 'display dialog "The Speak11 installer is already running." with title "Speak11" buttons {"OK"} default button "OK" with icon caution' 2>/dev/null || true
        exit 0
    fi
    # Stale lock — previous installer crashed. Remove and continue.
    rm -rf "$_LOCKDIR"
    mkdir "$_LOCKDIR" 2>/dev/null || exit 1
fi
echo "$$" > "$_LOCKDIR/pid"

# ── Capture Terminal window ID for cleanup ────────────────────────
_TERM_WINDOW_ID=""
if $_IS_TERMINAL_APP; then
    _TERM_WINDOW_ID=$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null || true)
fi

# ── Cleanup ───────────────────────────────────────────────────────
_spinner_pid=""

cleanup() {
    tput cnorm 2>/dev/null || true
    [ -n "$_spinner_pid" ] && kill "$_spinner_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    rmdir "$_LOCKDIR" 2>/dev/null || rm -rf "$_LOCKDIR" 2>/dev/null || true
    if $_IS_TERMINAL_APP && [ -n "$_TERM_WINDOW_ID" ]; then
        osascript -e "tell application \"Terminal\" to close (every window whose id is $_TERM_WINDOW_ID)" 2>/dev/null &
    fi
}
trap cleanup EXIT

# ── Progress helpers ──────────────────────────────────────────────

header() {
    printf '\033[2J\033[H'
    printf '\n'
    printf '  \033[1mSpeak11\033[0m\n'
    printf '  ─────────────────\n\n'
}

step() { printf '  \033[32m✓\033[0m  %s\n' "$1"; }

spin() {
    tput civis 2>/dev/null || true
    (
        trap '' INT
        s='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; i=0
        while true; do
            printf '\r  \033[36m%s\033[0m  %s' "${s:i%10:1}" "$1"
            i=$((i+1)); sleep 0.08
        done
    ) &
    _spinner_pid=$!
}

unspin() {
    [ -n "$_spinner_pid" ] && kill "$_spinner_pid" 2>/dev/null && \
        wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
    printf '\r\033[K'
    tput cnorm 2>/dev/null || true
}

# ── Keep terminal in the background — user interacts via dialogs ──
$_IS_TERMINAL_APP && osascript -e 'tell application "Terminal" to set miniaturized of front window to true' 2>/dev/null || true

# ── Welcome ───────────────────────────────────────────────────────
result=$(osascript -e 'button returned of (display dialog "Welcome to Speak11!\n\nThis installer will:\n  • Copy the speak script into ~/.local/bin\n  • Build a menu bar app that registers ⌥⇧/ as a global hotkey\n  • Optionally install local TTS for free offline use (Apple Silicon)" with title "Speak11" buttons {"Quit", "Continue"} default button "Continue" with icon note)' 2>/dev/null || true)
[ "$result" = "Quit" ] && exit 0

# ── Architecture detection ───────────────────────────────────────
IS_ARM64=false
[ "$(uname -m)" = "arm64" ] && IS_ARM64=true

# ── Backend choice ───────────────────────────────────────────────
BACKEND_CHOICE="ElevenLabs Only"
if $IS_ARM64; then
    BACKEND_CHOICE=$(osascript -e 'button returned of (display dialog "Choose your TTS backend:" & return & return & "• ElevenLabs Only — cloud API" & return & "• Both — ElevenLabs + local fallback" & return & "• Local Only — free, runs on your Mac" with title "Speak11" buttons {"ElevenLabs Only", "Both", "Local Only"} default button "Both" with icon note)' 2>/dev/null || true)
    [ -z "$BACKEND_CHOICE" ] && BACKEND_CHOICE="ElevenLabs Only"
fi

# ── API Key ──────────────────────────────────────────────────────
API_KEY=""
if [ "$BACKEND_CHOICE" = "Local Only" ]; then
    : # no API key needed
elif [ "$BACKEND_CHOICE" = "Both" ]; then
    API_KEY=$(osascript -e 'text returned of (display dialog "Paste your ElevenLabs API key:\n\nThe key needs Text-to-Speech and User Read permissions.\n\nSkip to use local TTS only when ElevenLabs is unavailable." with title "Speak11" default answer "" with hidden answer buttons {"Skip", "Install"} default button "Install")' 2>/dev/null || true)
else
    # ElevenLabs Only (or Intel — same thing)
    API_KEY=$(osascript -e 'text returned of (display dialog "Paste your ElevenLabs API key:\n\nThe key needs Text-to-Speech and User Read permissions." with title "Speak11" default answer "" with hidden answer buttons {"Cancel", "Install"} default button "Install")' 2>/dev/null || true)
    if [ -z "$API_KEY" ]; then
        osascript -e 'display dialog "No API key entered. Installation cancelled." with title "Speak11" buttons {"OK"} default button "OK" with icon caution' 2>/dev/null || true
        exit 1
    fi
fi

# ── Settings app choice (ask before work begins) ─────────────────
settings_result=$(osascript -e 'button returned of (display dialog "Install the Speak11 app?\n\nAdds a waveform icon to your menu bar to change voice, model, and speed without editing any files." with title "Speak11" buttons {"Skip", "Install"} default button "Install" with icon note)' 2>/dev/null || true)

# ── Show terminal with progress ──────────────────────────────────
if $_IS_TERMINAL_APP; then
    osascript -e 'tell application "Terminal"
        set miniaturized of front window to false
        activate
    end tell' 2>/dev/null || true
fi

header

# ── Store key in Keychain ─────────────────────────────────────────
if [ -n "$API_KEY" ]; then
    if security add-generic-password \
        -a "speak11" \
        -s "speak11-api-key" \
        -w "$API_KEY" \
        -U 2>/dev/null; then
        step "API key stored in Keychain"
    else
        printf '  \033[33m⚠\033[0m  Could not store API key in Keychain (will prompt on use)\n'
    fi
fi

# ── Log file ─────────────────────────────────────────────────────
_LOG_DIR="$HOME/.local/share/speak11"
_LOG_FILE="$_LOG_DIR/install.log"
mkdir -p "$_LOG_DIR"
# Append to existing log (preserves previous run errors for debugging).
# Truncate only if over 1 MB to prevent unbounded growth.
if [ -f "$_LOG_FILE" ] && [ "$(stat -f%z "$_LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -500 "$_LOG_FILE" > "$_LOG_FILE.tmp" && mv "$_LOG_FILE.tmp" "$_LOG_FILE"
fi
printf '\n══ Install run: %s ══\n\n' "$(date)" >> "$_LOG_FILE"

# ── Ensure Xcode Command Line Tools match macOS version ──────────
_os_major=$(sw_vers -productVersion | cut -d. -f1)
_clt_major=$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null \
    | awk '/version:/{print $2}' | cut -d. -f1)

if [ -z "$_clt_major" ] || [ "$_clt_major" != "$_os_major" ]; then
    spin "Checking for Command Line Tools update…"
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress 2>/dev/null || true
    _clt_label=$(softwareupdate --list 2>&1 \
        | grep -o 'Label: Command Line Tools[^,]*' | sed 's/Label: //' | head -1)
    unspin

    if [ -n "$_clt_label" ]; then
        spin "Installing $_clt_label (this may take a few minutes)…"
        if osascript -e "do shell script \"softwareupdate --install \\\"$_clt_label\\\"\" with prompt \"Speak11 needs to update Command Line Tools to compile the settings app.\" with administrator privileges" \
            >> "$_LOG_FILE" 2>&1; then
            :
        fi
        unspin
    fi

    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress 2>/dev/null || true

    _clt_major=$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null \
        | awk '/version:/{print $2}' | cut -d. -f1)
    if [ "$_clt_major" = "$_os_major" ]; then
        step "Command Line Tools updated"
    elif [ "${settings_result:-}" = "Install" ]; then
        printf '  \033[33m⚠\033[0m  Command Line Tools could not be updated\n'
        printf '      The settings app may fail to compile.\n'
    fi
fi

# ── Verify swiftc is reachable via xcrun ─────────────────────────
# xcode-select may point to a missing Xcode.app even when CLT is installed.
# Reset to the CLT path if it has swiftc but xcrun can't find it.
if ! xcrun swiftc --version >/dev/null 2>&1; then
    if [ -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]; then
        osascript -e 'do shell script "xcode-select --switch /Library/Developer/CommandLineTools" with prompt "Speak11 needs to configure the Swift compiler." with administrator privileges' 2>>"$_LOG_FILE" || true
    fi
fi

# ── Install mlx-audio (Both or Local Only on Apple Silicon) ──────
if $IS_ARM64 && [ "$BACKEND_CHOICE" != "ElevenLabs Only" ]; then
    spin "Installing mlx-audio and downloading Kokoro model…"
    if bash "$SCRIPT_DIR/install-local.sh" >> "$_LOG_FILE" 2>&1; then
        mlx_ok=0
    else
        mlx_ok=$?
    fi
    unspin
    if [ $mlx_ok -eq 0 ]; then
        step "mlx-audio installed"
    else
        printf '  \033[31m✗\033[0m  mlx-audio installation failed\n'
        _mlx_err=$(grep -iE '(^ERROR|^fatal|exception|failed|not found|no matching)' "$_LOG_FILE" \
            | tail -3 | tr '"\\' "'/" | head -c 500)
        [ -z "$_mlx_err" ] && _mlx_err=$(tail -3 "$_LOG_FILE" 2>/dev/null | tr '"\\' "'/")
        if [ "$BACKEND_CHOICE" = "Local Only" ]; then
            osascript -e "display dialog \"Could not install local TTS.\n\n${_mlx_err:-An internet connection is required for the first install.}\n\nFull log: ~/.local/share/speak11/install.log\" with title \"Speak11\" buttons {\"OK\"} default button \"OK\" with icon stop" 2>/dev/null || true
            exit 1
        else
            osascript -e "display dialog \"Could not install local TTS.\n\n${_mlx_err:-Check your internet connection.}\n\nElevenLabs will be used instead.\nFull log: ~/.local/share/speak11/install.log\" with title \"Speak11\" buttons {\"OK\"} default button \"OK\" with icon caution" 2>/dev/null || true
        fi
    fi
fi

# ── Install speak.sh ──────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cp -f "$SCRIPT_DIR/speak.sh" "$INSTALL_DIR/speak.sh"
cp -f "$SCRIPT_DIR/tts_server.py" "$INSTALL_DIR/tts_server.py"
cp -f "$SCRIPT_DIR/install-local.sh" "$INSTALL_DIR/install-local.sh"
if [ -f "$SCRIPT_DIR/uninstall.command" ]; then
    cp -f "$SCRIPT_DIR/uninstall.command" "$INSTALL_DIR/uninstall.command"
    chmod +x "$INSTALL_DIR/uninstall.command"
fi
chmod +x "$INSTALL_DIR/speak.sh" "$INSTALL_DIR/install-local.sh"
# Compile speak11-audio (fast mute check via CoreAudio, replaces osascript)
if [ -f "$SCRIPT_DIR/speak11-audio.swift" ]; then
    xcrun swiftc "$SCRIPT_DIR/speak11-audio.swift" -o "$INSTALL_DIR/speak11-audio" -O 2>>"$_LOG_FILE" && \
        chmod +x "$INSTALL_DIR/speak11-audio" || true
fi
step "Scripts copied to ~/.local/bin"

# ── Install Automator Quick Action ────────────────────────────────
mkdir -p "$SERVICES_DIR/$WORKFLOW_NAME/Contents"

cat > "$SERVICES_DIR/$WORKFLOW_NAME/Contents/Info.plist" << 'END_INFO'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Speak Selection</string>
</dict>
</plist>
END_INFO

cat > "$SERVICES_DIR/$WORKFLOW_NAME/Contents/document.wflow" << 'END_WFLOW'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AMApplicationBuild</key>
    <string>521.1</string>
    <key>AMApplicationVersion</key>
    <string>2.10</string>
    <key>AMDocumentVersion</key>
    <string>2</string>
    <key>actions</key>
    <array>
        <dict>
            <key>action</key>
            <dict>
                <key>AMAccepts</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Optional</key>
                    <true/>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.string</string>
                    </array>
                </dict>
                <key>AMActionVersion</key>
                <string>2.0.3</string>
                <key>AMApplication</key>
                <array>
                    <string>Automator</string>
                </array>
                <key>AMParameterProperties</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <dict/>
                    <key>CheckedForUserDefaultShell</key>
                    <dict/>
                    <key>inputMethod</key>
                    <dict/>
                    <key>shell</key>
                    <dict/>
                    <key>source</key>
                    <dict/>
                </dict>
                <key>AMProvides</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.string</string>
                    </array>
                </dict>
                <key>ActionBundlePath</key>
                <string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key>
                <string>Run Shell Script</string>
                <key>ActionParameters</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <string>~/.local/bin/speak.sh</string>
                    <key>CheckedForUserDefaultShell</key>
                    <true/>
                    <key>inputMethod</key>
                    <integer>0</integer>
                    <key>shell</key>
                    <string>/bin/bash</string>
                    <key>source</key>
                    <string></string>
                </dict>
                <key>BundleIdentifier</key>
                <string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key>
                <string>2.0.3</string>
                <key>CanShowSelectedItemsWhenRun</key>
                <false/>
                <key>CanShowWhenRun</key>
                <true/>
                <key>Category</key>
                <array>
                    <string>AMCategoryUtilities</string>
                </array>
                <key>Class Name</key>
                <string>RunShellScriptAction</string>
                <key>InputUUID</key>
                <string>60C3B7C0-5F50-4654-B57F-8B4A5BB21BD8</string>
                <key>Keywords</key>
                <array>
                    <string>Shell</string>
                    <string>Script</string>
                    <string>Command</string>
                    <string>Run</string>
                    <string>Unix</string>
                </array>
                <key>OutputUUID</key>
                <string>A0E8DB74-D54F-454E-BA0C-3D9C4F4E2501</string>
                <key>UUID</key>
                <string>86D36B84-D6AC-4D92-B7A4-C18A89D99C32</string>
                <key>UnlocalizedApplications</key>
                <array>
                    <string>Automator</string>
                </array>
                <key>arguments</key>
                <dict>
                    <key>0</key>
                    <dict>
                        <key>default value</key>
                        <integer>0</integer>
                        <key>name</key>
                        <string>inputMethod</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>0</string>
                    </dict>
                    <key>1</key>
                    <dict>
                        <key>default value</key>
                        <string></string>
                        <key>name</key>
                        <string>source</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>1</string>
                    </dict>
                    <key>2</key>
                    <dict>
                        <key>default value</key>
                        <string></string>
                        <key>name</key>
                        <string>COMMAND_STRING</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>2</string>
                    </dict>
                    <key>3</key>
                    <dict>
                        <key>default value</key>
                        <string>/bin/sh</string>
                        <key>name</key>
                        <string>shell</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>3</string>
                    </dict>
                </dict>
                <key>isViewVisible</key>
                <true/>
                <key>location</key>
                <string>309.000000:253.000000</string>
                <key>nibPath</key>
                <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/English.lproj/main.nib</string>
            </dict>
            <key>isViewVisible</key>
            <true/>
        </dict>
    </array>
    <key>connectors</key>
    <dict/>
    <key>workflowMetaData</key>
    <dict>
        <key>applicationBundleIDsByPath</key>
        <dict/>
        <key>applicationPathsByUUID</key>
        <dict/>
        <key>inputTypeIdentifier</key>
        <string>com.apple.Automator.text</string>
        <key>outputTypeIdentifier</key>
        <string>com.apple.Automator.nothing</string>
        <key>presentationMode</key>
        <integer>11</integer>
        <key>processesInput</key>
        <false/>
        <key>serviceInputTypeIdentifier</key>
        <string>com.apple.Automator.text</string>
        <key>serviceOutputTypeIdentifier</key>
        <string>com.apple.Automator.nothing</string>
        <key>serviceProcessesInput</key>
        <false/>
        <key>systemImageName</key>
        <string>NSActionTemplate</string>
        <key>useAutomaticInputType</key>
        <false/>
        <key>workflowTypeIdentifier</key>
        <string>com.apple.Automator.servicesMenu</string>
    </dict>
</dict>
</plist>
END_WFLOW

step "Quick Action created"

# ── Write config (before building the app — avoids first-run race) ─
# install-local.sh may have created a partial config earlier;
# this ensures correct values for the chosen backend.
mkdir -p "$HOME/.config/speak11"
case "$BACKEND_CHOICE" in
    "ElevenLabs Only")
        _CFG_BACKEND="elevenlabs"
        _CFG_INSTALLED="elevenlabs"
        ;;
    "Both")
        _CFG_BACKEND="auto"
        if [ "${mlx_ok:-1}" -eq 0 ]; then
            _CFG_INSTALLED="both"
        else
            _CFG_INSTALLED="elevenlabs"
        fi
        ;;
    "Local Only")
        _CFG_BACKEND="local"
        _CFG_INSTALLED="local"
        ;;
esac

_EXISTING_CONFIG="$HOME/.config/speak11/config"
if [ -f "$_EXISTING_CONFIG" ]; then
    # Re-install: update backend fields, preserve user customizations
    _TMPCONF=$(mktemp)
    while IFS= read -r line; do
        case "$line" in
            TTS_BACKEND=*)           echo "TTS_BACKEND=\"$_CFG_BACKEND\"" ;;
            TTS_BACKENDS_INSTALLED=*) echo "TTS_BACKENDS_INSTALLED=\"$_CFG_INSTALLED\"" ;;
            *)                        echo "$line" ;;
        esac
    done < "$_EXISTING_CONFIG" > "$_TMPCONF"
    mv "$_TMPCONF" "$_EXISTING_CONFIG"
    step "Config updated (existing settings preserved)"
else
    cat > "$_EXISTING_CONFIG" << CFGEOF
TTS_BACKEND="$_CFG_BACKEND"
TTS_BACKENDS_INSTALLED="$_CFG_INSTALLED"
VOICE_ID="pFZP5JQG7iQjIQuC4Bku"
MODEL_ID="eleven_flash_v2_5"
STABILITY="0.5"
SIMILARITY_BOOST="0.75"
STYLE="0.0"
USE_SPEAKER_BOOST="true"
SPEED="1.0"
LOCAL_VOICE="bf_lily"
LOCAL_SPEED="1.0"
CFGEOF
    step "Default config created"
fi

# ── Build and install settings menu bar app ───────────────────────
if [ "$settings_result" = "Install" ]; then
    APP_BUNDLE="$HOME/Applications/Speak11.app"
    APP_BINARY="$APP_BUNDLE/Contents/MacOS/Speak11"

    mkdir -p "$APP_BUNDLE/Contents/MacOS"

    # Compile — use xcrun for proper SDK resolution
    spin "Compiling app…"
    if xcrun swiftc "$SCRIPT_DIR/Speak11.swift" -o "$APP_BINARY" -O 2>>"$_LOG_FILE"; then
        compile_ok=0
    else
        compile_ok=$?
    fi
    unspin

    if [ $compile_ok -ne 0 ]; then
        printf '  \033[31m✗\033[0m  Compilation failed\n'
        printf '\n'
        _swift_err=$(grep -iE '(^error|^fatal|cannot|undefined|no such)' "$_LOG_FILE" \
            | tail -3 | tr '"\\' "'/" | head -c 500)
        [ -z "$_swift_err" ] && _swift_err=$(tail -3 "$_LOG_FILE" 2>/dev/null | tr '"\\' "'/")
        _swift_ver=$(xcrun swiftc --version 2>/dev/null | head -1 || echo "swiftc not found")
        printf '  Swift: %s\n' "$_swift_ver" >> "$_LOG_FILE"
        osascript -e "display dialog \"Could not compile the settings app.\n\n${_swift_err:-Unknown error.}\n\nTry updating Xcode Command Line Tools:\n  sudo rm -rf /Library/Developer/CommandLineTools\n  xcode-select --install\n\nFull log: ~/.local/share/speak11/install.log\" with title \"Speak11\" buttons {\"OK\"} default button \"OK\" with icon caution" 2>/dev/null || true
    else
        step "App compiled"

        # Info.plist
        cat > "$APP_BUNDLE/Contents/Info.plist" << 'END_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Speak11</string>
    <key>CFBundleIdentifier</key>
    <string>com.speak11.app</string>
    <key>CFBundleName</key>
    <string>Speak11</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
END_PLIST

        # Generate app icon
        spin "Generating app icon…"
        mkdir -p "$APP_BUNDLE/Contents/Resources"
        _ICONTMP=$(mktemp -d)
        _ICONSET="$_ICONTMP/AppIcon.iconset"
        mkdir -p "$_ICONSET"
        _ICONSCRIPT=$(mktemp /tmp/genicon_XXXXXX)
        cat > "$_ICONSCRIPT" << 'SWIFT_END'
import AppKit
let dir = CommandLine.arguments[1]
func px(_ n: Int) -> Data? {
    let s = CGFloat(n)
    guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.addPath(CGPath(roundedRect: CGRect(x:0, y:0, width:s, height:s),
        cornerWidth:s*0.22, cornerHeight:s*0.22, transform:nil))
    ctx.setFillColor(CGColor(red:0.15, green:0.47, blue:0.96, alpha:1))
    ctx.fillPath()
    NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx, flipped:false)
    if let sym = NSImage(systemSymbolName:"waveform", accessibilityDescription:nil),
       let img = sym.withSymbolConfiguration(
           NSImage.SymbolConfiguration(pointSize:s*0.48, weight:.medium)) {
        NSColor.white.set()
        img.draw(at:NSPoint(x:(s-img.size.width)/2, y:(s-img.size.height)/2),
            from:.zero, operation:.sourceOver, fraction:1)
    }
    guard let ci = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage:ci).representation(using:.png, properties:[:])
}
for (n,name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),
    (64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),
    (256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    if let d = px(n) { try? d.write(to:URL(fileURLWithPath:"\(dir)/\(name).png")) }
}
SWIFT_END
        if xcrun swift "$_ICONSCRIPT" "$_ICONSET" 2>/dev/null; then
            iconutil -c icns "$_ICONSET" \
                -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
        fi
        rm -f "$_ICONSCRIPT"
        rm -rf "$_ICONTMP"
        unspin
        step "App icon generated"

        # Code sign
        codesign --force --sign - "$APP_BUNDLE" 2>/dev/null || true
        step "App signed"

        printf '\n  \033[32mInstallation complete.\033[0m\n\n'

        # Offer login item (skip if already added from a previous install)
        _has_login_item=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "Speak11" || true)
        if [ "$_has_login_item" -eq 0 ] 2>/dev/null; then
            login_result=$(osascript -e 'button returned of (display dialog "Launch Speak11 automatically at login?" with title "Speak11" buttons {"Not Now", "Yes"} default button "Yes" with icon note)' 2>/dev/null || true)
            if [ "$login_result" = "Yes" ]; then
                osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP_BUNDLE\", hidden:true}" 2>/dev/null || true
            fi
        fi

        open "$APP_BUNDLE" || true
    fi
fi

# ── Done ──────────────────────────────────────────────────────────
if [ "${settings_result:-}" = "Install" ] && [ "${compile_ok:-1}" -eq 0 ]; then
    _DONE_MSG="Speak11 is installed!\n\n⌥⇧/ (Option + Shift + /) speaks your selection anywhere — including Electron apps like Beeper, Slack, and VS Code.\n\nThe ⊶ icon in your menu bar lets you change voice, model, and speed.\n\nFirst use: open the menu bar icon and grant Accessibility access when prompted."
    if [ "${mlx_ok:-1}" -eq 0 ]; then
        _DONE_MSG="$_DONE_MSG\n\nLocal TTS is ready — the Kokoro voice model has been downloaded."
    fi
    osascript -e "display dialog \"$_DONE_MSG\" with title \"Speak11\" buttons {\"Done\"} default button \"Done\" with icon note" 2>/dev/null || true
elif [ "${settings_result:-}" = "Install" ] && [ "${compile_ok:-1}" -ne 0 ]; then
    printf '\n  \033[32mInstallation complete (without settings app).\033[0m\n\n'
    result=$(osascript -e 'button returned of (display dialog "Speak11 is installed, but the menu bar app could not be compiled.\n\nYou can still use Speak11 by assigning a keyboard shortcut:\n\n1. System Settings will open\n2. Go to Keyboard Shortcuts → Services → Text\n3. Find \"Speak Selection\" and assign a shortcut\n\nSuggested: ⌃⌥S (Control+Option+S)\n\nTo get the menu bar app, update Xcode Command Line Tools and re-run the installer." with title "Speak11" buttons {"Done", "Open System Settings"} default button "Open System Settings" with icon caution)' 2>/dev/null || true)
    if [ "${result:-}" = "Open System Settings" ]; then
        open "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"
    fi
else
    printf '\n  \033[32mInstallation complete.\033[0m\n\n'
    result=$(osascript -e 'button returned of (display dialog "Speak11 is installed!\n\nOne last step: assign a keyboard shortcut.\n\n1. System Settings will open\n2. Go to Keyboard Shortcuts → Services → Text\n3. Find \"Speak Selection\" and double-click to assign a shortcut\n\nSuggested: ⌃⌥S (Control+Option+S)" with title "Speak11" buttons {"Done", "Open System Settings"} default button "Open System Settings" with icon note)' 2>/dev/null || true)
    if [ "${result:-}" = "Open System Settings" ]; then
        open "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"
    fi
fi
