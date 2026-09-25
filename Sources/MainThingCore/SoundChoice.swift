import Foundation

/// Which sound a cross off makes: the built in pen scratch, a file from `<config>/sounds/`, or none.
public enum SoundChoice: Equatable, Sendable {
    case pen
    case off
    case custom(fileName: String)

    public static let penKey = "pen"
    public static let offKey = "off"
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf"]

    /// The UserDefaults value.
    public var stored: String {
        switch self {
        case .pen: SoundChoice.penKey
        case .off: SoundChoice.offKey
        case .custom(let file): file
        }
    }

    /// From the stored value and the files present right now. A missing file falls back to Pen,
    /// as does nothing stored.
    public static func resolve(stored: String?, available: [String]) -> SoundChoice {
        guard let stored, !stored.isEmpty else { return .pen }
        if stored == penKey { return .pen }
        if stored == offKey { return .off }
        return available.contains(stored) ? .custom(fileName: stored) : .pen
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
        case .custom(let file): SoundChoice.displayName(fileName: file)
        }
    }
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
