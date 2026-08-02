// speak11-audio — CoreAudio utilities for Speak11
// Usage: speak11-audio is-muted     → exit 0 if muted, 1 if not
//        speak11-audio unmute       → exit 0 on success, 1 on failure
//        speak11-audio play-queue   → gapless audio queue player (stdin/stdout)
//        speak11-audio detect-lang  → language detection (stdin/stdout)

import AVFoundation
import CoreAudio
import Foundation
import NaturalLanguage

func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
        return nil
    }
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    return (err == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
}

func isMuted() -> Bool {
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

func unmute() -> Bool {
    guard let deviceID = getDefaultOutputDevice() else { return false }
    var muted: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    let err = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted)
    return err == noErr
}

// ── play-queue: gapless audio queue player ───────────────────────
// Reads tab-separated lines from stdin:
//   filepath\tepoch\toffset\tsent_len\tstatus_file\tpause_ms
// Outputs to stdout:
//   duration   (float, immediately after prepareToPlay)
//   DONE       (after playback finishes)
// Writes STATUS_FILE with: epoch\nduration\noffset\nsent_len\n

private struct PlayItem {
    let player: AVAudioPlayer
    let epoch: String
    let offset: String
    let sentLen: String
    let statusFile: String
    let pauseMs: Int
}

class QueuePlayer: NSObject, AVAudioPlayerDelegate {
    private var queue: [PlayItem] = []
    private var current: AVAudioPlayer?  // retain the playing instance
    private var playing = false
    private var stdinOpen = true

    func start() {
        DispatchQueue.global().async { [self] in
            while let line = readLine() {
                let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
                guard parts.count >= 5 else { continue }
                let path = String(parts[0])
                let url = URL(fileURLWithPath: path)
                guard let p = try? AVAudioPlayer(contentsOf: url) else {
                    fputs("ERROR: cannot open \(path)\n", stderr)
                    continue
                }
                p.delegate = self
                p.prepareToPlay()
                let pauseMs = parts.count >= 6 ? (Int(parts[5]) ?? 0) : 0
                let item = PlayItem(
                    player: p,
                    epoch: String(parts[1]),
                    offset: String(parts[2]),
                    sentLen: String(parts[3]),
                    statusFile: String(parts[4]),
                    pauseMs: pauseMs
                )
                DispatchQueue.main.async { [self] in
                    // Print duration immediately so bash can generate the next sentence
                    print(String(format: "%.3f", p.duration))
                    fflush(stdout)
                    self.queue.append(item)
                    if !self.playing { self.playNext() }
                }
            }
            DispatchQueue.main.async { [self] in
                self.stdinOpen = false
                if !self.playing { CFRunLoopStop(CFRunLoopGetMain()) }
            }
        }
    }

    private func playNext() {
        guard !queue.isEmpty else {
            current = nil
            playing = false
            if !stdinOpen { CFRunLoopStop(CFRunLoopGetMain()) }
            return
        }
        playing = true
        let item = queue.removeFirst()
        current = item.player  // retain while playing (delegate is weak)

        let startPlaying = {
            let status = "\(item.epoch)\n\(String(format: "%.3f", item.player.duration))\n\(item.offset)\n\(item.sentLen)\n"
            try? status.write(toFile: item.statusFile, atomically: true, encoding: .utf8)
            item.player.play()
        }

        let delay = Double(item.pauseMs) / 1000.0
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: startPlaying)
        } else {
            startPlaying()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("DONE")
        fflush(stdout)
        playNext()
    }
}

func runPlayQueue() -> Never {
    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }
    let qp = QueuePlayer()
    qp.start()
    CFRunLoopRun()
    exit(0)
}

// ── detect-lang: language detection via NaturalLanguage ──────────
// Reads NUL-separated UTF-8 records on stdin, writes one line per record:
//   <lang>\t<confidence>
// Batched so the whole-document probe and every paragraph probe cost a
// single process spawn (~13ms) rather than one each.
//
// Constrained to the languages the sentence splitter has pySBD rulesets
// tuned for.  Unconstrained, short strings misfire badly ("OK" → Polish).
// Undetectable input (digits, symbols) yields "und" with confidence 0 —
// the caller treats anything below its threshold as "use the document
// language", so no special case is needed downstream.

private let detectLanguages: [NLLanguage] = [.english, .german]

func runDetectLang() -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let records = data.split(separator: UInt8(0), omittingEmptySubsequences: false)
    var out = ""
    for rec in records {
        guard let text = String(data: Data(rec), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            out += "und\t0.000\n"
            continue
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = detectLanguages
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else {
            out += "und\t0.000\n"
            continue
        }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        out += "\(dominant.rawValue)\t\(String(format: "%.3f", confidence))\n"
    }
    FileHandle.standardOutput.write(Data(out.utf8))
    exit(0)
}

// ── Main ─────────────────────────────────────────────────────────

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: speak11-audio <is-muted|unmute|play-queue|detect-lang>\n", stderr)
    exit(2)
}

switch CommandLine.arguments[1] {
case "is-muted":
    exit(isMuted() ? 0 : 1)
case "unmute":
    exit(unmute() ? 0 : 1)
case "play-queue":
    runPlayQueue()
case "detect-lang":
    runDetectLang()
default:
    fputs("Unknown command: \(CommandLine.arguments[1])\n", stderr)
    exit(2)
}
