import Cocoa
import ApplicationServices

// MARK: - Config paths

private let configDir  = (NSHomeDirectory() as NSString).appendingPathComponent(".config/speak11")
private let configPath = (configDir as NSString).appendingPathComponent("config")
private let speakPath  = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/speak.sh")

// MARK: - Config model

struct Config {
    // Backend selection
    var ttsBackend:         String = "elevenlabs"   // "elevenlabs" or "local"
    var backendsInstalled:  String = "elevenlabs"   // "elevenlabs", "local", or "both"

    // ElevenLabs settings
    var voiceId:         String = "pFZP5JQG7iQjIQuC4Bku"
    var modelId:         String = "eleven_flash_v2_5"
    var stability:       Double = 0.5
    var similarityBoost: Double = 0.75
    var style:           Double = 0.0
    var useSpeakerBoost: Bool   = true

    // Local TTS settings
    var localVoice:      String = "af_heart"
    var localLang:       String = "a"

    // Shared
    var speed:           Double = 1.0

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
            case "LOCAL_LANG":           c.localLang          = value
            default: break
            }
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
            "LOCAL_LANG=\"\(localLang)\"",
        ]
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)
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
    ("Lily — British, bright", "bf_lily"),
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

private let languageSteps: [(label: String, code: String)] = [
    ("American English", "a"),
    ("British English",  "b"),
    ("Spanish",          "e"),
    ("French",           "f"),
    ("Italian",          "i"),
]

// MARK: - Global hotkey ⌥⇧/ → speak.sh
//
// Keycode 44 = forward slash on ANSI/ISO keyboards (US and most layouts).
// Option+Shift must be set — no Control or Command.

private let kHotkeyCode: Int64 = 44

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

    guard code == kHotkeyCode, flags == [.maskAlternate, .maskShift] else {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Speak11")
        appDelegateRef = self
        installHotkey()
        rebuildMenu()
        if !AXIsProcessTrusted() {
            requestAccessibility()
        }
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
        }
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

        // For short texts or near the end, restart from beginning
        if text.count < 100 || ratio > 0.95 { return text }

        let approxCharPos = Int(Double(text.count) * ratio)

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

        // Backend submenu — only when both backends are installed
        if config.backendsInstalled == "both" {
            menu.addItem(submenuItem("Backend", items: buildBackendItems()))
            menu.addItem(.separator())
        }

        // Voice submenu — different voices per backend
        if config.ttsBackend == "local" {
            menu.addItem(submenuItem("Voice", items: buildLocalVoiceItems()))
        } else {
            menu.addItem(submenuItem("Voice", items: buildVoiceItems()))
        }

        // Speed submenu — different ranges per backend
        let speedSteps = config.ttsBackend == "local" ? localSpeedSteps : elSpeedSteps
        menu.addItem(submenuItem("Speed", items: buildSpeedItems(steps: speedSteps)))

        // Backend-specific settings
        if config.ttsBackend == "local" {
            menu.addItem(submenuItem("Language", items: buildLanguageItems()))
        } else {
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
        }

        // API Key — when ElevenLabs is active or both backends installed
        if config.ttsBackend == "elevenlabs" || config.backendsInstalled == "both" {
            menu.addItem(.separator())
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
                title:          "⚠️  Enable Accessibility for ⌥⇧/",
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
            item("ElevenLabs", #selector(pickBackend(_:)),
                 repr: "elevenlabs", on: config.ttsBackend == "elevenlabs"),
            item("Local (Kokoro)", #selector(pickBackend(_:)),
                 repr: "local", on: config.ttsBackend == "local"),
        ]
    }

    private func buildVoiceItems() -> [NSMenuItem] {
        let isCustom = !knownVoices.contains { $0.id == config.voiceId }
        var items = knownVoices.map { v in
            item(v.name, #selector(pickVoice(_:)), repr: v.id, on: v.id == config.voiceId)
        }
        items.append(.separator())
        let customLabel = isCustom ? "Custom: \(config.voiceId)" : "Custom voice ID…"
        items.append(item(customLabel, #selector(customVoice), repr: "", on: isCustom))
        return items
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

    private func buildSpeedItems(steps: [(label: String, value: Double)]) -> [NSMenuItem] {
        steps.map { s in
            item(s.label, #selector(pickSpeed(_:)),
                 repr: String(s.value), on: abs(s.value - config.speed) < 0.01)
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

    private func buildLanguageItems() -> [NSMenuItem] {
        languageSteps.map { l in
            item(l.label, #selector(pickLanguage(_:)),
                 repr: l.code, on: l.code == config.localLang)
        }
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

    // MARK: Actions

    @objc private func pickBackend(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Guard: prompt for API key when switching to ElevenLabs if none exists
        if id == "elevenlabs" {
            if readAPIKey() == nil {
                if !showAPIKeyDialog(forBackendSwitch: true) {
                    return  // user cancelled — don't switch
                }
            }
        }
        config.ttsBackend = id
        config.save()
        rebuildMenu()
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

    @objc private func customVoice() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Custom Voice ID"
        alert.informativeText = "Enter a voice ID from elevenlabs.io/voice-library"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.stringValue = config.voiceId
        field.placeholderString = "e.g. pFZP5JQG7iQjIQuC4Bku"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let val = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !val.isEmpty else { return }
        config.voiceId = val
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

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        config.localLang = code
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    // MARK: - API Key Management

    @objc private func manageAPIKey() {
        showAPIKeyDialog(forBackendSwitch: false)
    }

    @discardableResult
    private func showAPIKeyDialog(forBackendSwitch: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let existingKey = readAPIKey()

        let alert = NSAlert()
        alert.messageText = forBackendSwitch ? "ElevenLabs API Key Required" : "ElevenLabs API Key"
        alert.informativeText = forBackendSwitch
            ? "Enter your ElevenLabs API key to use the cloud backend."
            : "Enter or update your ElevenLabs API key."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if existingKey != nil && !forBackendSwitch {
            alert.addButton(withTitle: "Remove")
        }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        if let key = existingKey {
            // Mask the key: first 4 + dots + last 4
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
            // Save
            let val = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !val.isEmpty {
                saveAPIKey(val)
                return true
            }
            // Empty field with existing key — keep existing
            return existingKey != nil
        } else if response == .alertThirdButtonReturn {
            // Remove
            deleteAPIKey()
            return false
        }
        // Cancel
        return false
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
