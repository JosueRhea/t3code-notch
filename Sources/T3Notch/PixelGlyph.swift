import AppKit

/// Provider logos as pixel art (7×7; Claude's spark 9×9 so its rays stay round), in each brand's color. While a thread works, a lit head
/// sweeps clockwise around the logo's rings and leaves a fading trail: opencode's "Soft Radar"
/// spinner (MIT, github.com/sst/opencode, packages/ui/src/components/spinner-radar.ts), run
/// over the logo's own pixels. Every glyph shares one clock, so they all sweep in step.
enum PixelArt {

    struct Art {
        let rows: [String]
        let color: NSColor
    }

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// The shared drawings (Shared/PixelArtData.swift, also used by the iPhone Live Activity).
    static func art(for provider: String?) -> Art {
        if let a = provider.flatMap({ PixelArtData.arts[$0] }) { return Art(rows: a.rows, color: hex(a.rgb)) }
        return Art(rows: PixelArtData.fallbackRows, color: ThreadStatus.working.color) // unknown provider
    }

    // Soft Radar's fade curve (opencode's samples, at 55% of the head), a bit quicker than
    // theirs: a lap in 1.3s reads as busy without racing (theirs is 1.8s, 0.9s felt frantic).
    static let loop = 1.3
    static let dim: Float = 0.3 // a touch above Soft Radar's 0.2: small dots on black still read as the logo
    private static let fade: [Double] = [1, 0.987, 0.934, 0.812, 0.599, 0.384, 0.238, 0.143, 0.081, 0.041, 0.017, 0.004, 0]

    /// One dot's opacity over a loop, 0 being the moment the head reaches it.
    static let stops: [(Double, Float)] = {
        var s: [(Double, Float)] = [(0, 1), (0.03, 1)]
        for (i, f) in fade.enumerated() { s.append((0.04 + 0.035 * Double(i), level(0.55 * f))) }
        s += [(0.965, dim), (0.985, 1), (1, 1)]
        return s
    }()

    static func level(_ l: Double) -> Float { dim + (1 - dim) * Float(l) }
}

@MainActor
final class PixelGlyph: NSView {
    enum Motion: Equatable {
        case still(Float)        // opacity
        case sweep(slow: Bool)   // working (or slowly: connecting)
        case wave                // waiting: a soft band of light drifting down and back up
        case breathe             // needs you
    }

    private struct Dot {
        let layer: CALayer
        let x: Int, y: Int
        /// Clockwise from 12 o'clock, 0–1: when the head passes it.
        let at: Double
        let center: Bool
    }

    private var dots: [Dot] = []
    private var grid = 7
    private var shown: (provider: String?, motion: Motion)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { animate() } // CA drops animations when a layer leaves its window
    }

    func configure(provider: String?, motion: Motion) {
        if let s = shown, s.provider == provider, s.motion == motion { return }
        let rebuild = shown?.provider != provider || dots.isEmpty
        shown = (provider, motion)
        if rebuild { build(PixelArt.art(for: provider)) }
        animate()
    }

    private func build(_ art: PixelArt.Art) {
        dots.forEach { $0.layer.removeFromSuperlayer() }
        dots = []
        grid = art.rows.count
        let n = grid, mid = Double(n - 1) / 2
        for (y, row) in art.rows.enumerated() {
            for (x, c) in row.enumerated() where c == "#" {
                let l = CALayer()
                l.backgroundColor = art.color.cgColor
                layer?.addSublayer(l)
                let gx = Double(x) - mid, gy = Double(y) - mid
                let angle = atan2(gx, -gy) / (2 * .pi)
                dots.append(Dot(layer: l, x: x, y: y, at: angle - floor(angle), center: gx == 0 && gy == 0))
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let n = CGFloat(grid)
        let side = min(bounds.width, bounds.height)
        // Dots about 3/4 of the pitch (opencode's are 2 in 3), snapped to half points: whole Retina pixels.
        let pitch = side / n, dot = max(1.5, (pitch * 0.75 * 2).rounded() / 2)
        let ox = (bounds.width - side) / 2 + (pitch - dot) / 2, oy = (bounds.height - side) / 2 + (pitch - dot) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for d in dots {
            d.layer.frame = CGRect(x: ox + CGFloat(d.x) * pitch, y: oy + CGFloat(d.y) * pitch, width: dot, height: dot)
            d.layer.cornerRadius = dot * 0.24
        }
        CATransaction.commit()
    }

    private func animate() {
        guard window != nil, let motion = shown?.motion else { return }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for d in dots {
            d.layer.removeAllAnimations()
            switch motion {
            case .still(let opacity):
                d.layer.opacity = opacity
            case .breathe:
                d.layer.opacity = 1
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0.35
                a.toValue = 1
                a.duration = 0.8
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                d.layer.add(a, forKey: "glyph")
            case .wave:
                // A soft band of light drifts top → bottom → top; each row brightens as it passes.
                // Same 3.6s clock for every glyph, so waiting threads drift together.
                let period = 3.6, samples = 36
                let row = Double(d.y) / Double(max(grid - 1, 1))
                var values: [NSNumber] = []
                for i in 0...samples {
                    let t = Double(i) / Double(samples)
                    let band = 0.5 - 0.5 * cos(2 * .pi * t) // 0 → 1 → 0, eased at both ends
                    let lift = exp(-pow((row - band) / 0.28, 2))
                    values.append(NSNumber(value: Float(0.35 + 0.65 * lift)))
                }
                d.layer.opacity = 0.35
                let a = CAKeyframeAnimation(keyPath: "opacity")
                a.values = values
                a.duration = period
                a.repeatCount = .infinity
                a.calculationMode = .cubic
                a.timeOffset = now.truncatingRemainder(dividingBy: period)
                d.layer.add(a, forKey: "glyph")
            case .sweep(let slow):
                if d.center { d.layer.opacity = PixelArt.level(0.55); continue } // steady, like Soft Radar's
                d.layer.opacity = PixelArt.dim
                let loop = PixelArt.loop * (slow ? 2 : 1)
                let a = CAKeyframeAnimation(keyPath: "opacity")
                a.values = PixelArt.stops.map { NSNumber(value: $0.1) }
                a.keyTimes = PixelArt.stops.map { NSNumber(value: $0.0) }
                a.duration = loop
                a.repeatCount = .infinity
                // Phase from the wall clock, so every glyph on screen sweeps in step.
                a.timeOffset = loop * (1 - d.at) + now.truncatingRemainder(dividingBy: loop)
                d.layer.add(a, forKey: "glyph")
            }
        }
        CATransaction.commit()
    }
}
