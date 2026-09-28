import Foundation

/// One of the 17 Cuelume cues (github.com/Danilaa1/cuelume, MIT), rendered once to a file in the
/// app bundle by scripts/render-cues. In Cuelume's own order.
public enum Cue: String, CaseIterable, Sendable {
    case chime, sparkle, droplet, bloom, whisper, tick, press, release, toggle
    case success, error, page, loading, ready, pulse, scan, arrival

    /// Stored values of cues start with this, so they never read as a file name.
    public static let storedPrefix = "cuelume:"
    /// Where the files are, inside the bundle's Resources and in the repo's Resources.
    public static let resourceDirectory = "Sounds/cuelume"
    public static let fileExtension = "caf"

    /// "cuelume:loading".
    public var stored: String { Cue.storedPrefix + rawValue }

    /// From a stored value: "cuelume:loading" is loading; anything else is no cue.
    public init?(stored: String) {
        guard stored.hasPrefix(Cue.storedPrefix) else { return nil }
        self.init(rawValue: String(stored.dropFirst(Cue.storedPrefix.count)))
    }

    /// "Loading".
    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// "loading.caf".
    public var fileName: String { "\(rawValue).\(Cue.fileExtension)" }
}

/// Which sound a cross off makes: a Cuelume cue, the built in pen scratch, a file from
/// `<config>/sounds/`, or none.
public enum SoundChoice: Equatable, Sendable {
    case pen
    case off
    case cue(Cue)
    case custom(fileName: String)

    /// The UserDefaults key. Nothing stored is the default.
    public static let key = "sound"
    public static let penKey = "pen"
    public static let offKey = "off"
    /// A new install, or a choice whose file is gone.
    public static let defaultChoice = SoundChoice.cue(.loading)
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf"]

    /// The UserDefaults value.
    public var stored: String {
        switch self {
        case .pen: SoundChoice.penKey
        case .off: SoundChoice.offKey
        case .cue(let cue): cue.stored
        case .custom(let file): file
        }
    }

    /// From the stored value and the files present right now. Nothing stored, a cue this version
    /// does not have, and a missing file are the default. An explicit Pen, Off or file stays.
    public static func resolve(stored: String?, available: [String]) -> SoundChoice {
        guard let stored, !stored.isEmpty else { return defaultChoice }
        if stored == penKey { return .pen }
        if stored == offKey { return .off }
        if stored.hasPrefix(Cue.storedPrefix) { return Cue(stored: stored).map(SoundChoice.cue) ?? defaultChoice }
        return available.contains(stored) ? .custom(fileName: stored) : defaultChoice
    }

    /// The Sound menu and picker, in order: Pen and the custom files, the Cuelume cues under their
    /// own heading, then Off.
    public static func groups(customFiles: [String]) -> [SoundGroup] {
        [
            SoundGroup(title: nil, choices: [.pen] + customFiles.map { .custom(fileName: $0) }),
            SoundGroup(title: "Cuelume", choices: Cue.allCases.map(SoundChoice.cue)),
            SoundGroup(title: nil, choices: [.off]),
        ]
    }

    /// Is this file name one the app lists?
    public static func isAudioFile(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        return audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// "texture-scratch.mp3" -> "Texture Scratch". Dashes and underscores become spaces, words are title cased.
    public static func displayName(fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { word -> String in
                let first = word.prefix(1).uppercased()
                return first + word.dropFirst()
            }
            .joined(separator: " ")
    }

    public var displayName: String {
        switch self {
        case .pen: "Pen"
        case .off: "Off"
        case .cue(let cue): cue.displayName
        case .custom(let file): SoundChoice.displayName(fileName: file)
        }
    }
}

/// A run of sound choices in a menu, with a heading or none. Groups are split by a divider.
public struct SoundGroup: Equatable, Sendable {
    public let title: String?
    public let choices: [SoundChoice]
}

/// The sound when a pasted link turns into its title, with the sparkle: a Cuelume cue or none.
public enum LinkSound {
    /// The UserDefaults key. Nothing stored is the default.
    public static let key = "linkSound"
    public static let noneKey = "none"
    /// A new install, or a cue this version does not have.
    public static let defaultCue: Cue = .sparkle
    /// The Link sound menu and picker: None, then every cue.
    public static let options: [Cue?] = [nil] + Cue.allCases.map { $0 }

    /// The cue to play, nil for None.
    public static func resolve(stored: String?) -> Cue? {
        guard let stored, !stored.isEmpty else { return defaultCue }
        if stored == noneKey { return nil }
        return Cue(stored: stored) ?? defaultCue
    }

    /// The UserDefaults value.
    public static func stored(_ cue: Cue?) -> String { cue?.stored ?? noneKey }

    public static func displayName(_ cue: Cue?) -> String { cue?.displayName ?? "None" }
}

/// Loudness matching: every sound lands near the pen scratch at its volume.
public enum SoundLevel {
    /// The player volume for a sound with `rms` (linear, 0...1) so it is as loud as the reference
    /// at `referenceVolume`. Never above 1, never below 0.02, and never so high that `peak`
    /// would clip.
    public static func volume(rms: Double, peak: Double, referenceRMS: Double, referenceVolume: Double) -> Float {
        guard rms > 0, referenceRMS > 0 else { return Float(referenceVolume) }
        var v = referenceVolume * referenceRMS / rms
        if peak > 0 { v = min(v, 1 / peak) }
        return Float(min(max(v, 0.02), 1))
    }
}
