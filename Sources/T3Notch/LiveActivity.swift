import AppKit
import Combine
import CryptoKit
import Network
import os

// The iPhone Live Activity, driven from here. The notch already knows every state change the
// moment it happens; this pushes it straight to Apple's push service (APNs), so the phone
// updates over the internet, wherever it is, with no server in between:
//
// - Pairing (once, same Wi-Fi): the phone sends its push-to-start token, checked with a 6-digit code.
// - One broadcast channel per Mac: the Live Activity is started remotely subscribed to it, and every
//   update goes to the channel, so the phone never has to report back.
// - Finishes and "needs you" go out at once (priority 10, with an alert); small changes (activity
//   text, +/−) at most every 15s at priority 5. Run timers count on the phone.
//
// Setup: an APNs auth key (.p8) from the developer account that signs the phone app, with
// "Broadcast Capability" on for its App ID (Certificates, IDs & Profiles).

private let log = Logger(subsystem: "dev.custom-dock.t3notch", category: "live")

// MARK: - Saved setup

struct LiveSetup: Codable {
    var keyId: String?
    /// The developer team that signs the phone app (and owns the push key). Asked for with the key.
    var teamId = ""
    var topic = LiveActivityProtocol.phoneBundleId
    /// Development-signed phone app: APNs sandbox.
    var sandbox = true
    var channelId: String?
    /// The channel keeps no messages (APNs' larger broadcast allowance). Older channels stored the latest.
    var channelNoStorage: Bool?
    var pushToStartToken: String?
    var deviceName: String?
    /// When the current Live Activity was started (iOS ends them after 8 hours).
    var startedAt: Date?

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/T3Notch", isDirectory: true)
    static let keyFile = folder.appendingPathComponent("apns-key.p8")
    private static let file = folder.appendingPathComponent("live-activity.json")

    static func load() -> LiveSetup {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LiveSetup.self, from: $0) } ?? LiveSetup()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        FileManager.default.createFile(atPath: Self.file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    var hasKey: Bool { keyId != nil && !teamId.isEmpty && FileManager.default.fileExists(atPath: Self.keyFile.path) }
    var paired: Bool { pushToStartToken != nil }
}

// MARK: - APNs

struct APNsError: LocalizedError {
    let status: Int
    let reason: String
    var retryAfter: TimeInterval?
    var errorDescription: String? { "APNs \(status): \(reason)" }
}

/// Token-based APNs: an ES256 JWT from the .p8 key (CryptoKit), refreshed every 50 minutes.
final class APNsClient {
    private let setup: LiveSetup
    private let key: P256.Signing.PrivateKey
    private var jwt: (token: String, at: Date)?

    init(setup: LiveSetup) throws {
        self.setup = setup
        let pem = try String(contentsOf: LiveSetup.keyFile, encoding: .utf8)
        key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    private func bearer() throws -> String {
        if let jwt, Date().timeIntervalSince(jwt.at) < 50 * 60 { return jwt.token }
        func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = b64(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": setup.keyId ?? ""]))
        let claims = b64(try JSONSerialization.data(withJSONObject: ["iss": setup.teamId, "iat": Int(Date().timeIntervalSince1970)]))
        let signature = try key.signature(for: Data("\(header).\(claims)".utf8))
        let token = "\(header).\(claims).\(b64(signature.rawRepresentation))"
        jwt = (token, Date())
        return token
    }

    private var pushHost: String { setup.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com" }
    private var channelHost: String {
        setup.sandbox ? "api-manage-broadcast.sandbox.push.apple.com:2195" : "api-manage-broadcast.push.apple.com:2195"
    }

    @discardableResult
    private func send(_ url: String, headers: [String: String], body: [String: Any]) async throws -> HTTPURLResponse {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("bearer \(try bearer())", forHTTPHeaderField: "authorization")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            throw APNsError(status: http.statusCode, reason: reason ?? String(data: data, encoding: .utf8) ?? "",
                            retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init))
        }
        return http
    }

    /// A broadcast channel for this app's Live Activities. No stored messages: APNs gives those
    /// channels more room, and every update carries the whole state anyway, so a phone that was
    /// offline catches up with the next one.
    func createChannel() async throws -> String {
        let response = try await send("https://\(channelHost)/1/apps/\(setup.topic)/channels", headers: [:],
                                      body: ["message-storage-policy": 0, "push-type": "LiveActivity"])
        guard let id = response.value(forHTTPHeaderField: "apns-channel-id") else {
            throw APNsError(status: response.statusCode, reason: "no channel id in the response")
        }
        return id
    }

    /// Starts the Live Activity on the phone, subscribed to `channel`.
    func start(token: String, channel: String, state: [String: Any], alert: [String: String]) async throws {
        try await send("https://\(pushHost)/3/device/\(token)",
                       headers: ["apns-push-type": "liveactivity", "apns-topic": "\(setup.topic).push-type.liveactivity",
                                 "apns-priority": "10"],
                       body: ["aps": ["timestamp": Int(Date().timeIntervalSince1970), "event": "start",
                                      "content-state": state, "attributes-type": "NotchActivityAttributes",
                                      "attributes": [String: Any](), "alert": alert, "input-push-channel": channel]])
    }

    /// An update (or the end) for every Live Activity subscribed to `channel`.
    func broadcast(channel: String, event: String, state: [String: Any], priority: Int,
                   alert: [String: String]? = nil, sound: String? = nil, dismissAt: Date? = nil) async throws {
        var aps: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970), "event": event, "content-state": state]
        // Live Activities take the sound inside the alert (not at the top level like other pushes);
        // a file name bundled in the phone app.
        if var alert {
            if let sound { alert["sound"] = sound }
            aps["alert"] = alert
        }
        if let dismissAt { aps["dismissal-date"] = Int(dismissAt.timeIntervalSince1970) }
        try await send("https://\(pushHost)/4/broadcasts/apps/\(setup.topic)",
                       headers: ["apns-push-type": "liveactivity", "apns-channel-id": channel, "apns-priority": "\(priority)",
                                 "apns-expiration": "0"], // required on channels; 0 = deliver now or never (no storage)
                       body: ["aps": aps])
    }
}

// MARK: - Pairing listener

/// Advertises on Bonjour while "Pair iPhone…" is open and accepts the phone whose code matches.
@MainActor
final class LivePairing {
    let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
    private var listener: NWListener?
    private let onPaired: (PairingRequest) -> Void

    init(onPaired: @escaping (PairingRequest) -> Void) {
        self.onPaired = onPaired
    }

    func start() throws {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: LiveActivityProtocol.bonjourType)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var reply = PairingReply(ok: false, macName: Host.current().localizedName, error: "Wrong code")
                if let data, let line = data.split(separator: 0x0A).first,
                   let request = try? JSONDecoder().decode(PairingRequest.self, from: Data(line)) {
                    if request.code == self.code, !request.pushToStartToken.isEmpty {
                        reply = PairingReply(ok: true, macName: Host.current().localizedName, error: nil)
                        self.onPaired(request)
                    }
                }
                var out = (try? JSONEncoder().encode(reply)) ?? Data()
                out.append(0x0A)
                connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

// MARK: - Mirror

@MainActor
final class LiveActivityMirror: ObservableObject {
    @Published private(set) var setup = LiveSetup.load()
    @Published private(set) var lastResult: String?
    private let store: ThreadStore
    private var client: APNsClient?
    private var cancellables: Set<AnyCancellable> = []
    private var lastSent: NotchActivityAttributes.ContentState?
    private var lastSentAt = Date.distantPast
    private var pending: DispatchWorkItem?
    private var pendingUrgent = false
    private var pendingAt = Date.distantPast
    private var endWork: DispatchWorkItem?
    private var event: LiveEvent?
    private var eventClear: DispatchWorkItem?
    private var sending = false
    private var resend = false
    /// No pushes before this (set a few seconds after T3 connects; never while it's offline).
    private var loadedAt = Date.distantFuture
    /// After APNs turns a push down: no pushes until then (10s, doubling to 5 min).
    private var backoffUntil = Date.distantPast
    private var backoff: TimeInterval = 0
    // APNs allows a channel about 4 updates a minute (reported on Apple's forums; undocumented),
    // and turns away the rest with 429. So: never closer than 15s, urgent or not.
    private static let minGap: TimeInterval = 15     // finishes, needs-you, status changes
    private static let batchGap: TimeInterval = 30   // activity text, +/−

    init(store: ThreadStore) {
        self.store = store
        makeClient()
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.storeChanged() }.store(in: &cancellables)
        // Right after (re)connecting the thread list is still filling in: hold pushes for a moment,
        // or the phone would get a "nothing running" flash.
        store.$connected.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] connected in
            guard let self else { return }
            self.loadedAt = connected ? Date().addingTimeInterval(3) : .distantFuture
            if connected { DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.storeChanged() } }
        }.store(in: &cancellables)
        store.$eventId.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] id in self?.eventChanged(id) }
            .store(in: &cancellables)
    }

    var ready: Bool { setup.hasKey && setup.paired }

    private func makeClient() {
        client = setup.hasKey ? try? APNsClient(setup: setup) : nil
    }

    // MARK: Setup

    /// Copies an APNs key (AuthKey_XXXXXXXXXX.p8) in, owner-only; the key id comes from its name.
    func installKey(from url: URL, teamId: String) throws {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("AuthKey_") else { throw APNsError(status: 0, reason: "Expected a file named AuthKey_<KEY ID>.p8") }
        let pem = try String(contentsOf: url, encoding: .utf8)
        _ = try P256.Signing.PrivateKey(pemRepresentation: pem) // fail now, not at the first push
        try FileManager.default.createDirectory(at: LiveSetup.folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: LiveSetup.keyFile.path, contents: Data(pem.utf8), attributes: [.posixPermissions: 0o600])
        setup.keyId = String(name.dropFirst("AuthKey_".count))
        setup.teamId = teamId
        setup.channelId = nil // a channel belongs to the key's team; make a fresh one
        setup.save()
        makeClient()
        storeChanged()
    }

    func paired(_ request: PairingRequest) {
        setup.pushToStartToken = request.pushToStartToken
        setup.deviceName = request.deviceName
        setup.startedAt = nil // start a fresh Live Activity on the new phone
        setup.save()
        lastSent = nil
        log.notice("paired with \(request.deviceName, privacy: .public)")
        storeChanged()
    }

    /// Ends whatever Live Activity the phone has (if any) and starts a fresh one. For when it's gone
    /// from the phone without the Mac knowing: swiped away, or ended by an update of the app.
    func restart() {
        Task {
            await end(now: true)
            setup.startedAt = nil
            setup.save()
            lastSent = nil
            lastSentAt = .distantPast
            storeChanged()
        }
    }

    func unpair() {
        Task { await end(now: true) }
        setup.pushToStartToken = nil
        setup.deviceName = nil
        setup.startedAt = nil
        setup.save()
    }

    // MARK: State → content

    private static func status(_ s: ThreadStatus) -> String {
        switch s {
        case .pendingApproval, .awaitingInput, .guestRequest: "needsYou"
        case .working: "working"
        case .connecting: "connecting"
        case .waiting: "waiting"
        case .failed: "failed"
        case .completed, .planReady: "done"
        case .idle: "idle"
        }
    }

    private static func clip(_ s: String?, _ n: Int) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    /// The event card goes as soon as it's old news: a finished thread that's working again, or a
    /// request that's been answered (here, in T3, or from another device).
    private func dropStaleEvent() {
        guard let e = event, let id = e.thread else { return }
        let thread = store.threads.first { $0.id == id }
        let stale = e.kind == "needsYou"
            ? !(thread?.status.needsYou ?? false) && thread?.status != .guestRequest
            : thread?.status.isBusy ?? false
        if stale {
            event = nil
            eventClear?.cancel()
        }
    }

    private func content() -> NotchActivityAttributes.ContentState {
        dropStaleEvent()
        let rank: (T3Thread) -> Int = { $0.status.needsYou || $0.status == .guestRequest ? 0 : $0.status == .working ? 1 : 2 }
        let active = store.active.sorted { rank($0) < rank($1) }
        let rows = active.prefix(4).map { t in
            LiveRow(id: t.id, title: Self.clip(t.title, 60) ?? "Thread", provider: t.provider,
                    status: Self.status(t.status), activity: Self.clip(t.activity, 70),
                    startedAt: t.status.isBusy ? t.startedAt?.timeIntervalSince1970.rounded() : nil,
                    added: t.linesAdded, removed: t.linesRemoved,
                    pr: t.pr?.label, checks: t.pr?.checks?.rawValue,
                    review: t.pr?.review == .reviewRequired ? nil : t.pr?.review?.rawValue)
        }
        var state = NotchActivityAttributes.ContentState(rows: Array(rows), working: store.busy.count,
                                                         needsYou: store.needsYou.count, event: event,
                                                         environmentId: store.currentEnvironmentId)
        // APNs caps a Live Activity push at 4 KB (the whole payload): shed detail until it fits.
        while Self.size(state) > 3_300 {
            if let i = state.rows.lastIndex(where: { $0.activity != nil }) { state.rows[i].activity = nil }
            else if state.rows.count > 1 { state.rows.removeLast() }
            else if state.event?.text != nil { state.event?.text = nil }
            else { break }
        }
        return state
    }

    private static func size(_ state: NotchActivityAttributes.ContentState) -> Int {
        (try? JSONEncoder().encode(state).count) ?? 0
    }

    private static func json(_ state: NotchActivityAttributes.ContentState) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(state),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    // MARK: Events (a finish, or something needs you)

    private func eventChanged(_ id: String?) {
        guard let id, let t = store.threads.first(where: { $0.id == id }) else { return }
        let kind = t.status.needsYou || t.status == .guestRequest ? "needsYou" : t.status == .failed ? "failed" : "done"
        let text = kind == "needsYou" ? (t.request.map { _ in t.activity } ?? t.activity) : (t.lastMessage ?? t.activity)
        event = LiveEvent(kind: kind, thread: t.id, title: Self.clip(t.title, 60) ?? "Thread", text: Self.clip(text, 140),
                          at: Date().timeIntervalSince1970.rounded())
        // Keep it on top for a few minutes, then let the rows have the space back.
        eventClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in self?.event = nil; self?.storeChanged() }
        eventClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == "needsYou" ? 600 : 120), execute: clear)
        lastSent = nil // force it through the scheduler as urgent
        storeChanged()
    }

    // MARK: Pushing

    private func storeChanged() {
        guard ready, Date() >= loadedAt else { return }
        let next = content()
        guard next != lastSent else { return }
        // Something that changes what you'd act on goes now; the rest is batched.
        let urgent = lastSent.map { old in
            old.working != next.working || old.needsYou != next.needsYou || old.event != next.event
                || old.rows.map { [$0.id, $0.status] } != next.rows.map { [$0.id, $0.status] }
        } ?? true
        // One timer at a time: an urgent change pulls the next push in, but never closer than
        // `minGap` to the last one (or before a back-off ends). Batched changes ride along.
        let since = Date().timeIntervalSince(lastSentAt)
        var wait = max(0, (urgent ? Self.minGap : Self.batchGap) - since)
        wait = max(wait, backoffUntil.timeIntervalSinceNow)
        let at = Date().addingTimeInterval(wait)
        if pending != nil, pendingAt <= at, pendingUrgent || !urgent { return } // one's already due sooner
        pending?.cancel()
        pendingUrgent = urgent
        pendingAt = at
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            Task { await self.push(urgent: urgent) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func push(urgent: Bool) async {
        guard ready, let client, let token = setup.pushToStartToken else { return }
        if sending { resend = true; return } // one at a time; the latest state goes next
        guard Date() >= backoffUntil else { storeChanged(); return }
        sending = true
        defer {
            sending = false
            if resend { resend = false; storeChanged() }
        }
        let state = content()
        let somethingToShow = !state.rows.isEmpty || state.event != nil
        do {
            if setup.channelId != nil, setup.channelNoStorage != true {
                // Move off an old storing channel: end its Live Activity, then start fresh on a new one.
                try? await client.broadcast(channel: setup.channelId!, event: "end", state: Self.json(state),
                                            priority: 10, dismissAt: Date())
                setup.channelId = nil
                setup.startedAt = nil
            }
            if setup.channelId == nil {
                setup.channelId = try await client.createChannel()
                setup.channelNoStorage = true
                setup.save()
                log.notice("created live activity channel")
            }
            let channel = setup.channelId!
            let expired = setup.startedAt.map { Date().timeIntervalSince($0) > 7.5 * 3600 } ?? true
            if somethingToShow {
                endWork?.cancel()
                endWork = nil
                if expired {
                    try await client.start(token: token, channel: channel, state: Self.json(state),
                                           alert: alert(for: state) ?? ["title": "T3 Code", "body": summary(state)])
                    setup.startedAt = Date()
                    setup.save()
                    result("Started on \(setup.deviceName ?? "iPhone")")
                } else {
                    let alert = urgent ? alert(for: state, changedFrom: lastSent) : nil
                    try await client.broadcast(channel: channel, event: "update", state: Self.json(state),
                                               priority: urgent ? 10 : 5, alert: alert,
                                               sound: alert == nil ? nil : Self.sound(for: state.event?.kind))
                    result("Updated")
                }
            } else if !expired {
                // Nothing running: show the empty state briefly, then end it.
                try await client.broadcast(channel: channel, event: "update", state: Self.json(state), priority: 5)
                scheduleEnd()
                result("Idle")
            }
            lastSent = state
            lastSentAt = Date()
            backoff = 0
        } catch {
            log.error("live activity push failed: \(error.localizedDescription, privacy: .public)")
            result(error.localizedDescription)
            // Don't hammer APNs (that's how a 429 happens): wait, longer each time, then send the latest.
            lastSentAt = Date()
            backoff = min(max(backoff * 2, 15, (error as? APNsError)?.retryAfter ?? 0), 300)
            backoffUntil = Date().addingTimeInterval(backoff)
            DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in self?.storeChanged() }
            if let e = error as? APNsError, e.reason == "BadChannelId" || e.status == 410 {
                setup.channelId = nil
                setup.save()
            }
        }
    }

    private func scheduleEnd() {
        guard endWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in Task { await self?.end(now: false) } }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    private func end(now: Bool) async {
        endWork = nil
        guard let client, let channel = setup.channelId, setup.startedAt != nil else { return }
        do {
            try await client.broadcast(channel: channel, event: "end", state: Self.json(content()), priority: 10,
                                       dismissAt: now ? Date() : Date().addingTimeInterval(60))
            setup.startedAt = nil
            setup.save()
            result("Ended")
        } catch {
            result(error.localizedDescription)
        }
    }

    /// The notch's own sounds, bundled in the phone app (Phone/App/Sounds): Hex's chime for a finish,
    /// the deep wood knocks for "needs you" and a failure.
    private static func sound(for kind: String?) -> String? {
        switch kind {
        case "done": "done.wav"
        case "needsYou": "needs-you.wav"
        case "failed": "failed.wav"
        default: nil
        }
    }

    private func summary(_ s: NotchActivityAttributes.ContentState) -> String {
        s.needsYou > 0 ? "\(s.needsYou) need\(s.needsYou == 1 ? "s" : "") you" : "\(s.working) working"
    }

    /// Light the phone up for a fresh finish or "needs you"; stay quiet otherwise.
    private func alert(for state: NotchActivityAttributes.ContentState,
                       changedFrom old: NotchActivityAttributes.ContentState? = nil) -> [String: String]? {
        guard let e = state.event, e != old?.event else { return nil }
        let verb = e.kind == "needsYou" ? "Needs you" : e.kind == "failed" ? "Failed" : "Done"
        return ["title": "\(verb): \(e.title)", "body": e.text ?? ""]
    }

    private func result(_ text: String) {
        log.notice("live activity: \(text, privacy: .public)")
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        lastResult = "\(text) · \(time)"
    }
}

// MARK: - Pairing window

/// The code, in a small floating window above everything (it doesn't need the app to come to the
/// front, which macOS often refuses a menu-bar app). Listens until paired or closed.
@MainActor
final class PairingWindow: NSObject, NSWindowDelegate {
    private let pairing: LivePairing
    private let panel: NSPanel
    private let message = NSTextField(wrappingLabelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Cancel", target: nil, action: nil)
    var onClose: () -> Void = {}

    init(onPaired: @escaping (PairingRequest) -> Void) {
        var done: ((PairingRequest) -> Void)?
        pairing = LivePairing { request in done?(request) }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 210),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        done = { [weak self] request in
            onPaired(request)
            self?.showPaired(request.deviceName)
        }
        panel.title = "Pair your iPhone"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        message.stringValue = "On the iPhone, open T3 Notch and enter this code. Both need to be on the same Wi-Fi, this once."
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        codeLabel.stringValue = "\(pairing.code.prefix(3)) \(pairing.code.suffix(3))"
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.isSelectable = true
        button.target = self
        button.action = #selector(closeWindow)
        button.bezelStyle = .rounded

        let stack = NSStackView(views: [message, codeLabel, button])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        message.preferredMaxLayoutWidth = 300
        panel.contentView = stack
    }

    func start() throws {
        try pairing.start()
        // Center it on the screen the pointer is on.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
    }

    private func showPaired(_ device: String) {
        pairing.stop()
        message.stringValue = "Paired with \(device). Your threads will show on its Lock Screen as soon as one is running."
        codeLabel.stringValue = "✓"
        codeLabel.textColor = .systemGreen
        button.title = "Done"
    }

    @objc private func closeWindow() { panel.close() }

    func windowWillClose(_ notification: Notification) {
        pairing.stop()
        onClose()
    }

    func close() { panel.close() }
}
