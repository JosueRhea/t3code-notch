import AppKit

/// The notch, in AppKit + Core Animation (no SwiftUI anywhere).
///
/// SwiftUI re-laid out its whole view tree for every animation frame and every state change,
/// which was ~95% of the app's CPU while threads were working. Here the notch shape is a
/// CAShapeLayer and every label is a plain NSTextField: springs, slides and rolling digits are
/// CAAnimations that run in the window server, so the app does no work per frame.
///
/// The expanded list and cards (NotchContent.swift) only exist while open.
@MainActor
final class NotchRootView: NSView {
    private let model: NotchModel
    private let store: ThreadStore
    private let shape = CAShapeLayer()
    /// The theme's background over the black shape, clipped to it (same springs). With a camera
    /// notch it stays black around the camera and eases into the theme color over the whole panel
    /// (a short fade read as a black band stuck on top).
    private let backdrop = CAGradientLayer()
    private let backdropMask = CAShapeLayer()
    private let compact: CompactBar
    private var content: NSView?
    private var contentKey = ""
    private var applied: (mode: NotchMode, size: CGSize)?

    /// Response 0.42s, damping fraction 0.78: settles fast with a small overshoot.
    nonisolated static func spring(_ keyPath: String) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / 0.42, 2)      // response 0.42s
        a.damping = 2 * 0.78 * (2 * .pi / 0.42)   // damping fraction 0.78
        a.duration = a.settlingDuration
        return a
    }

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        compact = CompactBar(model: model, store: store)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = Theme.current.glowColor
        shape.shadowOpacity = 0
        shape.shadowRadius = 14
        shape.shadowOffset = CGSize(width: 0, height: 6)
        layer?.addSublayer(shape)
        if let color = Theme.current.background?.cgColor {
            backdrop.colors = model.hardwareNotch ? Self.easedFade(to: color) : [color, color]
            backdrop.mask = backdropMask
            layer?.addSublayer(backdrop)
        }
        addSubview(compact)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true } // top-left origin
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        applied = nil // canvas changed: re-place everything without animating
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        backdropMask.frame = backdrop.bounds
        CATransaction.commit()
        fadeBackdrop(to: model.size)
        refresh(animated: false)
    }

    /// Called on any model/store change. Cheap when nothing visible changed.
    func refresh(animated: Bool = true) {
        let mode = model.mode
        let size = model.size
        // Where the black shape is *right now* (mid-spring), before it's retargeted.
        var shapeFrom: CGPath?
        if applied?.mode != mode || applied?.size != size {
            let animate = animated && applied != nil
            if animate { shapeFrom = shape.presentation()?.path ?? shape.path }
            setShape(size: size, animated: animate)
            applied = (mode, size)
        }
        syncContent(mode: mode, size: size, shapeFrom: shapeFrom)
        compact.frame = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: model.notchSize.height)
        compact.setVisible(mode == .activity)
        if mode == .activity { compact.update() }
    }

    // MARK: Shape

    private func path(for size: CGSize) -> CGPath {
        NotchShape.path(size: size, topRadius: model.topRadius, bottomRadius: model.bottomRadius,
                        offsetX: (bounds.width - size.width) / 2)
    }

    private static let fadeSteps = 8

    /// Black → theme color with ease-in-out stops, so there's no visible edge where it starts.
    private static func easedFade(to color: CGColor) -> [CGColor] {
        let target = NSColor(cgColor: color) ?? .black
        return (0...fadeSteps).map { i in
            let t = CGFloat(i) / CGFloat(fadeSteps)
            let eased = t * t * (3 - 2 * t)
            return (NSColor.black.blended(withFraction: eased, of: target) ?? target).cgColor
        }
    }

    /// Fade from the bottom of the camera notch to the bottom of the shape at `size`.
    private func fadeBackdrop(to size: CGSize) {
        guard model.hardwareNotch, backdrop.superlayer != nil, bounds.height > 0 else { return }
        let start = model.notchSize.height / bounds.height
        let end = max(start + 0.01, min(1, size.height / bounds.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.locations = (0...Self.fadeSteps).map {
            NSNumber(value: Double(start + (end - start) * CGFloat($0) / CGFloat(Self.fadeSteps)))
        }
        CATransaction.commit()
    }

    private func setShape(size: CGSize, animated: Bool) {
        fadeBackdrop(to: size)
        let newPath = path(for: size)
        let expanded = model.mode == .expanded
        if animated {
            let from = shape.presentation()?.path ?? shape.path
            let spring = Self.spring("path")
            spring.fromValue = from
            spring.toValue = newPath
            shape.add(spring, forKey: "path")
            backdropMask.add(spring, forKey: "path")
            // The shadow's outline springs with the shape (otherwise it pops to the final size
            // before the notch has opened), and it only fades in once the shape is mostly grown.
            let shadowShape = Self.spring("shadowPath")
            shadowShape.fromValue = shape.presentation()?.shadowPath ?? from
            shadowShape.toValue = newPath
            shape.add(shadowShape, forKey: "shadowPath")
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = shape.presentation()?.shadowOpacity ?? shape.shadowOpacity
            fade.toValue = expanded ? Theme.current.glowOpacity : 0
            fade.duration = expanded ? 0.22 : 0.1
            if expanded {
                fade.beginTime = CACurrentMediaTime() + 0.2
                fade.fillMode = .backwards // hold the old (zero) opacity until it starts
            }
            shape.add(fade, forKey: "shadow")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = newPath
        backdropMask.path = newPath
        shape.shadowPath = newPath
        // A shadow is a blur pass; only pay for it while it shows.
        shape.shadowOpacity = expanded ? Theme.current.glowOpacity : 0
        CATransaction.commit()
    }

    // MARK: Expanded list / cards, only while open

    private func syncContent(mode: NotchMode, size: CGSize, shapeFrom: CGPath?) {
        let event = store.event
        let key: String = switch mode {
        case .expanded: "expanded"
        case .peek: event.map { "peek:\($0.id):\($0.status.needsYou)" } ?? ""
        default: ""
        }
        if key != contentKey {
            contentKey = key
            if let old = content {
                content = nil
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; old.animator().alphaValue = 0 },
                                                     completionHandler: { old.removeFromSuperview() })
            }
            if !key.isEmpty {
                let view: NSView = switch mode {
                case .expanded: ExpandedView(model: model, store: store)
                default: event?.status.needsYou == true
                    ? NeedsYouView(model: model, store: store) : FinishedView(model: model, store: store)
                }
                view.wantsLayer = true
                view.layer?.mask = CAShapeLayer()
                view.alphaValue = 0
                addSubview(view)
                content = view
                NSAnimationContext.runAnimationGroup { $0.duration = 0.18; view.animator().alphaValue = 1 }
            }
        }
        guard let content else { return }
        let frame = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        let mask = content.layer?.mask as? CAShapeLayer
        if content.frame != frame || shapeFrom != nil {
            content.frame = frame
            let target = NotchShape.path(size: size, topRadius: model.topRadius, bottomRadius: model.bottomRadius)
            if let shapeFrom, let mask {
                // Clip the content with the *same* spring as the black shape, so it never shows
                // outside the notch while it grows. Shape paths live in our coordinates; the mask
                // is in the content view's, so shift by its origin.
                var shift = CGAffineTransform(translationX: -frame.minX, y: 0)
                let spring = Self.spring("path")
                spring.fromValue = shapeFrom.copy(using: &shift)
                spring.toValue = target
                mask.add(spring, forKey: "path")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask?.frame = content.bounds
            mask?.path = target
            CATransaction.commit()
        }
        switch content {
        case let v as ExpandedView: v.update()
        case let v as NeedsYouView: if let e = event { v.configure(e) }
        case let v as FinishedView: if let e = event { v.configure(e) }
        default: break
        }
    }

    /// Open (list or card): every store change updates it; collapsed only on visible changes.
    var isInteractive: Bool { content != nil }
}

// MARK: - Compact bar

/// One row flush with the menu bar: [indicator] [title · activity] [+N −M] [timer] [•• count].
/// On a hardware notch the middle is the camera, so it splits around it.
@MainActor
final class CompactBar: NSView {
    private let model: NotchModel
    private let store: ThreadStore

    private let indicator = StatusIndicator()
    private let featured = NSView()          // slides as a unit when the featured thread changes
    private let title = CompactBar.label(.systemFont(ofSize: 12, weight: .semibold))
    private let icon = NSImageView()
    private let activity = CompactBar.label(.systemFont(ofSize: 11))
    private let diff = CompactBar.label(.monospacedDigitSystemFont(ofSize: 11, weight: .semibold))
    private let timer = CompactBar.label(.monospacedDigitSystemFont(ofSize: 11, weight: .medium))
    private let count = CompactBar.label(CompactBar.rounded(13, .semibold))
    private let pages = PageDotsLayer()

    private var tick: Timer?
    private var ticks = 0
    private var index = 0
    private var shownId: String?
    private var shownDiff: (Int, Int)?
    private var shownCount: Int?

    init(model: NotchModel, store: ThreadStore) {
        self.model = model
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        featured.wantsLayer = true
        diff.wantsLayer = true
        count.wantsLayer = true
        icon.imageScaling = .scaleProportionallyDown
        addSubview(indicator)
        addSubview(featured)
        [title, icon, activity].forEach(featured.addSubview)
        [diff, timer, count].forEach(addSubview)
        layer?.addSublayer(pages)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func label(_ font: NSFont) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = font
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.cell?.truncatesLastVisibleLine = true
        return l
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    // MARK: Visibility + clock

    func setVisible(_ visible: Bool) {
        guard visible == isHidden else { return }
        if visible {
            isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
            // One 1s tick drives the timer label and, every 4th tick, the rotation.
            tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onTick() }
            }
            tick?.tolerance = 0.2 // let macOS coalesce wakeups
        } else {
            tick?.invalidate()
            tick = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; self.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                                                     guard let self, self.alphaValue == 0 else { return }
                                                     self.isHidden = true
                                                 })
        }
    }

    private func onTick() {
        ticks += 1
        if ticks % 4 == 0 { index += 1 }
        update()
    }

    // MARK: Content

    func update() {
        let active = store.active
        guard !active.isEmpty else { return }
        let current = active[index % active.count]
        let lead = leadStatus(active)

        indicator.show(lead, small: false)

        // Featured thread changed: spring-slide the whole line up (render-server animation).
        if current.id != shownId {
            if shownId != nil { featured.layer?.add(Self.slide(), forKey: "slide") }
            shownId = current.id
            shownDiff = nil
        }
        title.stringValue = current.title
        title.textColor = .white
        activity.stringValue = current.activity ?? current.status.label
        activity.font = current.activityIcon == "terminal"
            ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        let color = current.status.color.withAlphaComponent(0.9)
        activity.textColor = color
        icon.image = NSImage(systemSymbolName: current.activityIcon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        icon.contentTintColor = color

        // Rolling digits: spring-push the old number out when it changes.
        let d = (current.linesAdded, current.linesRemoved)
        if let old = shownDiff, old != d { diff.layer?.add(Self.roll(up: d.0 + d.1 > old.0 + old.1), forKey: "roll") }
        shownDiff = d
        diff.attributedStringValue = Self.diffText(d)
        diff.isHidden = d.0 + d.1 == 0

        timer.attributedStringValue = timerText(current)

        if let old = shownCount, old != active.count { count.layer?.add(Self.roll(up: active.count > old), forKey: "roll") }
        shownCount = active.count
        count.stringValue = "\(active.count)"
        count.textColor = lead.color

        pages.isHidden = active.count < 2 || model.hardwareNotch
        pages.set(count: active.count, index: index % active.count)

        layoutRow()
    }

    private func leadStatus(_ active: [T3Thread]) -> ThreadStatus {
        let order: [ThreadStatus] = [.pendingApproval, .awaitingInput, .guestRequest, .working, .connecting, .waiting]
        return order.first { s in active.contains { $0.status == s } } ?? .working
    }

    private func timerText(_ t: T3Thread) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        if t.status.isBusy, let start = t.startedAt {
            if t.status != .working {
                out.append(.init(string: t.status.label + " ", attributes: [.font: font, .foregroundColor: t.status.color]))
            }
            let s = max(0, Int(Date().timeIntervalSince(start)))
            let clock = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                                  : String(format: "%d:%02d", s / 60, s % 60)
            out.append(.init(string: clock, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.5)]))
        } else if t.status.needsYou {
            out.append(.init(string: t.status.label, attributes: [.font: font, .foregroundColor: t.status.color]))
        }
        return out
    }

    private static func diffText(_ d: (Int, Int)) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let out = NSMutableAttributedString(string: "+\(d.0)", attributes: [
            .font: font, .foregroundColor: Palette.added.withAlphaComponent(0.9)])
        out.append(.init(string: " −\(d.1)", attributes: [
            .font: font, .foregroundColor: Palette.removed.withAlphaComponent(0.9)]))
        return out
    }

    // MARK: Layout (manual frames: no constraint solving, no SwiftUI)

    private func layoutRow() {
        let h = bounds.height
        // +2: label insets; without it the last glyph truncates ("23:…").
        // Measure the text itself: a truncating label's intrinsic size follows its current frame.
        func fit(_ v: NSTextField) -> CGFloat {
            v.stringValue.isEmpty ? 0 : ceil(v.attributedStringValue.size().width) + 4
        }
        func place(_ v: NSView, x: CGFloat, w: CGFloat, vh: CGFloat) {
            // Labels need their natural line height, or AppKit truncates them vertically ("24:…").
            let height = (v as? NSTextField).map { ceil($0.intrinsicContentSize.height) } ?? vh
            v.frame = CGRect(x: x, y: ((h - height) / 2).rounded(), width: max(0, w), height: height)
        }

        // Padded from the shape's straight side (the top corners flare in by 6pt).
        let inset = model.sideInset(for: .activity)
        indicator.frame = CGRect(x: inset - 2, y: (h - 16) / 2, width: 22, height: 16) // dots are inset ~2pt in their box

        // Right edge: count, page dots, timer, diff (right to left).
        var right = bounds.width - inset
        let cw = fit(count); right -= cw; place(count, x: right, w: cw, vh: 17)
        if !pages.isHidden {
            right -= 6 + pages.width
            pages.frame = CGRect(x: right, y: (h - 4) / 2, width: pages.width, height: 4)
        }
        let tw = fit(timer)
        if tw > 0 { right -= 8 + tw; place(timer, x: right, w: tw, vh: 14) }
        // Next to a camera notch the diff goes in the left wing (after the title), so the right
        // wing has room for the activity.
        let dw = diff.isHidden ? 0 : fit(diff)
        if dw > 0, !model.hardwareNotch { right -= 8 + dw; place(diff, x: right, w: dw, vh: 14) }

        let left = inset + 28
        featured.frame = CGRect(x: left, y: 0, width: max(0, right - 8 - left), height: h)
        if model.hardwareNotch {
            // The camera sits in the middle: title in the left wing, activity in the right one.
            let wingEnd = (bounds.width - model.notchSize.width) / 2 - 4 - left
            let wingStart = (bounds.width + model.notchSize.width) / 2 + 8 - left
            let titleW = min(fit(title), wingEnd - (dw > 0 ? dw + 8 : 0))
            place(title, x: 0, w: titleW, vh: 15)
            if dw > 0 { place(diff, x: left + titleW + 8, w: dw, vh: 14) }
            let room = featured.frame.width - wingStart - 15
            icon.isHidden = room < 40
            activity.isHidden = room < 40
            place(icon, x: wingStart, w: 11, vh: 11)
            place(activity, x: wingStart + 15, w: room, vh: 14)
        } else {
            icon.isHidden = false
            activity.isHidden = false
            let room = featured.frame.width
            let titleW = min(fit(title), room * 0.55)
            place(title, x: 0, w: titleW, vh: 15)
            place(icon, x: titleW + 8, w: 11, vh: 11)
            place(activity, x: titleW + 23, w: room - titleW - 23, vh: 14)
        }
    }

    // MARK: Spring transitions (run in the window server)

    private static func slide() -> CATransition {
        let t = CATransition()
        t.type = .push
        t.subtype = .fromTop // flipped view: content comes up from below
        t.duration = NotchRootView.spring("position").settlingDuration * 0.6
        t.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.35, 1) // springy overshoot
        return t
    }

    private static func roll(up: Bool) -> CATransition {
        let t = CATransition()
        t.type = .push
        t.subtype = up ? .fromTop : .fromBottom
        t.duration = 0.35
        t.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.35, 1)
        return t
    }
}

// MARK: - Indicator + page dots

/// Status glyph: dots (working / connecting), breathing dot (needs you), an icon for the
/// rest, nothing for idle. Dots and pulse are Core Animation.
@MainActor
final class StatusIndicator: NSView {
    private let dots = LayerDots(dots: 3)
    private let pulse = LayerDots(dots: 1)
    private let icon = NSImageView()
    private var shown: (ThreadStatus, Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        [dots, pulse, icon].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        [dots, pulse, icon].forEach { $0.frame = bounds }
    }

    func show(_ status: ThreadStatus, small: Bool) {
        if let s = shown, s.0 == status, s.1 == small { return }
        shown = (status, small)
        let color = status.color
        dots.isHidden = !(status == .working || status == .connecting)
        pulse.isHidden = !(status.needsYou || status == .guestRequest)
        let symbol: String? = switch status {
        case .waiting: "hourglass"
        case .failed: "xmark.circle.fill"
        case .planReady: "list.bullet.clipboard.fill"
        case .completed: "checkmark.circle.fill"
        default: nil
        }
        icon.isHidden = symbol == nil
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.label)?
                .withSymbolConfiguration(.init(pointSize: small ? 11 : 12, weight: .semibold))
            icon.contentTintColor = color
        }
        dots.configure(color: status == .connecting ? color.withAlphaComponent(0.55) : color,
                       size: small ? 3.5 : 4.5, style: .wave)
        pulse.configure(color: color, size: 8, style: .pulse)
    }
}

/// "•• ▬ •" page indicator; the active capsule springs between positions.
final class PageDotsLayer: CALayer {
    private var capsules: [CALayer] = []
    private(set) var width: CGFloat = 0

    func set(count: Int, index: Int) {
        let n = min(count, 6)
        while capsules.count < n {
            let c = CALayer()
            c.cornerRadius = 2
            addSublayer(c)
            capsules.append(c)
        }
        while capsules.count > n { capsules.removeLast().removeFromSuperlayer() }
        var x: CGFloat = 0
        for (i, c) in capsules.enumerated() {
            let active = i == index % max(n, 1)
            let frame = CGRect(x: x, y: 0, width: active ? 8 : 4, height: 4)
            if c.frame != frame {
                let spring = NotchRootView.spring("bounds")
                spring.fromValue = NSValue(rect: c.presentation()?.bounds ?? c.bounds)
                spring.toValue = NSValue(rect: CGRect(origin: .zero, size: frame.size))
                c.add(spring, forKey: "bounds")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            c.frame = frame
            c.backgroundColor = NSColor.white.withAlphaComponent(active ? 0.9 : 0.3).cgColor
            CATransaction.commit()
            x += frame.width + 3
        }
        width = max(0, x - 3)
    }
}

final class LayerDots: NSView {
    enum Style { case wave, pulse }

    private let dots: [CALayer]
    private let halo = CALayer()
    private var config: (NSColor, CGFloat, Style)?

    init(dots count: Int) {
        dots = (0..<count).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(halo)
        dots.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(color: NSColor, size: CGFloat, style: Style) {
        if let c = config, c.0 == color, c.1 == size, c.2 == style { return } // SwiftUI calls this often
        config = (color, size, style)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots {
            dot.backgroundColor = color.cgColor
            dot.cornerRadius = size / 2
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        }
        halo.backgroundColor = color.withAlphaComponent(0.35).cgColor
        halo.cornerRadius = 8
        halo.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        halo.isHidden = style != .pulse
        CATransaction.commit()
        needsLayout = true
        restartAnimations()
    }

    override func layout() {
        super.layout()
        guard let (_, size, style) = config else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .wave:
            let gap = size * 0.6
            let total = size * 3 + gap * 2
            for (i, dot) in dots.enumerated() {
                dot.position = CGPoint(x: (bounds.width - total) / 2 + size / 2 + CGFloat(i) * (size + gap),
                                       y: bounds.midY - size * 0.4)
            }
        case .pulse:
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            halo.position = center
            dots.forEach { $0.position = center }
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartAnimations() // CA drops animations when a layer leaves its window
    }

    private func restartAnimations() {
        guard window != nil, let (_, size, style) = config else { return }
        switch style {
        case .wave:
            let period = 1.1
            for (i, dot) in dots.enumerated() {
                // Up-swing then rest, each dot a beat behind the previous one.
                let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
                lift.values = [0, size * 0.8, 0, 0]
                lift.keyTimes = [0, 0.25, 0.5, 1]
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.4, 1, 0.4, 0.4]
                fade.keyTimes = lift.keyTimes
                let group = CAAnimationGroup()
                group.animations = [lift, fade]
                group.duration = period
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                group.beginTime = CACurrentMediaTime() + Double(i) * period * 0.15
                group.fillMode = .backwards
                dot.opacity = 0.4
                dot.add(group, forKey: "wave")
            }
        case .pulse:
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.5
            breathe.toValue = 1
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(breathe, forKey: "pulse")
        }
    }
}
