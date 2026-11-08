import AVFoundation
import Foundation

/// The welcome's sound: a sweep of air that rises and crosses from left to right with the light,
/// as the ribbons run, and lands with a soft, low thump as the name arrives. No notes. It's drawn
/// in code, like the themes, so there's nothing to ship. It respects the Mac's "Play user
/// interface sound effects" setting.
@MainActor
final class OpeningSound {
    static let shared = OpeningSound()

    /// When the name arrives, from the start. The sound lands just ahead of it.
    static let chime: Double = 2.55
    static let length: Double = 5.5

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    /// Whether the Mac plays interface sounds. It's on unless someone turned it off.
    static var isAllowed: Bool {
        UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }

    func play() {
        guard Self.isAllowed, engine == nil, let buffer = Self.render() else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stop() } }
        }
        player.play()
        self.engine = engine
        self.player = player
    }

    /// Fades out quickly, for a skipped opening.
    func fadeOut() {
        guard let engine else { return }
        let mixer = engine.mainMixerNode
        Task { @MainActor [weak self] in
            for step in stride(from: 1.0, through: 0, by: -0.1) {
                mixer.outputVolume = Float(step)
                try? await Task.sleep(for: .milliseconds(25))
            }
            self?.stop()
        }
    }

    private func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    /// The whole sound with its room, rendered ahead so it plays the same every time.
    static func render(sampleRate: Double = 48_000) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let dry = dryBuffer(format: format) else { return nil }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let room = AVAudioUnitReverb()
        room.loadFactoryPreset(.largeHall)
        room.wetDryMix = 20
        engine.attach(player)
        engine.attach(room)
        engine.connect(player, to: room, format: format)
        engine.connect(room, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
        } catch { return nil }
        player.scheduleBuffer(dry)
        player.play()
        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: dry.frameCapacity) else { return nil }
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while out.frameLength < out.frameCapacity {
            let frames = min(4096, out.frameCapacity - out.frameLength)
            guard (try? engine.renderOffline(frames, to: chunk)) == .success else { break }
            for channel in 0 ..< Int(format.channelCount) {
                let from = chunk.floatChannelData![channel], to = out.floatChannelData![channel] + Int(out.frameLength)
                to.update(from: from, count: Int(chunk.frameLength))
            }
            out.frameLength += chunk.frameLength
        }
        engine.stop()
        return out
    }

    /// Noise, filtered as it goes, so it's the same every time.
    private struct Noise {
        var state: UInt32
        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state >> 8) / Double(1 << 24) * 2 - 1
        }
    }

    /// A band-pass filter whose center can move every sample.
    private struct Band {
        var low = 0.0, band = 0.0
        mutating func run(_ x: Double, center: Double, q: Double, rate: Double) -> Double {
            let g = 2 * sin(.pi * min(center, rate / 6) / rate)
            low += g * band
            let high = x - low - band / q
            band += g * high
            return band
        }
    }

    private struct LowPass {
        var y = 0.0
        mutating func run(_ x: Double, cutoff: Double, rate: Double) -> Double {
            y += (x - y) * (1 - exp(-2 * .pi * cutoff / rate))
            return y
        }
    }

    /// The sweep, gathering to the landing and gone a quarter of a second after it, and the landing:
    /// a low round thump, falling slightly in pitch, with a puff of air.
    private static func dryBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let count = AVAudioFrameCount(length * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        buffer.frameLength = count
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        let landing = chime - 0.05

        func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        var noiseL = Noise(state: 0x1234_5678), noiseR = Noise(state: 0x8765_4321), noisePuff = Noise(state: 0x0BAD_F00D)
        var bandL = Band(), bandR = Band(), body = LowPass(), puff = LowPass()

        for i in 0 ..< Int(count) {
            let t = Double(i) / rate

            // The sweep: its color rises from 280 Hz a decade, and it moves from the left to the right.
            let up = smooth((t - 0.2) / (landing - 0.2))
            let level = pow(up, 2.2) * (t < landing ? 1 : exp(-(t - landing) / 0.25)) * 0.55
            let center = 280 * pow(10, up)
            let a = bandL.run(noiseL.next(), center: center, q: 0.9, rate: rate)
            let b = bandR.run(noiseR.next(), center: center * 1.04, q: 0.9, rate: rate)
            let low = body.run((noiseL.next() + noiseR.next()) * 0.5, cutoff: 160, rate: rate) * 2.2
            let pan = 0.22 + 0.56 * up
            var l = (a + low * 0.4) * cos(pan * .pi / 2) * 1.41 * level
            var r = (b + low * 0.4) * sin(pan * .pi / 2) * 1.41 * level

            // The landing.
            if t >= landing {
                let d = t - landing
                let pitch = 56 + 10 * exp(-d / 0.06)
                let thump = (sin(2 * .pi * pitch * d) + 0.25 * sin(4 * .pi * pitch * d)) * min(1, d / 0.008) * exp(-d / 0.3)
                let air = puff.run(noisePuff.next(), cutoff: 900, rate: rate) * 3 * min(1, d / 0.005) * exp(-d / 0.09)
                let hit = (thump * 0.8 + air * 0.35) * 0.5
                l += hit
                r += hit
            }

            // A gentle start and end, never a click.
            let edges = min(1, t / 0.02) * min(1, (length - t) / 0.3)
            left[i] = Float(tanh(l) * edges * 0.92)
            right[i] = Float(tanh(r) * edges * 0.92)
        }
        return buffer
    }
}
