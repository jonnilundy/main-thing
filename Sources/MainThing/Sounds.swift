import AVFoundation
import Foundation
import MainThingCore
import os

/// The pen on paper. One scratch per text line as the ink draws, a lighter one on undo.
/// Quiet (0.25), prepared at launch so the first one is not late. Silent when the system
/// setting "Play user interface sound effects" is off or the Sounds menu item is off.
@MainActor
final class Sounds {
    static let volume: Float = 0.25
    private static let key = "sounds"

    /// The Sounds toggle in the notch menu. On by default.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// System Settings > Sound > "Play user interface sound effects". Off is 0 in the global domain.
    static var systemAllows: Bool {
        if let value = UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int {
            return value != 0
        }
        return true
    }

    private let log = Logger(subsystem: MainThingBundleID, category: "sound")
    /// A few players per sound, so the lines of one title can overlap their tails.
    private var scratches: [AVAudioPlayer] = []
    private var unscratches: [AVAudioPlayer] = []
    private var next = 0

    init() {
        scratches = Sounds.load("scratch", count: 3)
        unscratches = Sounds.load("unscratch", count: 2)
        if scratches.isEmpty { log.notice("no scratch.wav in the bundle, cross off stays silent") }
        // Wake the output device now, silently, so the first real scratch is not half a second late.
        if let player = scratches.first {
            player.volume = 0
            player.play()
            player.stop()
            player.currentTime = 0
            player.volume = Sounds.volume
        }
    }

    private static func load(_ name: String, count: Int) -> [AVAudioPlayer] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return [] }
        return (0..<count).compactMap { _ in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.volume = volume
            player.prepareToPlay()
            return player
        }
    }

    private var allowed: Bool { Sounds.enabled && Sounds.systemAllows }

    /// Called when the notch opens: gets the players ready off the main thread, so a click a moment
    /// later plays at once and the open itself is not held up by the audio device waking.
    func prime() {
        let box = PlayerBox(scratches + unscratches)
        DispatchQueue.global(qos: .userInitiated).async {
            for player in box.players where !player.isPlaying { player.prepareToPlay() }
        }
    }

    /// One scratch per line, each on the pen's own timing.
    func scratch(lines: Int) {
        guard allowed, !scratches.isEmpty else { return }
        for line in 0..<max(lines, 1) {
            let player = scratches[next % scratches.count]
            next += 1
            let at = player.deviceCurrentTime + Double(line) * PenStroke.secondsPerLine
            player.currentTime = 0
            player.play(atTime: at)
            log.notice("sound scratch line \(line, privacy: .public) at +\(Int(Double(line) * PenStroke.secondsPerLine * 1000), privacy: .public) ms")
        }
    }

    /// The undo: a short, lighter scratch the other way.
    func unscratch() {
        guard allowed, let player = unscratches.first(where: { !$0.isPlaying }) ?? unscratches.first else { return }
        player.currentTime = 0
        player.play()
        log.notice("sound unscratch")
    }
}

/// Players handed to a background queue for prepareToPlay only.
private final class PlayerBox: @unchecked Sendable {
    let players: [AVAudioPlayer]
    init(_ players: [AVAudioPlayer]) { self.players = players }
}
