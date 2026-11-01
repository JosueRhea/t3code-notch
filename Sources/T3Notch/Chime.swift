import AVFoundation

/// Soft, warm notification sounds. A finished run plays Hex's "classic" sound
/// (Resources/Sounds/done.wav, MIT, see LICENSE-hex); the rest are synthesized on the fly.
///
/// Each synthesized sound is a deep wooden knock: a low tone that drops slightly in pitch,
/// a hollow body an octave below, a quick marimba-like overtone, and a dark breath of noise
/// at the start for the contact. A touch of room reverb keeps it warm. Kept quiet on purpose.
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
    private let dry = AVAudioPlayerNode() // recorded sounds: already mixed, no added reverb
    // Stereo: AVAudioUnitReverb rejects mono input (-10868) with an uncatchable exception.
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var stopWork: DispatchWorkItem?
    private var recorded: Set<Sound> = []

    private init() {
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 18
        engine.attach(player)
        engine.attach(reverb)
        engine.connect(player, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        engine.attach(dry)
        engine.connect(dry, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.55

        // (frequency Hz, start s, loudness)
        if let done = Self.load("done", as: format) { // Hex's classic
            buffers[.done] = done
            recorded.insert(.done)
        } else {
            buffers[.done] = render([(330, 0.00, 1.0)])               // one soft knock
        }
        buffers[.needsYou] = render([(392, 0.00, 0.85), (311, 0.11, 1.0)]) // knock-knock: "hey"
        buffers[.failed] = render([(196, 0.00, 1.0)], decay: 0.11)      // lower, hollower knock
    }

    func play(_ sound: Sound) {
        guard Self.enabled, let buffer = buffers[sound] else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        let node = sound == .done && recorded.contains(.done) ? dry : player
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
        // Shut the engine down once the click (and its reverb tail) is over: a running
        // AVAudioEngine keeps a realtime audio thread spinning and the audio hardware awake.
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.player.stop()
            self?.dry.stop()
            self?.engine.stop()
        }
        stopWork = work
        let seconds = Double(buffer.frameLength) / format.sampleRate + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A bundled sound, converted once to the engine's format (44.1 kHz stereo float).
    private static func load(_ name: String, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds"),
              let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil else { return nil }
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        let frames = AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / source.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        var fed = false
        let status = converter.convert(to: out, error: nil) { _, input in
            if fed { input.pointee = .endOfStream; return nil }
            fed = true
            input.pointee = .haveData
            return source
        }
        return status == .error ? nil : out
    }

    private func render(_ taps: [(Double, Double, Float)], decay: Double = 0.085) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let length = (taps.map(\.1).max() ?? 0) + decay * 8 + 0.2 // room for the reverb tail
        let frames = AVAudioFrameCount(length * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { out[i] = 0 }
        defer { buffer.floatChannelData![1].update(from: out, count: Int(frames)) } // same sound both ears

        var seed: UInt32 = 0x2545F491
        for (freq, start, gain) in taps {
            let offset = Int(start * rate)
            var phase = 0.0, sub = 0.0
            var noise: Float = 0
            for i in 0..<min(Int(decay * 8 * rate), Int(frames) - offset) {
                let t = Double(i) / rate
                let attack = min(1, t / 0.003)                    // 3ms: soft edge, no harsh click
                let env = attack * exp(-t / decay)
                let drop = 1 - 0.08 * min(1, t / 0.04)            // slight pitch drop = wood
                phase += 2 * .pi * freq * drop / rate
                sub += 2 * .pi * freq * 0.5 * drop / rate         // hollow body, an octave down
                let body = sin(phase)
                    + 0.18 * sin(3.9 * phase) * exp(-t / (decay * 0.18)) // marimba-like overtone, gone fast
                    + 0.45 * sin(sub) * exp(-t / (decay * 0.7))
                // Darker (more low-passed) noise for the first ~6ms: the "felt" contact.
                seed = seed &* 1664525 &+ 1013904223
                noise += (Float(seed >> 8) / Float(1 << 24) * 2 - 1 - noise) * 0.08
                let contact = Double(noise) * exp(-t / 0.006) * 0.5
                out[offset + i] += Float((body * env + contact) * 0.3) * gain
            }
        }
        return buffer
    }
}
