import AppKit
import Combine

/// Notch silhouette: flush with the top of the screen, flaring outward at the top corners
/// and rounded at the bottom, the same trick the hardware notch / Dynamic Island apps use.
enum NotchShape {
    static func path(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat, offsetX: CGFloat = 0) -> CGPath {
        let w = size.width, h = size.height
        let t = topRadius, b = min(bottomRadius, (h - t) / 2)
        let p = CGMutablePath()
        let x = offsetX
        p.move(to: CGPoint(x: x, y: 0))
        p.addQuadCurve(to: CGPoint(x: x + t, y: t), control: CGPoint(x: x + t, y: 0))
        p.addLine(to: CGPoint(x: x + t, y: h - b))
        p.addQuadCurve(to: CGPoint(x: x + t + b, y: h), control: CGPoint(x: x + t, y: h))
        p.addLine(to: CGPoint(x: x + w - t - b, y: h))
        p.addQuadCurve(to: CGPoint(x: x + w - t, y: h - b), control: CGPoint(x: x + w - t, y: h))
        p.addLine(to: CGPoint(x: x + w - t, y: t))
        p.addQuadCurve(to: CGPoint(x: x + w, y: 0), control: CGPoint(x: x + w - t, y: 0))
        p.closeSubpath()
        return p
    }
}

/// T3's pill colors (Tailwind 300-ish shades used in its dark sidebar); Working follows the theme.
extension ThreadStatus {
    var color: NSColor {
        switch self {
        case .pendingApproval: NSColor(red: 0.99, green: 0.83, blue: 0.30, alpha: 1) // amber
        case .awaitingInput: NSColor(red: 0.65, green: 0.71, blue: 0.99, alpha: 1)   // indigo
        case .guestRequest: NSColor(red: 0.94, green: 0.67, blue: 0.99, alpha: 1)    // fuchsia
        case .working, .connecting: Theme.current.working                            // sky, or the theme's accent
        case .waiting, .idle: NSColor.white.withAlphaComponent(0.5)                  // muted
        case .failed: NSColor(red: 0.99, green: 0.65, blue: 0.65, alpha: 1)          // red
        case .planReady: NSColor(red: 0.77, green: 0.71, blue: 0.99, alpha: 1)       // violet
        case .completed: NSColor(red: 0.43, green: 0.91, blue: 0.72, alpha: 1)       // emerald
        }
    }
}

enum Palette {
    static let added = NSColor(red: 0.43, green: 0.91, blue: 0.62, alpha: 1)
    static let removed = NSColor(red: 0.99, green: 0.55, blue: 0.55, alpha: 1)
}

enum NotchMode: Equatable { case idle, activity, peek, expanded }

@MainActor
final class NotchModel: ObservableObject {
    @Published var hovering = false
    /// Opened with the keyboard shortcut: arrows / Enter / A / D / R work, panel holds focus.
    @Published var keyboard = false
    @Published var selection: String?
    /// Thread whose reply field is open, and what's typed in it.
    @Published var replyingTo: String?
    /// Row under the cursor, computed from the mouse position (tracking areas miss
    /// enter/exit in a non-activating panel, which left highlights stuck on the wrong row).
    @Published var hoveredRow: String?
    @Published var draft = ""

    /// Needs keyboard focus (and must not collapse when the cursor wanders off).
    var focused: Bool { keyboard || replyingTo != nil }
    let notchSize: CGSize
    /// Real camera notch: nothing can be drawn in the middle of the bar.
    let hardwareNotch: Bool
    let store: ThreadStore
    var onSettings: () -> Void = {}

    static let expandedWidth: CGFloat = 540
    static let rowHeight: CGFloat = 70
    static let compactRowHeight: CGFloat = 52
    static let actionBarHeight: CGFloat = 40 // approve / answer buttons under a waiting row
    static let replyHeight: CGFloat = 44
    static let hintsHeight: CGFloat = 24
    static let wing: CGFloat = 190 // side area next to the hardware notch in activity mode

    init(notchSize: CGSize, hardwareNotch: Bool, store: ThreadStore) {
        self.notchSize = notchSize
        self.hardwareNotch = hardwareNotch
        self.store = store
    }

    var mode: NotchMode {
        if focused { return .expanded }
        // A "needs you" card stays put (and clickable) even under the cursor.
        if store.stickyEvent != nil { return .peek }
        if hovering { return .expanded }
        if store.event != nil { return .peek }
        if !store.active.isEmpty { return .activity }
        return .idle
    }

    var size: CGSize {
        switch mode {
        case .idle:
            return notchSize
        case .activity:
            // One row: [indicator] [thread] [count], flush with the menu bar.
            let width = hardwareNotch ? notchSize.width + Self.wing * 2 : 540
            return .init(width: width, height: notchSize.height)
        case .peek:
            guard let event = store.event else { return notchSize }
            if event.status.needsYou {
                let w = max(notchSize.width + 300, 500)
                return .init(width: w, height: Layout.card(event, width: w, top: notchSize.height, inset: sideInset(for: .peek),
                                                           error: store.failed[event.id] != nil).height)
            }
            let w = max(notchSize.width + 240, 440)
            return .init(width: w, height: Layout.finished(event, width: w, top: notchSize.height, inset: sideInset(for: .peek)).height)
        case .expanded:
            let rows = store.threads.reduce(CGFloat(0)) { $0 + slotHeight($1) }
            return .init(width: Self.expandedWidth,
                         height: notchSize.height + 8 + max(rows, Self.rowHeight) + 18
                             + (keyboard ? Self.hintsHeight : 0))
        }
    }

    static let outputHeight: CGFloat = 70

    /// Row whose running command is being peeked at: hovered, or selected via keyboard.
    var peekRow: String? {
        guard mode == .expanded else { return nil }
        return hoveredRow ?? (keyboard ? selectedThread?.id : nil)
    }

    func showsOutput(_ t: T3Thread) -> Bool {
        peekRow == t.id && t.runningCommandId != nil && !(store.commandOutput[t.id] ?? []).isEmpty
    }

    /// Height of a thread row itself (the reply field is a separate view below it).
    func rowHeight(_ t: T3Thread) -> CGFloat {
        // Two lines (title, meta) unless there's an activity line to show.
        (t.activity == nil && !t.usageLimited ? Self.compactRowHeight : Self.rowHeight)
            + (t.request != nil ? Self.actionBarHeight : 0)
            + (showsOutput(t) ? Self.outputHeight : 0)
    }

    func slotHeight(_ t: T3Thread) -> CGFloat {
        rowHeight(t) + (replyingTo == t.id ? Self.replyHeight : 0)
    }

    /// Thread row at `y` points below the top of the notch (expanded layout).
    func rowId(atY y: CGFloat) -> String? {
        guard mode == .expanded else { return nil }
        var top = notchSize.height + 8
        for t in store.threads {
            let h = slotHeight(t)
            if y >= top && y < top + h { return t.id }
            top += h
        }
        return nil
    }

    /// Everything the collapsed notch draws. While collapsed, store changes that leave this
    /// equal (tool counts, idle rows, timestamps) skip the redraw entirely.
    var renderKey: [AnyHashable] {
        var key: [AnyHashable] = [mode, store.connected, store.incompatible, store.eventId]
        guard mode == .activity || mode == .idle else { return key + [UUID()] } // always redraw
        for t in store.active {
            key += [t.id, t.title, t.status, t.activity, t.activityIcon, t.linesAdded, t.linesRemoved, t.startedAt]
        }
        return key
    }

    // MARK: Keyboard navigation

    var selectedThread: T3Thread? {
        store.threads.first { $0.id == selection } ?? store.threads.first
    }

    func moveSelection(_ delta: Int) {
        let ids = store.threads.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? 0
        selection = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    func startReply(_ thread: T3Thread) {
        if replyingTo != thread.id { draft = "" }
        selection = thread.id
        replyingTo = thread.id
    }

    func sendReply() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = replyingTo, let thread = store.threads.first(where: { $0.id == id }), !text.isEmpty else { return }
        store.reply(thread, text)
        draft = ""
        replyingTo = nil
    }

    /// Padding from the shape's straight side: the top corners flare outward by `topRadius`,
    /// so content padded from the frame looked glued to the black edge.
    static let edgePadding: CGFloat = 16
    func sideInset(for mode: NotchMode) -> CGFloat {
        (mode == .idle || mode == .activity ? 6 : 14) + (mode == .activity ? 10 : Self.edgePadding)
    }

    var topRadius: CGFloat { mode == .idle || mode == .activity ? 6 : 14 }
    var bottomRadius: CGFloat { mode == .expanded ? 28 : mode == .peek ? 22 : 12 }
}

/// Content-driven heights for the cards, shared by the model (notch size) and the views
/// (layout), so the shape always matches what's drawn.
enum Layout {
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 12)
    static let smallFont = NSFont.systemFont(ofSize: 11)
    static let headerFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static func lineHeight(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }

    /// Wrapped height of `text` in `width`, capped at `maxLines`.
    static func textHeight(_ text: String, _ font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let r = (text as NSString).boundingRect(with: CGSize(width: width - 4, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: font])
        return min(ceil(r.height), lineHeight(font) * CGFloat(maxLines)) + 2
    }

    struct Card {
        var height: CGFloat = 0
        var reason: CGFloat = 0, header: CGFloat = 0, body: CGFloat = 0, code: CGFloat = 0
        var actionsY: CGFloat = 0
    }

    /// Approval / question card: header row, detail, buttons.
    static func card(_ t: T3Thread, width: CGFloat, top: CGFloat, inset: CGFloat, error: Bool = false) -> Card {
        var c = Card()
        let inner = width - inset * 2
        var y = top + 10 + 22 + 10 // title row
        switch t.request?.kind {
        case .approval(let prompt, let why, _)?:
            if let why { c.reason = textHeight(why, smallFont, width: inner, maxLines: 1); y += c.reason + 6 }
            if let prompt { c.code = textHeight(prompt, codeFont, width: inner - 16, maxLines: 3) + 16; y += c.code + 10 }
        case .questions(let qs)?:
            if let q = qs.first {
                if !q.header.isEmpty { c.header = lineHeight(headerFont); y += c.header + 3 }
                c.body = textHeight(questionText(qs), bodyFont, width: inner, maxLines: 3); y += c.body + 10
            }
        case nil:
            c.body = textHeight(t.activity ?? "Waiting for your input", bodyFont, width: inner, maxLines: 3); y += c.body + 10
        }
        c.actionsY = y
        c.height = y + 26 + (error ? 18 : 0) + 16 // buttons, the error line only if there is one, padding
        return c
    }

    static func questionText(_ qs: [Question]) -> String {
        guard let q = qs.first else { return "" }
        return q.text + (qs.count > 1 ? "\n+\(qs.count - 1) more question\(qs.count > 2 ? "s" : "")" : "")
    }

    /// Finished pop-up: title row, then up to 3 lines of the final message.
    static func finished(_ t: T3Thread, width: CGFloat, top: CGFloat, inset: CGFloat) -> (height: CGFloat, message: CGFloat) {
        let message = textHeight(finishedText(t), bodyFont, width: width - inset * 2 - 28, maxLines: 3)
        return (top + 10 + 20 + 4 + message + 16, message)
    }

    static func finishedText(_ t: T3Thread) -> String { t.lastMessage ?? t.activity ?? "Done" }
}
