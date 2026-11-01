import Foundation

// The iPhone Live Activity's content, shared by the Mac (which pushes it as JSON through Apple's
// push service) and the iPhone (which decodes it). Phone/project.yml compiles this file too.
// Keep it small: a Live Activity push payload is capped at 4 KB.

/// The Live Activity's attributes. Nothing static: everything lives in the content state.
struct NotchActivityAttributes: Codable, Hashable {
    struct ContentState: Codable, Hashable {
        /// Up to four threads, most urgent first.
        var rows: [LiveRow]
        var working: Int
        var needsYou: Int
        /// What just happened (a run finished, or something needs you), shown on top for a while.
        var event: LiveEvent?
        /// T3's environment id, for opening a thread in T3 Code (t3code://threads/<env>/<thread>).
        var environmentId: String?
    }
}

struct LiveRow: Codable, Hashable {
    /// The thread's id (opens it in T3 Code).
    var id: String
    var title: String
    /// T3's provider id ("claudeAgent", "codex", …), for the pixel logo.
    var provider: String?
    /// "working", "waiting", "connecting", "needsYou", "done", "failed", "idle".
    var status: String
    var activity: String?
    /// Unix seconds the run started (the phone counts the timer itself; no push per second).
    var startedAt: Double?
    var added: Int
    var removed: Int
    /// Pull request label ("#212", "#208 draft") and its CI checks ("passing", "failing", "pending").
    var pr: String?
    var checks: String?
    /// "approved" or "changes-requested", when a review decided something.
    var review: String?
}

struct LiveEvent: Codable, Hashable {
    /// "done", "failed" or "needsYou".
    var kind: String
    var thread: String?
    var title: String
    var text: String?
    /// Unix seconds.
    var at: Double
}

/// The pairing handshake over the local network (newline-terminated JSON).
struct PairingRequest: Codable {
    var code: String
    var pushToStartToken: String
    var deviceName: String
}

struct PairingReply: Codable {
    var ok: Bool
    var macName: String?
    var error: String?
}

enum LiveActivityProtocol {
    /// Tapping the Live Activity: the thread in T3 Code, linked directly. If iOS hands the tap to the
    /// T3 Notch app instead, it forwards the link (and tries T3's preview / dev builds too).
    static func openURL(environment: String?, thread: String?) -> URL? {
        guard let environment, let thread else { return nil }
        return URL(string: "t3code://threads/\(environment)/\(thread)")
    }

    /// Bonjour service the Mac advertises while "Pair iPhone…" is open.
    static let bonjourType = "_t3notch._tcp"
    static let phoneBundleId = "dev.custom-dock.t3notch.phone"
}
