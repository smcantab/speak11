import Cocoa
import ApplicationServices

// MARK: - Config paths

private let configDir  = (NSHomeDirectory() as NSString).appendingPathComponent(".config/speak11")
private let configPath = (configDir as NSString).appendingPathComponent("config")
private let speakPath  = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/speak.sh")

// MARK: - Config model

struct Config {
    var voiceId:         String = "pFZP5JQG7iQjIQuC4Bku"
    var modelId:         String = "eleven_flash_v2_5"
    var stability:       Double = 0.5
    var similarityBoost: Double = 0.75
    var style:           Double = 0.0
    var useSpeakerBoost: Bool   = true
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
            case "VOICE_ID":         c.voiceId         = value
            case "MODEL_ID":         c.modelId         = value
            case "STABILITY":        c.stability        = Double(value) ?? c.stability
            case "SIMILARITY_BOOST": c.similarityBoost  = Double(value) ?? c.similarityBoost
            case "STYLE":            c.style            = Double(value) ?? c.style
            case "USE_SPEAKER_BOOST":c.useSpeakerBoost  = value == "true" || value == "1"
            case "SPEED":            c.speed            = Double(value) ?? c.speed
            default: break
            }
        }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        let lines = [
            "VOICE_ID=\"\(voiceId)\"",
            "MODEL_ID=\"\(modelId)\"",
            "STABILITY=\"\(String(format: "%.2f", stability))\"",
            "SIMILARITY_BOOST=\"\(String(format: "%.2f", similarityBoost))\"",
            "STYLE=\"\(String(format: "%.2f", style))\"",
            "USE_SPEAKER_BOOST=\"\(useSpeakerBoost ? "true" : "false")\"",
            "SPEED=\"\(String(format: "%.2f", speed))\"",
        ]
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Static data

private let knownVoices: [(name: String, id: String)] = [
    ("Lily — British, raspy",     "pFZP5JQG7iQjIQuC4Bku"),
    ("Alice — British, confident","Xb7hH8MSUJpSbSDYk0k2"),
    ("Rachel — calm",             "21m00Tcm4TlvDq8ikWAM"),
    ("Adam — deep",               "pNInz6obpgDQGcFmaJgB"),
    ("Domi — strong",             "AZnzlk1XvdvUeBnXmlld"),
    ("Josh — young, deep",        "TxGEqnHWrfWFTfGW9XjX"),
    ("Sam — raspy",               "yoZ06aMxZJJ28mfd3POQ"),
]

private let knownModels: [(name: String, id: String)] = [
    ("v3 — best quality",         "eleven_v3"),
    ("Flash v2.5 — fastest",      "eleven_flash_v2_5"),
    ("Turbo v2.5 — fast, ½ cost", "eleven_turbo_v2_5"),
    ("Multilingual v2 — 29 langs","eleven_multilingual_v2"),
]

// ElevenLabs API accepts speed in [0.7, 1.2] — values outside that range
// return HTTP 400 "invalid_voice_settings".
private let speedSteps: [(label: String, value: Double)] = [
    ("0.7×", 0.7), ("0.85×", 0.85), ("1×", 1.0), ("1.1×", 1.1), ("1.2×", 1.2),
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

    // Fire speak.sh on a background thread — never block the event tap.
    DispatchQueue.global(qos: .userInitiated).async {
        // Simulate ⌘C directly via CGEvent so the settings app's own
        // Accessibility grant is used — avoids the osascript/System Events
        // path which doesn't inherit AX permission reliably from child processes.
        let src = CGEventSource(stateID: .hidSystemState)
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
        cDown?.flags = .maskCommand
        let cUp   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        cUp?.flags = .maskCommand
        cDown?.post(tap: .cgAnnotatedSessionEventTap)
        cUp?.post(tap: .cgAnnotatedSessionEventTap)
        // Wait for the clipboard to be updated before speak.sh reads it.
        Thread.sleep(forTimeInterval: 0.2)

        DispatchQueue.main.async { appDelegateRef?.setSpeaking(true) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments    = [speakPath]
        task.standardInput = FileHandle.nullDevice
        do    { try task.run(); task.waitUntilExit() }
        catch {}
        DispatchQueue.main.async { appDelegateRef?.setSpeaking(false) }
    }
    return nil  // consume the keystroke
}

// MARK: - App delegate

@objc final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config         = Config.load()
    private var accessTimer: Timer?
    private var animTimer:   Timer?
    private var animPhase:   Double = 0

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

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(submenuItem("Voice", items: buildVoiceItems()))
        menu.addItem(submenuItem("Model", items: buildModelItems()))
        menu.addItem(submenuItem("Speed", items: buildSpeedItems()))
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

    private func buildModelItems() -> [NSMenuItem] {
        knownModels.map { m in
            item(m.name, #selector(pickModel(_:)), repr: m.id, on: m.id == config.modelId)
        }
    }

    private func buildSpeedItems() -> [NSMenuItem] {
        speedSteps.map { s in
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

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.voiceId = id
        config.save()
        rebuildMenu()
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
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.modelId = id
        config.save()
        rebuildMenu()
    }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.speed = val
        config.save()
        rebuildMenu()
    }

    @objc private func pickStability(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.stability = val
        config.save()
        rebuildMenu()
    }

    @objc private func pickSimilarity(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.similarityBoost = val
        config.save()
        rebuildMenu()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.style = val
        config.save()
        rebuildMenu()
    }

    @objc private func toggleSpeakerBoost() {
        config.useSpeakerBoost.toggle()
        config.save()
        rebuildMenu()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
