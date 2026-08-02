import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio

// MARK: - Editable text field
//
// This app runs as an accessory (LSUIElement) with no main menu, so there is
// no Edit menu to provide the standard ⌘X/⌘C/⌘V/⌘A key equivalents. Without
// them, text fields in our NSAlert dialogs only support paste via right-click.
// Routing the editing actions to the field editor through the responder chain
// restores the expected keyboard shortcuts regardless of activation policy.
final class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "x": if NSApp.sendAction(#selector(NSText.cut(_:)),    to: nil, from: self) { return true }
            case "c": if NSApp.sendAction(#selector(NSText.copy(_:)),   to: nil, from: self) { return true }
            case "v": if NSApp.sendAction(#selector(NSText.paste(_:)),  to: nil, from: self) { return true }
            case "a": if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
            case "z": if NSApp.sendAction(Selector(("undo:")),          to: nil, from: self) { return true }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Config paths

private let configDir  = (NSHomeDirectory() as NSString).appendingPathComponent(".config/speak11")
private let configPath = (configDir as NSString).appendingPathComponent("config")
private let speakPath  = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/speak.sh")
// User-defined ElevenLabs voices live in their own JSON file (not the
// bash-sourced `config`) so arbitrary names never need shell escaping.
private let customVoicesPath = (configDir as NSString).appendingPathComponent("custom_voices.json")

// MARK: - Config model

/// A user-added ElevenLabs voice (a display name + voice ID).
struct CustomVoice: Codable {
    var name: String
    var id: String
}

// MARK: - Hotkey model

/// The global shortcut that triggers speaking, as a raw keycode plus the
/// modifier mask it must be pressed with.
///
/// Stored in the config file as a keycode and a comma-separated modifier list
/// (`HOTKEY_CODE="44"`, `HOTKEY_FLAGS="alt,shift"`) rather than a rendered
/// string like "⌥⇧/", because the character a keycode produces depends on the
/// active keyboard layout — the keycode is the layout-independent identity.
struct Hotkey: Equatable {
    var code:  Int64
    var flags: CGEventFlags

    /// Keycode 44 = forward slash on ANSI/ISO keyboards (US and most layouts).
    static let `default` = Hotkey(code: 44, flags: [.maskAlternate, .maskShift])

    /// The modifiers we recognise, in the order macOS displays them: ⌃⌥⇧⌘.
    static let modifiers: [(mask: CGEventFlags, name: String, symbol: String)] = [
        (.maskControl,   "ctrl",  "\u{2303}"),
        (.maskAlternate, "alt",   "\u{2325}"),
        (.maskShift,     "shift", "\u{21E7}"),
        (.maskCommand,   "cmd",   "\u{2318}"),
    ]

    /// F1–F20. Bindable on their own: they produce no character, so consuming
    /// one can't eat ordinary typing.
    static let functionKeys: Set<Int64> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,  // F1–F12
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,                          // F13–F20
    ]

    /// A shortcut must carry at least one of ⌃⌥⌘, or be a function key.
    /// Shift alone is rejected because the tap consumes what it matches, so
    /// binding "⇧a" would eat every capital A the user types.
    ///
    /// Fn is deliberately not a modifier here: macOS sets the function flag on
    /// every F-key event whether or not Fn is physically held, so "Fn+F18" and
    /// "F18" are indistinguishable. Matching on the keycode alone means the
    /// binding works however the keyboard chooses to deliver the key.
    var isValid: Bool {
        Hotkey.functionKeys.contains(code)
            || !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty
    }

    /// e.g. "⌥⇧/" — for the menu and the Accessibility prompt.
    var display: String {
        Hotkey.modifiers.filter { flags.contains($0.mask) }.map { $0.symbol }.joined()
            + Hotkey.keyLabel(for: code)
    }

    /// e.g. "alt,shift" — for the config file.
    var serializedFlags: String {
        Hotkey.modifiers.filter { flags.contains($0.mask) }.map { $0.name }.joined(separator: ",")
    }

    static func parseFlags(_ raw: String) -> CGEventFlags {
        var result = CGEventFlags()
        for token in raw.lowercased().split(separator: ",") {
            let name = token.trimmingCharacters(in: .whitespaces)
            if let m = modifiers.first(where: { $0.name == name }) { result.insert(m.mask) }
        }
        return result
    }

    // Keys that produce no printable character, so UCKeyTranslate can't name them.
    private static let specialKeys: [Int64: String] = [
        0x24: "\u{21A9}",  0x30: "\u{21E5}",  0x31: "Space",   0x33: "\u{232B}",
        0x35: "\u{238B}",  0x75: "\u{2326}",  0x73: "\u{2196}", 0x77: "\u{2198}",
        0x74: "\u{21DE}",  0x79: "\u{21DF}",  0x7B: "\u{2190}", 0x7C: "\u{2192}",
        0x7D: "\u{2193}",  0x7E: "\u{2191}",
        0x7A: "F1",  0x78: "F2",  0x63: "F3",  0x76: "F4",  0x60: "F5",  0x61: "F6",
        0x62: "F7",  0x64: "F8",  0x65: "F9",  0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
    ]

    /// Renders a keycode using the *current* keyboard layout, so a German
    /// layout shows the character its user actually presses.
    static func keyLabel(for code: Int64) -> String {
        if let special = specialKeys[code] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(code)" }

        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = layoutData.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout,
                UInt16(code),
                UInt16(kUCKeyActionDisplay),
                0,                                   // no modifiers — we want the base character
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// MARK: - Hotkey recorder
//
// A view that captures one key combination. Combos carrying ⌘/⌥/⌃ are grabbed
// in performKeyEquivalent, which runs *before* the alert's buttons get a look
// at them — otherwise ⌘Q would quit the app mid-recording. Plain Return and
// Escape deliberately fall through so they still work the buttons.
final class HotkeyRecorderView: NSView {
    private(set) var hotkey: Hotkey
    private let label = NSTextField(labelWithString: "")

    init(initial: Hotkey) {
        hotkey = initial
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        label.frame = bounds
        label.alignment = .center
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.stringValue = initial.display
        addSubview(label)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Grab ⌘/⌥/⌃ combos here, ahead of the alert's buttons, so ⌘Q doesn't
        // quit the app mid-recording. Everything else falls through, which is
        // what keeps plain Return working Save and Escape working Cancel.
        let flags = cgFlags(from: event)
        guard !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty
        else { return super.performKeyEquivalent(with: event) }
        capture(Hotkey(code: Int64(event.keyCode), flags: flags))
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Modifier-less keys land here — acceptable only if a function key.
        let candidate = Hotkey(code: Int64(event.keyCode), flags: cgFlags(from: event))
        guard candidate.isValid else { NSSound.beep(); return }
        capture(candidate)
    }

    override func flagsChanged(with event: NSEvent) {
        // Live preview: show modifiers as they are held, before the key lands.
        let flags = cgFlags(from: event)
        label.stringValue = flags.isEmpty
            ? hotkey.display
            : Hotkey.modifiers.filter { flags.contains($0.mask) }.map { $0.symbol }.joined()
    }

    private func capture(_ candidate: Hotkey) {
        hotkey = candidate
        label.stringValue = candidate.display
    }

    private func cgFlags(from event: NSEvent) -> CGEventFlags {
        let ns = event.modifierFlags
        var flags = CGEventFlags()
        if ns.contains(.control) { flags.insert(.maskControl)   }
        if ns.contains(.option)  { flags.insert(.maskAlternate) }
        if ns.contains(.shift)   { flags.insert(.maskShift)     }
        if ns.contains(.command) { flags.insert(.maskCommand)   }
        return flags
    }
}

struct Config {
    // Backend selection
    var ttsBackend:         String = "auto"          // "auto", "elevenlabs", or "local"
    var backendsInstalled:  String = "elevenlabs"   // "elevenlabs", "local", or "both"

    // ElevenLabs settings
    var voiceId:         String = "pFZP5JQG7iQjIQuC4Bku"
    var customVoices:    [CustomVoice] = []
    var modelId:         String = "eleven_flash_v2_5"
    var stability:       Double = 0.5
    var similarityBoost: Double = 0.75
    var style:           Double = 0.0
    var useSpeakerBoost: Bool   = true

    // Local TTS settings
    var localVoice:      String = "bf_lily"
    var localSpeed:      Double = 1.0

    // ElevenLabs speed (shared name kept for config compat)
    var speed:           Double = 1.0

    // Inter-sentence pause (milliseconds at 1.0x speed, scales with speed)
    var sentencePause:   Int    = 400

    // Global shortcut that triggers speaking
    var hotkey:          Hotkey = .default

    static func load() -> Config {
        var c = Config()
        guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else { return c }
        for line in raw.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eqRange = line.range(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var value = String(line[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'")  && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "TTS_BACKEND":          c.ttsBackend        = value
            case "TTS_BACKENDS_INSTALLED":c.backendsInstalled = value
            case "VOICE_ID":             c.voiceId            = value
            case "MODEL_ID":             c.modelId            = value
            case "STABILITY":            c.stability          = Double(value) ?? c.stability
            case "SIMILARITY_BOOST":     c.similarityBoost    = Double(value) ?? c.similarityBoost
            case "STYLE":                c.style              = Double(value) ?? c.style
            case "USE_SPEAKER_BOOST":    c.useSpeakerBoost    = value == "true" || value == "1"
            case "SPEED":                c.speed              = Double(value) ?? c.speed
            case "LOCAL_VOICE":          c.localVoice         = value
            case "LOCAL_SPEED":          c.localSpeed         = Double(value) ?? c.localSpeed
            case "SENTENCE_PAUSE":       c.sentencePause      = Int(value) ?? c.sentencePause
            case "HOTKEY_CODE":          c.hotkey.code        = Int64(value) ?? c.hotkey.code
            case "HOTKEY_FLAGS":         c.hotkey.flags       = Hotkey.parseFlags(value)
            default: break
            }
        }
        // A hand-edited config could name no modifiers at all, which would bind
        // a bare key and swallow ordinary typing. Fall back rather than obey.
        if !c.hotkey.isValid { c.hotkey = .default }

        // Custom voices live in a separate JSON file.
        if let data = FileManager.default.contents(atPath: customVoicesPath),
           let voices = try? JSONDecoder().decode([CustomVoice].self, from: data) {
            c.customVoices = voices
        }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        let lines = [
            "TTS_BACKEND=\"\(ttsBackend)\"",
            "TTS_BACKENDS_INSTALLED=\"\(backendsInstalled)\"",
            "VOICE_ID=\"\(voiceId)\"",
            "MODEL_ID=\"\(modelId)\"",
            "STABILITY=\"\(String(format: "%.2f", stability))\"",
            "SIMILARITY_BOOST=\"\(String(format: "%.2f", similarityBoost))\"",
            "STYLE=\"\(String(format: "%.2f", style))\"",
            "USE_SPEAKER_BOOST=\"\(useSpeakerBoost ? "true" : "false")\"",
            "SPEED=\"\(String(format: "%.2f", speed))\"",
            "LOCAL_VOICE=\"\(localVoice)\"",
            "LOCAL_SPEED=\"\(String(format: "%.2f", localSpeed))\"",
            "SENTENCE_PAUSE=\"\(sentencePause)\"",
            "HOTKEY_CODE=\"\(hotkey.code)\"",
            "HOTKEY_FLAGS=\"\(hotkey.serializedFlags)\"",
        ]
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)

        // Persist custom voices to their own JSON file.
        if let data = try? JSONEncoder().encode(customVoices) {
            try? data.write(to: URL(fileURLWithPath: customVoicesPath), options: .atomic)
        }
    }
}

// MARK: - Static data

// ElevenLabs voices
private let knownVoices: [(name: String, id: String)] = [
    ("Lily — British, raspy",     "pFZP5JQG7iQjIQuC4Bku"),
    ("Alice — British, confident","Xb7hH8MSUJpSbSDYk0k2"),
    ("Rachel — calm",             "21m00Tcm4TlvDq8ikWAM"),
    ("Adam — deep",               "pNInz6obpgDQGcFmaJgB"),
    ("Domi — strong",             "AZnzlk1XvdvUeBnXmlld"),
    ("Josh — young, deep",        "TxGEqnHWrfWFTfGW9XjX"),
    ("Sam — raspy",               "yoZ06aMxZJJ28mfd3POQ"),
]

// Kokoro voices (curated English subset)
private let kokoroVoices: [(name: String, id: String)] = [
    ("Lily — British, bright", "bf_lily"),
    ("Heart — warm",           "af_heart"),
    ("Bella — soft",           "af_bella"),
    ("Nova — confident",       "af_nova"),
    ("Sarah — gentle",         "af_sarah"),
    ("Sky — bright",           "af_sky"),
    ("Adam — deep",            "am_adam"),
    ("Echo — clear",           "am_echo"),
    ("Eric — steady",          "am_eric"),
    ("Michael — warm",         "am_michael"),
    ("Emma — British, warm",   "bf_emma"),
    ("George — British, deep", "bm_george"),
]

private let knownModels: [(name: String, id: String)] = [
    ("v3 — best quality",         "eleven_v3"),
    ("Flash v2.5 — fastest",      "eleven_flash_v2_5"),
    ("Turbo v2.5 — fast, ½ cost", "eleven_turbo_v2_5"),
    ("Multilingual v2 — 29 langs","eleven_multilingual_v2"),
]

// ElevenLabs API accepts speed in [0.7, 1.2]
private let elSpeedSteps: [(label: String, value: Double)] = [
    ("0.7×", 0.7), ("0.85×", 0.85), ("1×", 1.0), ("1.1×", 1.1), ("1.2×", 1.2),
]

// Kokoro accepts a wider speed range
private let localSpeedSteps: [(label: String, value: Double)] = [
    ("0.5×", 0.5), ("0.75×", 0.75), ("1×", 1.0), ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0),
]

private let stabilitySteps: [(label: String, value: Double)] = [
    ("0.0 — expressive", 0.0), ("0.25", 0.25), ("0.5 — default", 0.5),
    ("0.75", 0.75), ("1.0 — steady", 1.0),
]

private let similaritySteps: [(label: String, value: Double)] = [
    ("0.0 — low", 0.0), ("0.25", 0.25), ("0.5", 0.5),
    ("0.75 — default", 0.75), ("1.0 — high", 1.0),
]

private let styleSteps: [(label: String, value: Double)] = [
    ("0.0 — none (default)", 0.0), ("0.25", 0.25), ("0.5", 0.5),
    ("0.75", 0.75), ("1.0 — max", 1.0),
]

// MARK: - CoreAudio mute check (in-process, microseconds)

private func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else { return nil }
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    return (err == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
}

func isOutputMuted() -> Bool {
    guard let deviceID = getDefaultOutputDevice() else { return false }
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
    return err == noErr && muted == 1
}

func unmuteOutput() {
    guard let deviceID = getDefaultOutputDevice() else { return }
    var muted: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return }
    AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted)
}

// MARK: - Global hotkey → speak.sh
//
// Defaults to ⌥⇧/ (keycode 44 = forward slash on ANSI/ISO keyboards) but the
// user can rebind it from the menu — mainly to dodge other apps that install
// their own keyboard taps and would otherwise swallow the combo first.
//
// Read and written only on the main thread: the tap's run loop source is
// attached to the main run loop, so the callback runs there too.
private var gHotkey = Hotkey.default

// Module-level tap reference so the C callback can re-enable it after a timeout.
private var globalTap: CFMachPort?
// Weak ref so the C callback can update the menu bar icon.
private weak var appDelegateRef: AppDelegate?

private let hotkeyCallback: CGEventTapCallBack = { _, type, event, _ in
    // If the tap was disabled (e.g. callback was too slow), re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else { return Unmanaged.passRetained(event) }

    let code  = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.intersection([.maskAlternate, .maskShift, .maskControl, .maskCommand])

    guard code == gHotkey.code, flags == gHotkey.flags else {
        return Unmanaged.passRetained(event)
    }

    // Fire on a background thread — never block the event tap.
    DispatchQueue.global(qos: .userInitiated).async {
        appDelegateRef?.handleHotkey()
    }
    return nil  // consume the keystroke
}

// MARK: - App delegate

@objc final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var config         = Config.load()
    private var accessTimer: Timer?
    private var animTimer:   Timer?
    private var animPhase:   Double = 0

    // Respeak state — synchronized via speakLock
    private var speakGeneration = 0
    private var currentSpeakProcess: Process?
    private var isSpeakingFlag = false
    private var respeakTimer: Timer?
    private let speakLock = NSLock()

    // Credits cache (fetched from ElevenLabs API)
    private var cachedCredits: (used: Int, limit: Int, fetchedAt: Date)?

    // TTS daemon process (managed mode — started by this app)
    private var ttsDaemonProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Speak11")
        appDelegateRef = self
        gHotkey = config.hotkey
        installHotkey()
        rebuildMenu()
        if !AXIsProcessTrusted() {
            requestAccessibility()
        }
        updateTTSDaemon()
        fetchCredits()
    }

    func applicationWillTerminate(_ notification: Notification) {
        killCurrentProcess()
        stopTTSDaemon()
    }

    // Re-read config every time the menu opens so we pick up changes from
    // speak.sh (e.g. when the 429 handler installs local TTS and updates the
    // config file).
    func menuWillOpen(_ menu: NSMenu) {
        let fresh = Config.load()
        if fresh.backendsInstalled != config.backendsInstalled ||
           fresh.ttsBackend != config.ttsBackend {
            config = fresh
            rebuildMenu()
            updateTTSDaemon()
        }
        fetchCredits()
    }

    func setSpeaking(_ active: Bool) {
        // Always stop any existing animation first (prevents leaked timers
        // when the hotkey fires while a previous speak.sh is still running).
        animTimer?.invalidate()
        animTimer = nil

        if active {
            animPhase = 0
            statusItem.button?.image = waveformFrame(phase: 0)
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.animPhase += 0.5
                self.statusItem.button?.image = self.waveformFrame(phase: self.animPhase)
            }
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "waveform", accessibilityDescription: "Speak11")
        }
    }

    private func waveformFrame(phase: Double) -> NSImage {
        let w: CGFloat = 18, h: CGFloat = 18
        let barCount   = 5
        let barWidth:  CGFloat = 2
        let gap:       CGFloat = 1.5
        let totalW     = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX     = (w - totalW) / 2

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        for i in 0..<barCount {
            let t = phase + Double(i) * 0.8
            let norm = (sin(t) + 1) / 2          // 0…1
            let minH: CGFloat = 3
            let maxH: CGFloat = 14
            let barH = minH + CGFloat(norm) * (maxH - minH)
            let x = startX + CGFloat(i) * (barWidth + gap)
            let y = (h - barH) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: barH)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    // MARK: - Hotkey

    func handleHotkey() {
        speakLock.lock()
        let speaking = isSpeakingFlag
        speakLock.unlock()

        if speaking {
            stopSpeaking()
        } else {
            // Simulate ⌘C directly via CGEvent so the settings app's own
            // Accessibility grant is used.
            let src = CGEventSource(stateID: .hidSystemState)
            let cDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
            cDown?.flags = .maskCommand
            let cUp   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
            cUp?.flags = .maskCommand
            cDown?.post(tap: .cgAnnotatedSessionEventTap)
            cUp?.post(tap: .cgAnnotatedSessionEventTap)
            // Wait for the clipboard to be updated before speak.sh reads it.
            Thread.sleep(forTimeInterval: 0.2)

            runSpeak()
        }
    }

    private func installHotkey() {
        guard AXIsProcessTrusted() else { return }
        guard globalTap == nil else { return }  // already installed

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap  = CGEvent.tapCreate(
            tap:              .cgSessionEventTap,
            place:            .headInsertEventTap,
            options:          .defaultTap,
            eventsOfInterest: mask,
            callback:         hotkeyCallback,
            userInfo:         nil)
        guard let tap = tap else { return }

        globalTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Poll until Accessibility is granted (e.g. after user clicks Allow).
    private func startAccessibilityPolling() {
        accessTimer?.invalidate()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.installHotkey()
            self?.rebuildMenu()
        }
    }

    @objc private func requestAccessibility() {
        let key  = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        startAccessibilityPolling()
    }

    // MARK: - Speak process management

    func runSpeak(withText text: String? = nil) {
        // In-process mute check via CoreAudio (microseconds, no fork).
        if isOutputMuted() {
            let alert = NSAlert()
            alert.messageText = "Your Mac is muted."
            alert.addButton(withTitle: "Unmute & Play")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                unmuteOutput()
            } else {
                return
            }
        }

        speakLock.lock()
        speakGeneration += 1
        let gen = speakGeneration
        isSpeakingFlag = true
        speakLock.unlock()

        DispatchQueue.main.async { self.setSpeaking(true) }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments    = [speakPath]
            // Force a UTF-8 character type so speak.sh's pbpaste keeps non-ASCII
            // text (ß, umlauts, accents, CJK). GUI-launched apps often have no
            // LANG, which would make pbpaste fall back to ASCII and drop them.
            task.environment  = ProcessInfo.processInfo.environment.merging(
                ["SPEAK11_MUTE_CHECKED": "1", "LC_CTYPE": "UTF-8"]) { _, new in new }

            if let text = text {
                let pipe = Pipe()
                pipe.fileHandleForWriting.write(text.data(using: .utf8) ?? Data())
                pipe.fileHandleForWriting.closeFile()
                task.standardInput = pipe
            } else {
                task.standardInput = FileHandle.nullDevice
            }

            speakLock.lock()
            currentSpeakProcess = task
            speakLock.unlock()

            do { try task.run() } catch {
                speakLock.lock()
                currentSpeakProcess = nil
                if speakGeneration == gen { isSpeakingFlag = false }
                speakLock.unlock()
                DispatchQueue.main.async {
                    self.speakLock.lock()
                    let current = self.speakGeneration
                    self.speakLock.unlock()
                    if current == gen { self.setSpeaking(false) }
                }
                return
            }

            task.waitUntilExit()

            speakLock.lock()
            currentSpeakProcess = nil
            let currentGen = speakGeneration
            if currentGen == gen { isSpeakingFlag = false }
            speakLock.unlock()

            DispatchQueue.main.async {
                if currentGen == gen { self.setSpeaking(false) }
            }
        }
    }

    func killCurrentProcess() {
        speakLock.lock()
        speakGeneration += 1
        let process = currentSpeakProcess
        currentSpeakProcess = nil  // prevent duplicate kill attempts
        speakLock.unlock()

        guard let process = process, process.isRunning else { return }
        let pid = process.processIdentifier

        // Kill child processes first (afplay, curl, python3).
        // bash 3.2 defers SIGTERM while a foreground child is running,
        // so we kill children first to let bash process the signal.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", String(pid)]
        try? pkill.run()
        pkill.waitUntilExit()

        process.terminate()
    }

    // MARK: - TTS daemon lifecycle

    private var needsDaemon: Bool {
        let b = config.ttsBackend
        return (b == "local" || b == "auto") && isLocalInstalled
    }

    private var venvPythonPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/speak11/venv/bin/python3")
    }

    private var ttsServerPath: String {
        ((speakPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("tts_server.py")
    }

    private func startTTSDaemon() {
        guard needsDaemon else { return }
        if let existing = ttsDaemonProcess, existing.isRunning { return }

        let python = venvPythonPath
        let server = ttsServerPath

        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: server) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [server, "--managed"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            ttsDaemonProcess = task
        } catch {
            // Daemon failed to start — speak.sh will fall back to direct invocation
        }
    }

    private func stopTTSDaemon() {
        guard let process = ttsDaemonProcess, process.isRunning else {
            ttsDaemonProcess = nil
            return
        }
        process.terminate()  // sends SIGTERM → daemon cleans up and exits
        ttsDaemonProcess = nil
    }

    private func updateTTSDaemon() {
        if needsDaemon {
            startTTSDaemon()
        } else {
            stopTTSDaemon()
        }
    }

    private func stopSpeaking() {
        killCurrentProcess()
        speakLock.lock()
        isSpeakingFlag = false
        speakLock.unlock()
        DispatchQueue.main.async { self.setSpeaking(false) }
    }

    func calculateRemainingText() -> String? {
        let tmpDir = NSTemporaryDirectory()
        let textPath = (tmpDir as NSString).appendingPathComponent("speak11_text")
        let statusPath = (tmpDir as NSString).appendingPathComponent("speak11_status")

        guard let text = try? String(contentsOfFile: textPath, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }

        guard let statusStr = try? String(contentsOfFile: statusPath, encoding: .utf8) else {
            return text  // no status file (still generating) → restart from beginning
        }

        let lines = statusStr.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              let startTime = TimeInterval(lines[0]),
              let duration = TimeInterval(lines[1]),
              duration > 0 else {
            return text  // invalid status → restart from beginning
        }

        let elapsed = Date().timeIntervalSince1970 - startTime
        let ratio = min(max(elapsed / duration, 0), 1)

        // For short texts, restart from beginning
        if text.count < 100 { return text }

        // Use per-sentence offset from 4-line STATUS_FILE when available
        let approxCharPos: Int
        if lines.count >= 4,
           let charOffset = Int(lines[2]),
           let sentenceLen = Int(lines[3]),
           sentenceLen > 0 {
            approxCharPos = charOffset + Int(Double(sentenceLen) * ratio)
        } else {
            approxCharPos = Int(Double(text.count) * ratio)
        }

        // Near the end of the full text — restart from beginning
        if approxCharPos >= text.count - 50 { return text }

        // Find the nearest sentence boundary at or after approxCharPos
        let searchStart = max(0, approxCharPos - 20)
        let startIdx = text.index(text.startIndex, offsetBy: min(searchStart, text.count))
        let searchStr = String(text[startIdx...])

        // Look for sentence boundaries: .!? followed by whitespace, or newline
        var bestOffset: Int? = nil
        let chars = Array(searchStr.unicodeScalars)
        for i in 0..<chars.count {
            let absPos = searchStart + i
            guard absPos >= approxCharPos else { continue }
            if i > 0 && (chars[i-1] == "." || chars[i-1] == "!" || chars[i-1] == "?") &&
               (chars[i] == " " || chars[i] == "\n" || chars[i] == "\t") {
                bestOffset = absPos
                break
            }
            if chars[i] == "\n" && i + 1 < chars.count {
                bestOffset = absPos + 1
                break
            }
            // Don't search too far — 200 chars max
            if absPos - approxCharPos > 200 {
                bestOffset = approxCharPos
                break
            }
        }

        let resumePos = bestOffset ?? approxCharPos
        guard resumePos < text.count else { return text }
        let resumeIdx = text.index(text.startIndex, offsetBy: resumePos)
        let remaining = String(text[resumeIdx...]).trimmingCharacters(in: .whitespaces)
        return remaining.isEmpty ? text : remaining
    }

    func respeak() {
        let remainingText = calculateRemainingText()
        killCurrentProcess()
        // Brief delay to let the old process clean up
        Thread.sleep(forTimeInterval: 0.05)
        runSpeak(withText: remainingText)
    }

    func scheduleRespeak() {
        speakLock.lock()
        let speaking = isSpeakingFlag
        speakLock.unlock()
        guard speaking else { return }

        DispatchQueue.main.async { [self] in
            respeakTimer?.invalidate()
            respeakTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.respeak()
                }
            }
        }
    }

    // MARK: - Keychain helpers

    private func readAPIKey() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-a", "speak11", "-s", "speak11-api-key", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    private func saveAPIKey(_ key: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["add-generic-password", "-a", "speak11", "-s", "speak11-api-key", "-w", key, "-U"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private func deleteAPIKey() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["delete-generic-password", "-a", "speak11", "-s", "speak11-api-key"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Backend submenu — always visible so users can discover and switch
        menu.addItem(submenuItem("Backend", items: buildBackendItems()))
        menu.addItem(.separator())

        let showEl      = config.ttsBackend == "auto" || config.ttsBackend == "elevenlabs"
        let showLocal   = config.ttsBackend == "local" ||
                          (config.ttsBackend == "auto" && isLocalInstalled)
        let showHeaders = showEl && showLocal

        // ── ElevenLabs section ──
        if showEl {
            if showHeaders { menu.addItem(hintItem("ElevenLabs")) }
            menu.addItem(submenuItem("Voice", items: buildVoiceItems()))
            menu.addItem(submenuItem("Speed", items: buildElSpeedItems()))
            menu.addItem(submenuItem("Model", items: buildModelItems()))
            menu.addItem(submenuItem("Stability", items: buildStabilityItems()))
            menu.addItem(submenuItem("Similarity", items: buildSimilarityItems()))
            menu.addItem(submenuItem("Style", items: buildStyleItems()))
            let boost = NSMenuItem(
                title:  "Speaker Boost",
                action: #selector(toggleSpeakerBoost),
                keyEquivalent: "")
            boost.target = self
            boost.state = config.useSpeakerBoost ? .on : .off
            menu.addItem(boost)
            menu.addItem(.separator())
        }

        // ── Local (Kokoro) section ──
        if showLocal {
            if showHeaders { menu.addItem(hintItem("Local (Kokoro)")) }
            menu.addItem(submenuItem("Voice", items: buildLocalVoiceItems()))
            menu.addItem(submenuItem("Speed", items: buildLocalSpeedItems()))
            menu.addItem(.separator())
        }

        // Sentence Pause — playback-level setting, applies to all backends
        let pauseItem = NSMenuItem(
            title:  "Sentence Pause: \(config.sentencePause) ms",
            action: #selector(editSentencePause),
            keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let shortcutItem = NSMenuItem(
            title:  "Shortcut: \(config.hotkey.display)",
            action: #selector(editHotkey),
            keyEquivalent: "")
        shortcutItem.target = self
        menu.addItem(shortcutItem)
        menu.addItem(.separator())

        // API Key + Credits — when ElevenLabs is active
        if showEl {
            // Credits display (hidden until successfully fetched)
            let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            creditsItem.tag = 999
            creditsItem.isEnabled = false
            creditsItem.isHidden = true
            menu.addItem(creditsItem)

            let apiItem = NSMenuItem(
                title:  "API Key\u{2026}",
                action: #selector(manageAPIKey),
                keyEquivalent: "")
            apiItem.target = self
            menu.addItem(apiItem)
        }

        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(
                title:          "⚠️  Enable Accessibility for \(config.hotkey.display)",
                action:         #selector(requestAccessibility),
                keyEquivalent:  "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: Menu builders

    private func buildBackendItems() -> [NSMenuItem] {
        [
            item("Auto", #selector(pickBackend(_:)),
                 repr: "auto", on: config.ttsBackend == "auto"),
            item("ElevenLabs", #selector(pickBackend(_:)),
                 repr: "elevenlabs", on: config.ttsBackend == "elevenlabs"),
            item("Local (Kokoro)", #selector(pickBackend(_:)),
                 repr: "local", on: config.ttsBackend == "local"),
        ]
    }

    private func buildVoiceItems() -> [NSMenuItem] {
        var items = knownVoices.map { v in
            item(v.name, #selector(pickVoice(_:)), repr: v.id, on: v.id == config.voiceId)
        }

        // User-added custom voices — selectable like presets (reuse pickVoice).
        if !config.customVoices.isEmpty {
            items.append(.separator())
            for v in config.customVoices {
                items.append(item(v.name, #selector(pickVoice(_:)),
                                  repr: v.id, on: v.id == config.voiceId))
            }
        }

        // An active voice that is neither a preset nor a saved custom voice
        // (e.g. set via the ELEVENLABS_VOICE_ID env var or an older config).
        let isKnown = knownVoices.contains       { $0.id == config.voiceId }
        let isSaved = config.customVoices.contains { $0.id == config.voiceId }
        if !isKnown && !isSaved {
            items.append(.separator())
            items.append(item("Custom: \(config.voiceId)", #selector(pickVoice(_:)),
                              repr: config.voiceId, on: true))
        }

        items.append(.separator())
        items.append(item("Add Custom Voice\u{2026}", #selector(addCustomVoice), repr: "", on: false))
        if !config.customVoices.isEmpty {
            items.append(submenuItem("Remove Custom Voice", items: buildRemoveCustomVoiceItems()))
        }
        return items
    }

    private func buildRemoveCustomVoiceItems() -> [NSMenuItem] {
        config.customVoices.map { v in
            item(v.name, #selector(removeCustomVoice(_:)), repr: v.id, on: false)
        }
    }

    private func buildLocalVoiceItems() -> [NSMenuItem] {
        kokoroVoices.map { v in
            item(v.name, #selector(pickLocalVoice(_:)), repr: v.id, on: v.id == config.localVoice)
        }
    }

    private func buildModelItems() -> [NSMenuItem] {
        knownModels.map { m in
            item(m.name, #selector(pickModel(_:)), repr: m.id, on: m.id == config.modelId)
        }
    }

    private func buildElSpeedItems() -> [NSMenuItem] {
        elSpeedSteps.map { s in
            item(s.label, #selector(pickSpeed(_:)),
                 repr: String(s.value), on: abs(s.value - config.speed) < 0.01)
        }
    }

    private func buildLocalSpeedItems() -> [NSMenuItem] {
        localSpeedSteps.map { s in
            item(s.label, #selector(pickLocalSpeed(_:)),
                 repr: String(s.value), on: abs(s.value - config.localSpeed) < 0.01)
        }
    }

    private func buildStabilityItems() -> [NSMenuItem] {
        var items = [hintItem("Lower = expressive · Higher = steady"), .separator()]
        items += stabilitySteps.map { s in
            item(s.label, #selector(pickStability(_:)),
                 repr: String(s.value), on: abs(s.value - config.stability) < 0.01)
        }
        return items
    }

    private func buildSimilarityItems() -> [NSMenuItem] {
        var items = [hintItem("How closely output matches the original voice"), .separator()]
        items += similaritySteps.map { s in
            item(s.label, #selector(pickSimilarity(_:)),
                 repr: String(s.value), on: abs(s.value - config.similarityBoost) < 0.01)
        }
        return items
    }

    private func buildStyleItems() -> [NSMenuItem] {
        var items = [hintItem("Amplifies characteristic delivery · adds latency"), .separator()]
        items += styleSteps.map { s in
            item(s.label, #selector(pickStyle(_:)),
                 repr: String(s.value), on: abs(s.value - config.style) < 0.01)
        }
        return items
    }

    // MARK: Helpers

    private func hintItem(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector,
                      repr: String, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = repr
        i.state = on ? .on : .off
        return i
    }

    private func submenuItem(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        parent.submenu = sub
        return parent
    }

    // MARK: Backend setup helpers

    private var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }.hasPrefix("arm64")
    }

    private var isLocalInstalled: Bool {
        config.backendsInstalled == "local" || config.backendsInstalled == "both"
    }

    private var installLocalPath: String {
        ((speakPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("install-local.sh")
    }

    /// Show "Install Local TTS" dialog. Returns true if user clicked Install.
    private func offerLocalInstall(skipLabel: String = "Cancel") -> Bool {
        guard isAppleSilicon else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Apple Silicon Required"
            a.informativeText = "Local TTS (Kokoro) requires an Apple Silicon Mac (M1 or later)."
            a.alertStyle = .warning
            a.addButton(withTitle: "OK")
            a.runModal()
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Local TTS"
        alert.informativeText = "This will install mlx-audio and download the Kokoro voice model (~350 MB)."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: skipLabel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Run install-local.sh in background. On success, reload config, set
    /// desiredBackend (because install-local.sh forces TTS_BACKEND="local"),
    /// and rebuild the menu.
    private func runInstallLocal(desiredBackend: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [installLocalPath]
            task.standardOutput = FileHandle.nullDevice
            task.standardError  = FileHandle.nullDevice
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(false) }
                return
            }
            task.waitUntilExit()
            let success = task.terminationStatus == 0
            DispatchQueue.main.async { [self] in
                if success {
                    config = Config.load()
                    config.ttsBackend = desiredBackend
                    config.save()
                    rebuildMenu()
                }
                completion(success)
            }
        }
    }

    private func showInstallResult(success: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if success {
            a.messageText = "Local TTS Installed"
            a.informativeText = "mlx-audio and the Kokoro model are ready."
        } else {
            a.messageText = "Installation Failed"
            a.informativeText = "Could not install local TTS.\n\nAn internet connection is required for the first install.\nPlease check your connection and try again."
            a.alertStyle = .warning
        }
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: Actions

    @objc private func pickBackend(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }

        if id == "elevenlabs" {
            // ElevenLabs requires an API key
            if readAPIKey() == nil {
                if !showAPIKeyDialog(forBackendSwitch: true) { return }
            }
        } else if id == "local" {
            // Local requires mlx-audio installed
            if !isLocalInstalled {
                if !offerLocalInstall(skipLabel: "Cancel") { return }
                // User accepted — install in background, switch now
                config.ttsBackend = id
                config.save()
                rebuildMenu()
                scheduleRespeak()
                runInstallLocal(desiredBackend: id) { [weak self] ok in
                    self?.showInstallResult(success: ok)
                    self?.updateTTSDaemon()
                }
                return
            }
        } else {
            // auto — ensure at least one backend is available
            let hasKey   = readAPIKey() != nil
            let hasLocal = isLocalInstalled

            if !hasKey && !hasLocal {
                // Neither ready — need at least one
                if !showAPIKeyDialog(forBackendSwitch: true) {
                    // Skipped API key — try local install
                    if offerLocalInstall(skipLabel: "Cancel") {
                        config.ttsBackend = id
                        config.save()
                        rebuildMenu()
                        runInstallLocal(desiredBackend: id) { [weak self] ok in
                            self?.showInstallResult(success: ok)
                            self?.updateTTSDaemon()
                        }
                        return
                    }
                    return  // both skipped — don't switch
                }
            } else if !hasKey {
                // Has local, missing API key — soft prompt (Skip is fine)
                showAPIKeyDialog(forBackendSwitch: true, optional: true)
            } else if !hasLocal {
                // Has API key, missing local — offer install (Not Now is fine)
                if offerLocalInstall(skipLabel: "Not Now") {
                    config.ttsBackend = id
                    config.save()
                    rebuildMenu()
                    scheduleRespeak()
                    runInstallLocal(desiredBackend: id) { [weak self] ok in
                        self?.showInstallResult(success: ok)
                        self?.updateTTSDaemon()
                    }
                    return
                }
                // User chose "Not Now" — auto degrades to ElevenLabs-only
            }
        }

        config.ttsBackend = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
        updateTTSDaemon()
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.voiceId = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickLocalVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.localVoice = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func addCustomVoice() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Custom Voice"
        alert.informativeText = "Enter a name and a voice ID from elevenlabs.io/voice-library."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        // Two stacked fields (name on top, ID below). EditableTextField so ⌘V works.
        let nameField = EditableTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 22))
        nameField.placeholderString = "Name (e.g. Antoni)"
        let idField = EditableTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        idField.placeholderString = "Voice ID (e.g. pFZP5JQG7iQjIQuC4Bku)"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        container.addSubview(nameField)
        container.addSubview(idField)
        nameField.nextKeyView = idField
        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = idField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = id }

        // Update the name if this ID already exists, otherwise append.
        if let idx = config.customVoices.firstIndex(where: { $0.id == id }) {
            config.customVoices[idx].name = name
        } else {
            config.customVoices.append(CustomVoice(name: name, id: id))
        }
        config.voiceId = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func removeCustomVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.customVoices.removeAll { $0.id == id }
        // If the removed voice was active, fall back to the default preset.
        if config.voiceId == id {
            config.voiceId = knownVoices.first?.id ?? "pFZP5JQG7iQjIQuC4Bku"
        }
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.modelId = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.speed = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickLocalSpeed(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.localSpeed = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func editSentencePause() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sentence Pause"
        alert.informativeText = "Milliseconds of silence between sentences (at 1\u{00D7} speed). Set to 0 for no pause."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = EditableTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        field.stringValue = String(config.sentencePause)
        field.placeholderString = "e.g. 400"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let val = Int(text), val >= 0 else { return }
        config.sentencePause = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func editHotkey() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)

        // Suspend our own tap while recording, or pressing the current shortcut
        // to re-record it would be consumed and start speaking instead.
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: false) }
        defer { if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) } }

        let alert = NSAlert()
        alert.messageText = "Set Shortcut"
        alert.informativeText = "Press the key combination you want to use \u{2014} "
            + "either a function key (F1\u{2013}F20) on its own, or any key with "
            + "\u{2318}, \u{2325} or \u{2303}."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let recorder = HotkeyRecorderView(initial: config.hotkey)
        alert.accessoryView = recorder
        alert.window.initialFirstResponder = recorder

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let picked = recorder.hotkey
        guard picked.isValid, picked != config.hotkey else { return }

        config.hotkey = picked
        config.save()
        gHotkey = picked
        rebuildMenu()
    }

    @objc private func pickStability(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.stability = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickSimilarity(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.similarityBoost = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.style = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func toggleSpeakerBoost() {
        config.useSpeakerBoost.toggle()
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    // MARK: - Credits Display

    private func fetchCredits() {
        guard config.ttsBackend == "auto" || config.ttsBackend == "elevenlabs" else { return }
        guard let key = readAPIKey(), !key.isEmpty else { return }

        // Use cache if fresh (< 60s old)
        if let cached = cachedCredits, Date().timeIntervalSince(cached.fetchedAt) < 60 {
            updateCreditsMenuItem(used: cached.used, limit: cached.limit)
            return
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/user/subscription") else { return }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let used = json["character_count"] as? Int,
                  let limit = json["character_limit"] as? Int else { return }

            self?.cachedCredits = (used: used, limit: limit, fetchedAt: Date())

            DispatchQueue.main.async {
                self?.updateCreditsMenuItem(used: used, limit: limit)
            }
        }.resume()
    }

    private func updateCreditsMenuItem(used: Int, limit: Int) {
        guard let menu = statusItem.menu,
              let creditsItem = menu.item(withTag: 999) else { return }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let remaining = max(limit - used, 0)
        let rStr = fmt.string(from: NSNumber(value: remaining)) ?? "\(remaining)"
        let lStr = fmt.string(from: NSNumber(value: limit)) ?? "\(limit)"
        creditsItem.title = "Credits: \(rStr) / \(lStr)"
        creditsItem.isHidden = false
    }

    // MARK: - API Key Management

    @objc private func manageAPIKey() {
        showAPIKeyDialog(forBackendSwitch: false)
    }

    /// Validate an API key by calling /v1/user/subscription.
    /// Returns nil on success, or an error message on failure.
    private func validateAPIKey(_ key: String) -> String? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user/subscription") else {
            return "Could not build request URL."
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        var result: String? = "Could not reach ElevenLabs. Check your internet connection."
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if error != nil {
                result = "Could not reach ElevenLabs. Check your internet connection."
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = "Unexpected response from ElevenLabs."
                return
            }
            switch http.statusCode {
            case 200:
                result = nil
            case 401:
                result = "Invalid API key. Check that you copied the full key."
            case 403:
                result = "This key is missing required permissions.\nEnable Text-to-Speech and User Read at elevenlabs.io."
            default:
                result = "ElevenLabs returned HTTP \(http.statusCode). Try again later."
            }
        }.resume()
        sem.wait()
        return result
    }

    @discardableResult
    private func showAPIKeyDialog(forBackendSwitch: Bool, optional: Bool = false) -> Bool {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let existingKey = readAPIKey()

        let skipTitle = optional ? "Skip" : "Cancel"
        let baseMessage: String
        let baseInfo: String
        if optional {
            baseMessage = "Add ElevenLabs API Key"
            baseInfo = "Add your API key for cloud TTS.\nThe key needs Text-to-Speech and User Read permissions.\n\nWithout a key, Auto mode will use local TTS only."
        } else if forBackendSwitch {
            baseMessage = "ElevenLabs API Key Required"
            baseInfo = "Enter your ElevenLabs API key to use the cloud backend.\nThe key needs Text-to-Speech and User Read permissions."
        } else {
            baseMessage = "ElevenLabs API Key"
            baseInfo = "Enter or update your ElevenLabs API key.\nThe key needs Text-to-Speech and User Read permissions."
        }

        var errorMessage: String? = nil

        while true {
            let alert = NSAlert()
            alert.messageText = baseMessage
            if let err = errorMessage {
                alert.informativeText = err + "\n\n" + baseInfo
                alert.icon = NSImage(named: NSImage.cautionName)
            } else {
                alert.informativeText = baseInfo
            }
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: skipTitle)
            if !forBackendSwitch && !optional && existingKey != nil && errorMessage == nil {
                alert.addButton(withTitle: "Remove")
            }

            let field = EditableTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
            if errorMessage == nil, let key = existingKey {
                if key.count > 8 {
                    let start = key.prefix(4)
                    let end = key.suffix(4)
                    field.placeholderString = "\(start)\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(end)"
                } else {
                    field.placeholderString = "Current key set"
                }
            } else {
                field.placeholderString = "Paste your API key here"
            }
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                let val = field.stringValue.trimmingCharacters(in: .whitespaces)
                if val.isEmpty {
                    if existingKey != nil { return true }
                    errorMessage = "No key entered."
                    continue
                }
                if let err = validateAPIKey(val) {
                    errorMessage = err
                    continue
                }
                saveAPIKey(val)
                return true
            } else if response == .alertThirdButtonReturn {
                deleteAPIKey()
                return false
            }
            return false
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
