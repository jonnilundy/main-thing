import AVFoundation
import Foundation
import MainThingCore
import os

/// The cross off sound and the link sound. "Pen" is the built in scratch, one per text line as the
/// ink draws, with a lighter scratch on undo. A Cuelume cue from the bundle or a custom sound from
/// `<config>/sounds/` plays once per cross off at stroke start, to its end; a new cross off stops
/// it; undo is silent. The link sound, a cue or none, plays when a pasted link turns into its
/// title. The reminder sound, a cue or none (the default), plays with each reminder nudge. Every sound is matched to the pen's loudness at volume 0.25 from its decoded samples.
/// Silent when the system setting "Play user interface sound effects" is off or the choice is Off.
@MainActor
final class Sounds {
    static let volume: Double = 0.25
    static let key = SoundChoice.key

    /// The Sound menu choice. Nothing stored, or a missing file, is the default cue.
    static var stored: String? { UserDefaults.standard.string(forKey: key) }

    static func store(_ choice: SoundChoice) {
        UserDefaults.standard.set(choice.stored, forKey: key)
    }

    /// The Link sound menu choice. Nothing stored is the default cue.
    static var linkCue: Cue? { LinkSound.resolve(stored: UserDefaults.standard.string(forKey: LinkSound.key)) }

    static func storeLink(_ cue: Cue?) {
        UserDefaults.standard.set(LinkSound.stored(cue), forKey: LinkSound.key)
    }

    /// The Reminder sound choice. Nothing stored is None.
    static var reminderCue: Cue? { ReminderSound.resolve(stored: UserDefaults.standard.string(forKey: ReminderSound.key)) }

    static func storeReminder(_ cue: Cue?) {
        UserDefaults.standard.set(ReminderSound.stored(cue), forKey: ReminderSound.key)
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
    /// Plays nothing: the bench and the card probe cross tasks off without a sound.
    var muted = false
    /// A few players per built in sound, so the lines of one title can overlap their tails.
    private var scratches: [AVAudioPlayer] = []
    private var unscratches: [AVAudioPlayer] = []
    private var next = 0
    /// The pen's loudness: the reference every custom sound is matched to.
    private var penRMS = 0.136
    /// Decoded custom sounds, by file name.
    private var custom: [String: AVAudioPlayer] = [:]
    /// Decoded Cuelume cues from the bundle.
    private var cues: [Cue: AVAudioPlayer] = [:]
    private var playing: AVAudioPlayer?
    /// Silence on a loop at volume 0: keeps the output device awake while the notch is open, so a
    /// cross off's sound starts at once instead of half a second later. Not always on: an active
    /// output holds a system sleep assertion, so it rests a few seconds after the notch closes.
    private var keepAwake: AVAudioPlayer?
    /// Starting the silent loop blocks the calling thread for about half a second once the output
    /// has been idle for a while (460ms measured after 2 minutes, 2ms when warm), so it starts and
    /// stops on this queue, never on the main thread: the notch opens without waiting for audio.
    private let audioQueue = DispatchQueue(label: "com.jonnilundy.mainthing.audio", qos: .userInitiated)
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
        guard let keepAwake else { return }
        let box = PlayerBox([keepAwake])
        let log = self.log
        audioQueue.async {
            guard let player = box.players.first, !player.isPlaying else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            player.play()
            let ms = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            log.debug("audio awake in \(ms, privacy: .public) ms")
        }
    }

    /// The notch closed: stop the silent loop 3 seconds later, or 3 seconds after the last sound
    /// ends, whichever is later, so the Mac can idle sleep while the notch is closed.
    func rest() {
        restTask?.cancel()
        restTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                let busy = (playing?.isPlaying ?? false) || cues.values.contains { $0.isPlaying }
                    || scratches.contains { $0.isPlaying } || unscratches.contains { $0.isPlaying }
                if !busy {
                    if let keepAwake {
                        let box = PlayerBox([keepAwake])
                        audioQueue.async { box.players.first?.pause() }
                    }
                    log.debug("audio at rest")
                    return
                }
            }
        }
    }

    /// Decode, measure and prepare the chosen sounds now, not at the first cross off or link.
    private func preload() {
        switch choice {
        case .custom(let file) where custom[file] == nil: _ = player(for: file)
        case .cue(let cue) where cues[cue] == nil: _ = player(for: cue)
        default: break
        }
        if let cue = Sounds.linkCue, cues[cue] == nil { _ = player(for: cue) }
        if let cue = Sounds.reminderCue, cues[cue] == nil { _ = player(for: cue) }
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
        case .cue, .custom: playCustom(choice)
        }
    }

    /// One option once, stopping the one before, storing nothing: the pointer moving through a
    /// sound menu in Settings, or its play button.
    func preview(_ choice: SoundChoice) {
        switch choice {
        case .off: stopCustom()
        case .pen: stopCustom(); scratch(lines: 1)
        case .cue, .custom: playCustom(choice)
        }
    }

    /// A link sound option once, stopping the one before, storing nothing.
    func preview(link cue: Cue?) {
        stopCustom()
        guard let cue, let player = player(for: cue) else { return }
        start(player, label: "link \(cue.displayName)")
        playing = player
    }

    /// A reminder sound option once, stopping the one before, storing nothing.
    func preview(reminder cue: Cue?) {
        stopCustom()
        guard let cue, let player = player(for: cue) else { return }
        start(player, label: "reminder \(cue.displayName)")
        playing = player
    }

    func previewDone() { preview(choice) }
    func previewLink() { preview(link: Sounds.linkCue) }
    func previewReminder() { preview(reminder: Sounds.reminderCue) }

    /// A reminder nudge: the reminder sound, once. The notch is collapsed, so the output may be
    /// asleep, and starting it then blocks for about half a second: it starts on the audio queue,
    /// never on the main thread, so the hop does not wait for it.
    func reminderNudge() {
        guard Sounds.systemAllows, !muted, let cue = Sounds.reminderCue, let player = player(for: cue) else { return }
        player.currentTime = 0
        let box = PlayerBox([player])
        let log = self.log
        audioQueue.async {
            let started = box.players.first?.play() ?? false
            log.notice("sound reminder \(cue.displayName, privacy: .public) started \(started, privacy: .public)")
        }
    }

    /// The Link sound menu: sets the choice and plays it once as a preview.
    func chooseLink(_ cue: Cue?) {
        Sounds.storeLink(cue)
        log.notice("link sound choice: \(LinkSound.displayName(cue), privacy: .public)")
        if let cue, let player = player(for: cue) { start(player, label: "link \(cue.displayName)") }
    }

    /// A pasted link turned into its title: the link sound, once.
    func linkResolved() {
        guard Sounds.systemAllows, !muted, let cue = Sounds.linkCue, let player = player(for: cue) else { return }
        start(player, label: "link \(cue.displayName)")
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
        guard Sounds.systemAllows, !muted else { return }
        let choice = self.choice
        switch choice {
        case .off:
            return
        case .cue, .custom:
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

    /// The undo: the lighter pen scratch. Cues and custom sounds have no undo sound.
    func unscratch() {
        guard Sounds.systemAllows, !muted, choice == .pen else { return }
        guard let player = unscratches.first(where: { !$0.isPlaying }) ?? unscratches.first else { return }
        player.currentTime = 0
        player.play()
        log.notice("sound Pen undo")
    }

    /// A cue or a custom file, once, stopping the one before.
    private func playCustom(_ choice: SoundChoice) {
        let player: AVAudioPlayer?
        switch choice {
        case .cue(let cue): player = self.player(for: cue)
        case .custom(let file): player = self.player(for: file)
        case .pen, .off: player = nil
        }
        guard let player else { return }
        stopCustom()
        start(player, label: choice.displayName)
        playing = player
    }

    private func start(_ player: AVAudioPlayer, label: String) {
        player.currentTime = 0
        let started = player.play()
        log.notice("sound \(label, privacy: .public) started \(started, privacy: .public), volume \(player.volume, privacy: .public), \(player.duration, format: .fixed(precision: 2), privacy: .public) s")
    }

    private func stopCustom() {
        if let playing, playing.isPlaying { playing.stop() }
        playing = nil
    }

    /// Decoded once per file, its volume set from its loudness against the pen.
    private func player(for file: String) -> AVAudioPlayer? {
        if let cached = custom[file] { return cached }
        let player = loadMatched(folder.appendingPathComponent(file), name: file)
        custom[file] = player
        return player
    }

    /// A cue from the bundle's Resources/Sounds/cuelume, decoded once, matched like a custom file.
    private func player(for cue: Cue) -> AVAudioPlayer? {
        if let cached = cues[cue] { return cached }
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: Cue.fileExtension, subdirectory: Cue.resourceDirectory) else {
            log.error("no \(cue.fileName, privacy: .public) in the bundle")
            return nil
        }
        let player = loadMatched(url, name: cue.fileName)
        cues[cue] = player
        return player
    }

    private func loadMatched(_ url: URL, name: String) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            log.error("could not open \(name, privacy: .public)")
            return nil
        }
        let level = Sounds.measure(url) ?? (rms: penRMS, peak: 1)
        player.volume = SoundLevel.volume(rms: level.rms, peak: level.peak, referenceRMS: penRMS, referenceVolume: Sounds.volume)
        player.prepareToPlay()
        log.notice("loaded \(name, privacy: .public): rms \(20 * log10(max(level.rms, 1e-6)), format: .fixed(precision: 1), privacy: .public) dBFS, peak \(20 * log10(max(level.peak, 1e-6)), format: .fixed(precision: 1), privacy: .public) dBFS, volume \(player.volume, privacy: .public)")
        return player
    }
}

/// Players handed to a background queue for prepareToPlay only.
private final class PlayerBox: @unchecked Sendable {
    let players: [AVAudioPlayer]
    init(_ players: [AVAudioPlayer]) { self.players = players }
}
