// Synthesizes the cross off sounds: a felt tip scratching paper. No samples, only filtered noise.
//
//   swift scripts/make-sound.swift Resources
//
// scratch.wav   220 ms, one pen stroke: fast attack, a grainy body, a soft tail, the band pass
//               sweeping down a little as the pen slows.
// unscratch.wav 120 ms, lighter and reversed in feel (sweep up), for the undo.
import Foundation

let sampleRate = 44_100.0

/// A resonant band pass (biquad) whose center can move per sample.
struct BandPass {
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    mutating func run(_ x: Double, center: Double, q: Double) -> Double {
        let w = 2 * .pi * center / sampleRate
        let alpha = sin(w) / (2 * q)
        let b0 = alpha, b1 = 0.0, b2 = -alpha
        let a0 = 1 + alpha, a1 = -2 * cos(w), a2 = 1 - alpha
        let y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

struct Noise {
    var state: UInt64 = 0x9e37_79b9_7f4a_7c15
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

/// Render one scratch. `sweep` goes from the start to the end center frequency.
func scratch(seconds: Double, attack: Double, tail: Double, from: Double, to: Double, grain: Double, gain: Double) -> [Double] {
    let n = Int(seconds * sampleRate)
    var noise = Noise()
    var band = BandPass()
    var band2 = BandPass()
    var out = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sampleRate
        let u = t / seconds
        // Envelope: linear attack, flat body, exponential tail over the last `tail` seconds.
        var env = min(t / attack, 1)
        let left = seconds - t
        if left < tail { env *= exp(-4 * (1 - left / tail)) }
        // The pen slows into the end: the band drops from `from` to `to`, and the grain thins.
        let center = from + (to - from) * pow(u, 0.7)
        let raw = noise.next()
        // Grain: bursts of fibre contact, a slow random gate on top of the hiss.
        let gate = 0.6 + 0.4 * (0.5 + 0.5 * sin(2 * .pi * (grain + 25 * u) * t * 7))
        var s = band.run(raw, center: center, q: 1.6) * 3
        s += band2.run(raw, center: center * 2.3, q: 4) * 0.8
        out[i] = s * env * gate * gain
    }
    // Normalize to the gain as a peak.
    let peak = out.map(abs).max() ?? 1
    return out.map { $0 / peak * gain }
}

func writeWav(_ samples: [Double], to url: URL) throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    for s in samples {
        let v = Int16(max(-1, min(1, s)) * 32767)
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    try data.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try writeWav(scratch(seconds: 0.22, attack: 0.006, tail: 0.07, from: 2600, to: 1500, grain: 3, gain: 0.7), to: dir.appendingPathComponent("scratch.wav"))
try writeWav(scratch(seconds: 0.12, attack: 0.004, tail: 0.05, from: 1600, to: 2400, grain: 5, gain: 0.45), to: dir.appendingPathComponent("unscratch.wav"))
print("wrote scratch.wav (220 ms) and unscratch.wav (120 ms) in \(dir.path)")
