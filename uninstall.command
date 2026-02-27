#!/bin/bash
# uninstall.command — Speak11 uninstaller for macOS
# Double-click this file in Finder to run.

set -e

# ── Cleanup ───────────────────────────────────────────────────────
cleanup() {
    osascript -e 'tell application "Terminal" to close front window' 2>/dev/null &
}
trap cleanup EXIT

# ── Keep terminal in the background — user interacts via dialogs ──
osascript -e 'tell application "Terminal" to set miniaturized of front window to true' 2>/dev/null || true

result=$(osascript -e 'button returned of (display dialog "This will completely remove Speak11:\n\n  • Stop and remove the menu bar app\n  • Remove Accessibility permission\n  • Remove the speak script\n  • Remove the Services workflow\n  • Remove settings and config\n  • Remove the local TTS environment\n  • Remove the API key from Keychain\n  • Remove the login item (if set)" with title "Speak11" buttons {"Cancel", "Uninstall"} default button "Cancel" with icon caution)' 2>/dev/null)
[ "$result" = "Uninstall" ] || exit 0

# ── Show terminal with progress ──────────────────────────────────
osascript -e 'tell application "Terminal"
    set miniaturized of front window to false
    activate
end tell' 2>/dev/null || true

printf '\033[2J\033[H'
printf '\n'
printf '  \033[1mSpeak11\033[0m — Uninstalling\n'
printf '  ───────────────────────\n\n'

step() { printf '  \033[32m✓\033[0m  %s\n' "$1"; }

# ── Quit the menu bar app ─────────────────────────────────────────
pkill -x "Speak11" 2>/dev/null || true
pkill -x "Speak11Settings" 2>/dev/null || true  # legacy binary name
sleep 0.5
step "Menu bar app stopped"

# ── Remove Accessibility permission ───────────────────────────────
tccutil reset Accessibility com.speak11.app 2>/dev/null || true
tccutil reset Accessibility com.speak11.settings 2>/dev/null || true  # legacy bundle ID
step "Accessibility permission removed"

# ── Remove the app bundle ─────────────────────────────────────────
rm -rf "$HOME/Applications/Speak11.app"
rm -rf "$HOME/Applications/Speak11 Settings.app"  # legacy name
step "App bundle removed"

# ── Remove script symlinks ───────────────────────────────────────
rm -f "$HOME/.local/bin/speak.sh"
rm -f "$HOME/.local/bin/tts_server.py"
step "Script symlinks removed"

# ── Remove the Services workflow ──────────────────────────────────
rm -rf "$HOME/Library/Services/Speak Selection.workflow"
step "Quick Action removed"

# ── Remove config directory ───────────────────────────────────────
rm -rf "$HOME/.config/speak11"
step "Config removed"

# ── Kill TTS daemon if running ───────────────────────────────────
if [ -f "$HOME/.local/share/speak11/tts_server.pid" ]; then
    _daemon_pid=$(cat "$HOME/.local/share/speak11/tts_server.pid" 2>/dev/null)
    if [ -n "$_daemon_pid" ] && kill -0 "$_daemon_pid" 2>/dev/null; then
        if ps -p "$_daemon_pid" -o args= 2>/dev/null | grep -q tts_server; then
            kill "$_daemon_pid" 2>/dev/null || true
        fi
    fi
fi

# ── Remove local TTS data (venv, daemon, standalone Python) ────
rm -rf "$HOME/.local/share/speak11"
step "Local TTS data removed"

# ── Remove API key from Keychain ──────────────────────────────────
security delete-generic-password \
    -a "speak11" \
    -s "speak11-api-key" 2>/dev/null || true
step "API key removed from Keychain"

# ── Remove login item ────────────────────────────────────────────
osascript -e 'tell application "System Events" to delete (every login item whose name is "Speak11")' 2>/dev/null || true
osascript -e 'tell application "System Events" to delete (every login item whose name is "Speak11 Settings")' 2>/dev/null || true
step "Login item removed"

printf '\n  \033[32mSpeak11 has been removed.\033[0m\n\n'

# ── Done ──────────────────────────────────────────────────────────
osascript -e 'display dialog "Speak11 has been removed.\n\nIf you assigned a Services keyboard shortcut, remove it manually:\nSystem Settings → Keyboard → Keyboard Shortcuts → Services" with title "Speak11" buttons {"Done"} default button "Done" with icon note' 2>/dev/null
