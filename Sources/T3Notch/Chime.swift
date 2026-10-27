import AVFoundation

/// Soft, warm notification sounds synthesized on the fly (no audio files).
///
/// Each sound is a tiny wooden "tock": a short tone that drops slightly in pitch and
/// dies out in ~50ms, with a breath of soft noise at the start for the tactile edge.
/// A touch of small-room reverb keeps it warm instead of clinical. Kept quiet on purpose.
@MainActor
final class Chime {
    static let shared = Chime()

    enum Sound { case done, needsYou, failed }

    private static let enabledKey = "soundsEnabled"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    // Stereo: AVAudioUnitReverb rejects mono input (-10868) with an uncatchable exception.
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var stopWork: DispatchWorkItem?

    private init() {
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 12
        engine.attach(player)
        engine.attach(reverb)
        engine.connect(player, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0.55

        // (frequency Hz, start s, loudness)
        buffers[.done] = render([(620, 0.00, 1.0)])                    // one soft tock
        buffers[.needsYou] = render([(840, 0.00, 0.8), (700, 0.085, 0.9)]) // tick-tock: "hey"
        buffers[.failed] = render([(330, 0.00, 1.0)], decay: 0.07)     // lower, duller tock
    }

    func play(_ sound: Sound) {
        guard Self.enabled, let buffer = buffers[sound] else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        // Shut the engine down once the click (and its reverb tail) is over: a running
        // AVAudioEngine keeps a realtime audio thread spinning and the audio hardware awake.
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.player.stop()
            self?.engine.stop()
        }
        stopWork = work
        let seconds = Double(buffer.frameLength) / format.sampleRate + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func render(_ taps: [(Double, Double, Float)], decay: Double = 0.05) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let length = (taps.map(\.1).max() ?? 0) + decay * 8 + 0.15 // room for the reverb tail
        let frames = AVAudioFrameCount(length * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { out[i] = 0 }
        defer { buffer.floatChannelData![1].update(from: out, count: Int(frames)) } // same sound both ears

        var seed: UInt32 = 0x2545F491
        for (freq, start, gain) in taps {
            let offset = Int(start * rate)
            var phase = 0.0
            var noise: Float = 0
            for i in 0..<min(Int(decay * 8 * rate), Int(frames) - offset) {
                let t = Double(i) / rate
                let attack = min(1, t / 0.002)                    // 2ms: soft edge, no harsh click
                let env = attack * exp(-t / decay)
                phase += 2 * .pi * freq * (1 - 0.12 * min(1, t / 0.03)) / rate // slight pitch drop = wood
                let body = sin(phase) + 0.25 * sin(2.01 * phase) * exp(-t / (decay * 0.3))
                // Low-passed noise burst for the first ~4ms: the "felt" contact.
                seed = seed &* 1664525 &+ 1013904223
                noise += (Float(seed >> 8) / Float(1 << 24) * 2 - 1 - noise) * 0.25
                let contact = Double(noise) * exp(-t / 0.004) * 0.35
                out[offset + i] += Float((body * env + contact) * 0.3) * gain
            }
        }
        return buffer
    }
}
