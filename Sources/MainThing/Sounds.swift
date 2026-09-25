import AVFoundation
import Foundation
import MainThingCore
import os

/// The cross off sound. "Pen" is the built in scratch, one per text line as the ink draws, with a
/// lighter scratch on undo. A custom sound from `<config>/sounds/` plays once per cross off at
/// stroke start, to its end; a new cross off stops it; undo is silent. Every sound is matched to
/// the pen's loudness at volume 0.25 from its decoded samples. Silent when the system setting
/// "Play user interface sound effects" is off or the choice is Off.
@MainActor
final class Sounds {
    static let volume: Double = 0.25
    private static let key = "sound"

    /// The Sound menu choice, stored by file name. Pen for new installs. A missing file is Pen.
    static var stored: String? { UserDefaults.standard.string(forKey: key) }

    static func store(_ choice: SoundChoice) {
        UserDefaults.standard.set(choice.stored, forKey: key)
    }

    /// System Settings > Sound > "Play user interface sound effects". Off is 0 in the global domain.
    static var systemAllows: Bool {
        if let value = UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int {
            return value != 0
        }
        return true
    }

    private let log = Logger(subsystem: MainThingBundleID, category: "sound")
    let folder: URL
    /// A few players per built in sound, so the lines of one title can overlap their tails.
    private var scratches: [AVAudioPlayer] = []
    private var unscratches: [AVAudioPlayer] = []
    private var next = 0
    /// The pen's loudness: the reference every custom sound is matched to.
    private var penRMS = 0.136
    /// Decoded custom sounds, by file name.
    private var custom: [String: AVAudioPlayer] = [:]
    private var playing: AVAudioPlayer?
    /// Silence on a loop at volume 0: keeps the output device awake while the notch is open, so a
    /// cross off's sound starts at once instead of half a second later. Not always on: an active
    /// output holds a system sleep assertion, so it rests a few seconds after the notch closes.
    private var keepAwake: AVAudioPlayer?
    private var restTask: Task<Void, Never>?
    private var defaultsObserver: (any NSObjectProtocol)?

    init(configDirectory: URL = EventRunner.defaultConfigDirectory) {
        folder = configDirectory.appendingPathComponent("sounds", isDirectory: true)
        scratches = Sounds.load("scratch", count: 3)
        unscratches = Sounds.load("unscratch", count: 2)
        if scratches.isEmpty {
            log.notice("no scratch.wav in the bundle, the pen stays silent")
        } else if let url = Bundle.main.url(forResource: "scratch", withExtension: "wav"), let level = Sounds.measure(url) {
            penRMS = level.rms
        }
        log.notice("custom sounds in \(self.folder.path, privacy: .public): \(self.available().joined(separator: ", "), privacy: .public)")
        prime()
        if let url = Bundle.main.url(forResource: "silence", withExtension: "wav"), let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 0
            player.numberOfLoops = -1
            player.prepareToPlay()
            keepAwake = player
        }
        preload()
        // The choice can change from the menu or from `defaults write`: keep the chosen sound warm.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preload() }
        }
    }

    /// The notch opened: start the silent loop so the output device is awake before any click.
    func wake() {
        restTask?.cancel()
        restTask = nil
        guard let keepAwake, !keepAwake.isPlaying else { return }
        keepAwake.play()
        log.debug("audio awake")
    }

    /// The notch closed: stop the silent loop 3 seconds later, or 3 seconds after the last sound
    /// ends, whichever is later, so the Mac can idle sleep while the notch is closed.
    func rest() {
        restTask?.cancel()
        restTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                let busy = (playing?.isPlaying ?? false)
                    || scratches.contains { $0.isPlaying } || unscratches.contains { $0.isPlaying }
                if !busy {
                    keepAwake?.pause()
                    log.debug("audio at rest")
                    return
                }
            }
        }
    }

    /// Decode, measure and prepare the chosen custom sound now, not at the first cross off.
    private func preload() {
        if case .custom(let file) = choice, custom[file] == nil {
            _ = player(for: file)
        }
    }

    private static func load(_ name: String, count: Int) -> [AVAudioPlayer] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return [] }
        return (0..<count).compactMap { _ in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.volume = Float(volume)
            player.prepareToPlay()
            return player
        }
    }

    /// RMS and peak of a file's decoded samples, linear 0...1. The first 30 seconds at most.
    private static func measure(_ url: URL) -> (rms: Double, peak: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(min(file.length, 44_100 * 30))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
        do { try file.read(into: buffer, frameCount: frames) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        var sum = 0.0, peak = 0.0, count = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for i in 0..<Int(buffer.frameLength) {
                let s = Double(samples[i])
                sum += s * s
                peak = max(peak, abs(s))
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sqrt(sum / Double(count)), peak)
    }

    /// The audio files in the sounds folder, sorted. Read at launch and whenever the menu opens.
    func available() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(SoundChoice.isAudioFile).sorted { $0.lowercased() < $1.lowercased() }
    }

    /// The current choice, with a missing file falling back to Pen.
    var choice: SoundChoice { SoundChoice.resolve(stored: Sounds.stored, available: available()) }

    /// The menu: sets the choice and plays it once as a preview.
    func choose(_ choice: SoundChoice) {
        Sounds.store(choice)
        log.notice("sound choice: \(choice.displayName, privacy: .public)")
        switch choice {
        case .off: stopCustom()
        case .pen: scratch(lines: 1)
        case .custom: playCustom(choice)
        }
    }

    /// Gets the built in players ready on a background queue. Called at launch, never on open.
    func prime() {
        let box = PlayerBox(scratches + unscratches)
        DispatchQueue.global(qos: .userInitiated).async {
            for player in box.players where !player.isPlaying { player.prepareToPlay() }
        }
    }

    /// A cross off starts. Pen: one scratch per line on the pen's timing. Custom: once, to the end.
    func scratch(lines: Int) {
        guard Sounds.systemAllows else { return }
        let choice = self.choice
        switch choice {
        case .off:
            return
        case .custom:
            playCustom(choice)
        case .pen:
            guard !scratches.isEmpty else { return }
            for line in 0..<max(lines, 1) {
                let player = scratches[next % scratches.count]
                next += 1
                let at = player.deviceCurrentTime + Double(line) * PenStroke.secondsPerLine
                player.currentTime = 0
                player.play(atTime: at)
                log.notice("sound Pen line \(line, privacy: .public) at +\(Int(Double(line) * PenStroke.secondsPerLine * 1000), privacy: .public) ms, volume \(player.volume, privacy: .public)")
            }
        }
    }

    /// The undo: the lighter pen scratch. Custom sounds have no undo sound.
    func unscratch() {
        guard Sounds.systemAllows, choice == .pen else { return }
        guard let player = unscratches.first(where: { !$0.isPlaying }) ?? unscratches.first else { return }
        player.currentTime = 0
        player.play()
        log.notice("sound Pen undo")
    }

    private func playCustom(_ choice: SoundChoice) {
        guard case .custom(let file) = choice, let player = player(for: file) else { return }
        stopCustom()
        player.currentTime = 0
        player.play()
        playing = player
        log.notice("sound \(choice.displayName, privacy: .public) (\(file, privacy: .public)) volume \(player.volume, privacy: .public), \(player.duration, format: .fixed(precision: 2), privacy: .public) s")
    }

    private func stopCustom() {
        if let playing, playing.isPlaying { playing.stop() }
        playing = nil
    }

    /// Decoded once per file, its volume set from its loudness against the pen.
    private func player(for file: String) -> AVAudioPlayer? {
        if let cached = custom[file] { return cached }
        let url = folder.appendingPathComponent(file)
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            log.error("could not open \(file, privacy: .public)")
            return nil
        }
        let level = Sounds.measure(url) ?? (rms: penRMS, peak: 1)
        player.volume = SoundLevel.volume(rms: level.rms, peak: level.peak, referenceRMS: penRMS, referenceVolume: Sounds.volume)
        player.prepareToPlay()
        log.notice("loaded \(file, privacy: .public): rms \(20 * log10(max(level.rms, 1e-6)), format: .fixed(precision: 1), privacy: .public) dBFS, peak \(20 * log10(max(level.peak, 1e-6)), format: .fixed(precision: 1), privacy: .public) dBFS, volume \(player.volume, privacy: .public)")
        custom[file] = player
        return player
    }
}

/// Players handed to a background queue for prepareToPlay only.
private final class PlayerBox: @unchecked Sendable {
    let players: [AVAudioPlayer]
    init(_ players: [AVAudioPlayer]) { self.players = players }
}
