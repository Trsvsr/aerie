import AVFoundation
import AppKit

/// Synthesized event cues — generated at runtime with AVAudioEngine so the
/// binary stays a single file (SPM resource bundles would break the
/// copy-one-binary install the hooks depend on).
@MainActor
final class SoundPlayer {
    enum Cue {
        case approval      // two rising blips: something needs you NOW
        case needsInput    // single gentle blip
        case completion    // soft decaying tone + fifth
        case deny          // low thud
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var ready = false
    private let sampleRate: Double = 44_100
    /// Rendered buffers, built lazily per cue.
    private var buffers: [String: AVAudioPCMBuffer] = [:]

    var volume: Float = 0.5 {
        didSet { player.volume = volume }
    }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        player.volume = volume
        do {
            try engine.start()
            player.play()
            ready = true
        } catch {
            log("sound engine failed to start: \(error) — falling back to beep")
        }
    }

    func play(_ cue: Cue) {
        guard ready else { NSSound.beep(); return }
        let key = String(describing: cue)
        let buffer = buffers[key] ?? {
            let b = render(cue)
            buffers[key] = b
            return b
        }()
        guard let buffer else { NSSound.beep(); return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !engine.isRunning { try? engine.start(); player.play() }
    }

    // MARK: synthesis

    /// A tone segment: frequency, duration, attack/decay envelope.
    private struct Segment {
        var freq: Double
        var duration: Double
        var gain: Double = 0.8
        var startAt: Double        // offset into the buffer
    }

    private func segments(for cue: Cue) -> [Segment] {
        switch cue {
        case .approval:
            return [Segment(freq: 880, duration: 0.09, startAt: 0),
                    Segment(freq: 1174.7, duration: 0.12, startAt: 0.11)]
        case .needsInput:
            return [Segment(freq: 987.8, duration: 0.12, gain: 0.6, startAt: 0)]
        case .completion:
            return [Segment(freq: 523.3, duration: 0.28, gain: 0.55, startAt: 0),
                    Segment(freq: 784.0, duration: 0.24, gain: 0.35, startAt: 0.03)]
        case .deny:
            return [Segment(freq: 220, duration: 0.15, gain: 0.7, startAt: 0)]
        }
    }

    private func render(_ cue: Cue) -> AVAudioPCMBuffer? {
        let segs = segments(for: cue)
        let total = segs.map { $0.startAt + $0.duration }.max() ?? 0.2
        let frames = AVAudioFrameCount(total * sampleRate) + 1
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { out[i] = 0 }

        for seg in segs {
            let start = Int(seg.startAt * sampleRate)
            let count = Int(seg.duration * sampleRate)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                // fast attack, exponential-ish decay; sine core with a hint
                // of second harmonic for the 8-bit-adjacent character
                let attack = min(1.0, t / 0.008)
                let decay = pow(1.0 - Double(i) / Double(count), 1.6)
                let sample = sin(2 * .pi * seg.freq * t) * 0.85
                    + sin(4 * .pi * seg.freq * t) * 0.15
                let idx = start + i
                if idx < Int(frames) {
                    out[idx] += Float(sample * attack * decay * seg.gain)
                }
            }
        }
        return buffer
    }
}
