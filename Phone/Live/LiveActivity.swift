import ActivityKit
import SwiftUI
import WidgetKit

// The Live Activity: the notch on the Lock Screen (and the Dynamic Island, on phones that have one).
// Apple only renders Live Activities from SwiftUI, in its own process; this is the one place
// T3 Notch uses it. Content arrives as pushes from the Mac (see LiveActivityState.swift).

@main
struct T3NotchLiveBundle: WidgetBundle {
    var body: some Widget { NotchLiveActivity() }
}

struct NotchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NotchActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.leadURL)
        } dynamicIsland: { context in
            let state = context.state
            let lead = state.rows.first
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PixelLogo(provider: lead?.provider, status: lead?.status ?? "idle").frame(width: 22, height: 22)
                }
                DynamicIslandExpandedRegion(.trailing) { Counts(state: state) }
                DynamicIslandExpandedRegion(.center) {
                    Text(lead?.title ?? "T3 Code").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ForEach(state.rows.prefix(3), id: \.id) { RowView(row: $0) }
                    }
                }
            } compactLeading: {
                PixelLogo(provider: lead?.provider, status: lead?.status ?? "idle").frame(width: 16, height: 16)
            } compactTrailing: {
                Text("\(state.needsYou > 0 ? state.needsYou : state.working)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(state.needsYou > 0 ? Palette.amber : Palette.working)
            } minimal: {
                PixelLogo(provider: lead?.provider, status: lead?.status ?? "idle").frame(width: 16, height: 16)
            }
            .widgetURL(state.leadURL)
        }
        // The small layout: Apple Watch's Smart Stack and CarPlay.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Lock Screen

struct LockScreenView: View {
    let state: NotchActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            SmallView(state: state)
        } else {
            full
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("T3 Code").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Counts(state: state)
            }
            if let event = state.event { linked(EventView(event: event), thread: event.thread) }
            ForEach(state.rows.prefix(event == nil ? 3 : 2), id: \.id) { linked(RowView(row: $0), thread: $0.id) }
            if state.rows.isEmpty, state.event == nil {
                Text("Nothing running").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(14)
    }

    private var event: LiveEvent? { state.event }

    /// Each row (and the event) opens its own thread in T3 Code.
    @ViewBuilder
    private func linked(_ view: some View, thread: String?) -> some View {
        if let url = LiveActivityProtocol.openURL(environment: state.environmentId, thread: thread) {
            Link(destination: url) { view }
        } else {
            view
        }
    }
}

extension NotchActivityAttributes.ContentState {
    /// A tap anywhere else: the thread the activity is about (what just happened, else the top row).
    var leadURL: URL? {
        LiveActivityProtocol.openURL(environment: environmentId, thread: event?.thread ?? rows.first?.id)
    }
}

struct Counts: View {
    let state: NotchActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if state.needsYou > 0 {
                Label { Text("\(state.needsYou)").contentTransition(.numericText(value: Double(state.needsYou))) }
                    icon: { Image(systemName: "hand.raised.fill") }
                    .foregroundStyle(Palette.amber)
            }
            Label { Text("\(state.working)").contentTransition(.numericText(value: Double(state.working))) }
                icon: { Image(systemName: "bolt.fill") }
                .foregroundStyle(state.working > 0 ? Palette.working : .white.opacity(0.5))
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .labelStyle(TightLabel())
    }
}

/// What just happened: a run finished (or failed), or something needs you.
struct EventView: View {
    let event: LiveEvent

    var body: some View {
        let color = Palette.color(for: event.kind)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.kind == "needsYou" ? "hand.raised.fill"
                  : event.kind == "failed" ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let text = event.text {
                    Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct RowView: View {
    let row: LiveRow

    var body: some View {
        let color = Palette.color(for: row.status)
        HStack(spacing: 10) {
            PixelLogo(provider: row.provider, status: row.status).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let activity = row.activity {
                    Text(activity)
                        .font(activity.hasPrefix("$") ? .system(size: 11, design: .monospaced) : .system(size: 11))
                        .foregroundStyle(color.opacity(0.9))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if let start = row.startedAt, ["working", "waiting", "connecting"].contains(row.status) {
                    // The phone counts this itself: no push per second.
                    Text(timerInterval: Date(timeIntervalSince1970: start)...Date.distantFuture, countsDown: false)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52, alignment: .trailing)
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    Text(Palette.label(for: row.status))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                }
                HStack(spacing: 5) {
                    if let pr = row.pr { PRBadge(label: pr, checks: row.checks, review: row.review) }
                    if row.added + row.removed > 0 {
                        // Digits roll to their new value on each update, like the notch.
                        HStack(spacing: 3) {
                            Text("+\(row.added)").foregroundStyle(Palette.added)
                                .contentTransition(.numericText(value: Double(row.added)))
                            Text("−\(row.removed)").foregroundStyle(Palette.removed)
                                .contentTransition(.numericText(value: Double(row.removed)))
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                }
            }
        }
    }
}

/// "#212 ●": the pull request and its CI checks (red failing, yellow pending, green passing), plus a
/// review mark when one decided something.
struct PRBadge: View {
    let label: String
    let checks: String?
    let review: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 9, weight: .bold))
            Text(label)
            if let checks {
                Circle().fill(checks == "failing" ? Palette.failed : checks == "pending" ? Palette.amber : Palette.done)
                    .frame(width: 6, height: 6)
            }
            if review == "approved" {
                Image(systemName: "hand.thumbsup.fill").font(.system(size: 9)).foregroundStyle(Palette.done)
            } else if review == "changes-requested" {
                Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
    }
}

/// Apple Watch Smart Stack and CarPlay: the one thing that matters most, big and simple.
struct SmallView: View {
    let state: NotchActivityAttributes.ContentState

    var body: some View {
        let lead = state.rows.first
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PixelLogo(provider: lead?.provider, status: lead?.status ?? "idle").frame(width: 14, height: 14)
                Text(state.needsYou > 0 ? "Needs you" : state.working > 0 ? "\(state.working) working" : "T3 Code")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(state.needsYou > 0 ? Palette.amber : Palette.working)
                    .contentTransition(.numericText(value: Double(state.working)))
                Spacer(minLength: 0)
            }
            if let event = state.event {
                Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(Palette.label(for: event.kind)).font(.system(size: 11)).foregroundStyle(Palette.color(for: event.kind))
            } else if let lead {
                Text(lead.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let start = lead.startedAt, ["working", "waiting", "connecting"].contains(lead.status) {
                    Text(timerInterval: Date(timeIntervalSince1970: start)...Date.distantFuture, countsDown: false)
                        .font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                } else {
                    Text(Palette.label(for: lead.status)).font(.system(size: 11)).foregroundStyle(Palette.color(for: lead.status))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
    }
}

/// The provider's pixel logo, in its brand color (the drawings are shared with the Mac notch).
/// Live Activities can't run continuous animations, so it's still here; idle and done dim it.
struct PixelLogo: View {
    let provider: String?
    let status: String

    var body: some View {
        let art = provider.flatMap { PixelArtData.arts[$0] }
        let rows = art?.rows ?? PixelArtData.fallbackRows
        let color = art.map { Palette.rgb($0.rgb) } ?? Palette.working
        Canvas { context, size in
            let n = CGFloat(rows.count)
            let pitch = min(size.width, size.height) / n
            let dot = pitch * 0.75
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    let rect = CGRect(x: CGFloat(x) * pitch + (pitch - dot) / 2, y: CGFloat(y) * pitch + (pitch - dot) / 2,
                                      width: dot, height: dot)
                    context.fill(Path(roundedRect: rect, cornerRadius: dot * 0.24), with: .color(color))
                }
            }
        }
        .opacity(["idle", "done"].contains(status) ? 0.6 : 1)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

/// The notch's status colors (T3's pill colors).
enum Palette {
    static let working = Color(red: 0.49, green: 0.83, blue: 0.99)
    static let amber = Color(red: 0.99, green: 0.83, blue: 0.30)
    static let failed = Color(red: 0.99, green: 0.65, blue: 0.65)
    static let done = Color(red: 0.43, green: 0.91, blue: 0.72)
    static let added = Color(red: 0.43, green: 0.91, blue: 0.62)
    static let removed = Color(red: 0.99, green: 0.55, blue: 0.55)

    static func rgb(_ v: UInt32) -> Color {
        Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func color(for status: String) -> Color {
        switch status {
        case "working", "connecting": working
        case "needsYou": amber
        case "failed": failed
        case "done": done
        default: .white.opacity(0.5)
        }
    }

    static func label(for status: String) -> String {
        switch status {
        case "needsYou": "Needs you"
        case "failed": "Failed"
        case "done": "Done"
        case "waiting": "Waiting"
        case "connecting": "Connecting"
        case "working": "Working"
        default: ""
        }
    }
}
