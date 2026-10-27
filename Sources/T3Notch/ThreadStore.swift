import AppKit
import Foundation
import os
import SQLite3

private let log = Logger(subsystem: "dev.custom-dock.t3notch", category: "threads")

/// Mirrors T3 Code's sidebar status pill (`resolveThreadStatusPill` in apps/web
/// Sidebar.logic.ts), same names, same priority order.
enum ThreadStatus: Equatable, Sendable {
    case pendingApproval, awaitingInput, guestRequest, working, connecting, waiting, failed, planReady, completed
    /// No pill in T3: finished and already seen, stopped, or never run.
    case idle

    var label: String {
        switch self {
        case .pendingApproval: "Pending Approval"
        case .awaitingInput: "Awaiting Input"
        case .guestRequest: "Guest Request"
        case .working: "Working"
        case .connecting: "Connecting"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .planReady: "Plan Ready"
        case .completed: "Completed"
        case .idle: ""
        }
    }

    /// Blocked on the user.
    var needsYou: Bool { self == .pendingApproval || self == .awaitingInput }
    /// A run is actually in flight (stop / steer apply).
    var isBusy: Bool { self == .working || self == .connecting || self == .waiting }
    /// Shows up in the collapsed live ticker.
    var isActive: Bool { needsYou || isBusy || self == .guestRequest }
}

struct T3Thread: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let status: ThreadStatus
    var startedAt: Date?
    let updatedAt: Date
    var runId: String?
    var model: String?
    /// Provider driver ("claudeAgent", "codex", "cursor"…) for the logo next to the model.
    var provider: String?
    var branch: String?
    var pullRequest: String?
    /// What the agent is doing right now (running) or the last thing it said (finished).
    var activity: String?
    var activityIcon = "text.bubble"
    /// Latest assistant message, used for the "just finished" peek.
    var lastMessage: String?
    var filesChanged = 0
    var toolCalls = 0
    /// The approval / question the agent is blocked on, when it's waiting for you.
    var request: PendingRequest?
    /// Lines added / removed by the latest run (checkpoint, or live file edits while it runs).
    var linesAdded = 0
    var linesRemoved = 0
    var pr: PullRequestInfo?
    /// Set when the provider's usage limit stopped the thread.
    var usageLimitResetAt: Date?
    var usageLimited = false
    /// `command_execution` item still running, for the live output peek.
    var runningCommandId: String?
}

struct PullRequestInfo: Equatable, Sendable {
    enum Checks: String, Sendable { case passing, failing, pending }
    enum Review: String, Sendable { case approved, changesRequested = "changes-requested", reviewRequired = "review-required" }
    let number: Int
    let url: String
    let state: String // open | closed | merged
    let isDraft: Bool
    let checks: Checks?
    let review: Review?
    let conflicting: Bool

    var label: String { "#\(number)" + (isDraft ? " draft" : state == "open" ? "" : " \(state)") }
}

struct ApprovalOption: Equatable, Sendable {
    let decision, label: String
    let warning: String?
    var isAccept: Bool { decision.hasPrefix("accept") }
}

struct QuestionOption: Equatable, Sendable {
    let label, value: String
    let description: String?
}

struct Question: Equatable, Sendable {
    let id, header, text: String
    let options: [QuestionOption]
    let multiSelect: Bool
}

struct PendingRequest: Equatable {
    enum Kind: Equatable {
        case approval(prompt: String?, reason: String?, options: [ApprovalOption])
        case questions([Question])
    }
    let id: String
    let kind: Kind

    /// One single-choice question is answerable with one tap; anything richer goes to T3 Code.
    var quickQuestion: Question? {
        guard case .questions(let qs) = kind, qs.count == 1, let q = qs.first,
              !q.multiSelect, !q.options.isEmpty else { return nil }
        return q
    }
}

/// Live view of T3 Code threads, streamed from the local T3 server over its WebSocket RPC.
///
/// - `orchestration.subscribeShell` gives every thread's status (cheap, no message bodies).
/// - `orchestration.subscribeThread` is opened only for the visible threads, for their
///   turn items (current command / file edit / last message).
@MainActor
final class ThreadStore: ObservableObject {
    @Published private(set) var threads: [T3Thread] = []
    /// Id of a thread that just changed into an interesting state; drives the "peek".
    @Published private(set) var eventId: String?
    @Published private(set) var connected = false
    /// Threads with a command in flight (button spinners) and ones whose last command failed.
    @Published private(set) var sending: Set<String> = []
    @Published private(set) var failed: [String: String] = [:]
    /// Last few lines of the command being peeked at (hovered / selected running row).
    @Published private(set) var commandOutput: [String: [String]] = [:]
    /// Set when the server speaks a protocol this build doesn't (shown instead of threads).
    @Published private(set) var incompatible: String?

    var busy: [T3Thread] { threads.filter { $0.status.isBusy } }
    var needsYou: [T3Thread] { threads.filter { $0.status.needsYou } }
    var active: [T3Thread] { threads.filter { $0.status.isActive } }
    var event: T3Thread? { eventId.flatMap { id in threads.first { $0.id == id } } }
    /// The "needs you" card stays up (and stays interactive) until it's answered or dismissed.
    var stickyEvent: T3Thread? { event.flatMap { $0.status.needsYou ? $0 : nil } }

    static let visibleCount = 6

    // Shell state
    private var shell: [String: ShellThread] = [:]
    private var projects: [String: String] = [:]
    private var lastPhases: [String: RunPhase] = [:]
    private var lastPRs: [String: PullRequestInfo] = [:]
    private var limitChimed: Set<String> = []
    private var commandOutputStreaming = false
    private var outputWatch: (threadId: String, itemId: String, requestId: String)?
    private var outputText = ""
    /// Streamed file edits come without their patch; look each up once for live +/- counts.
    private var fetchedEdits: Set<String> = []
    private var recomputeScheduled = false
    private var eventClearTask: Task<Void, Never>?

    // Per-thread detail (only for visible threads)
    private var details: [String: [String: TurnItem]] = [:]
    private var threadRequests: [String: String] = [:] // threadId -> requestId
    private var requestThreads: [String: String] = [:] // requestId -> threadId
    private var commandThreads: [String: String] = [:] // requestId -> threadId (dispatchCommand)

    // Connection
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var nextRequestId = 1
    private var shellRequestId = ""
    private var environmentId: String?
    private var pingTimer: Timer?
    private var retryDelay: TimeInterval = 1
    private let auth = TokenStore()

    func start() {
        connect()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLimitResets() }
        }
    }

    // MARK: Opening threads

    func open(_ thread: T3Thread) {
        if let env = environmentId, let url = URL(string: "t3code://threads/\(env)/\(thread.id)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    // MARK: Actions (need the orchestration:operate scope)

    func approve(_ thread: T3Thread, _ option: ApprovalOption) {
        guard let request = thread.request else { return }
        dispatch(thread, ["type": "runtime-request.respond", "threadId": thread.id,
                          "requestId": request.id, "decision": option.decision])
    }

    func answer(_ thread: T3Thread, _ question: Question, _ option: QuestionOption) {
        guard let request = thread.request else { return }
        dispatch(thread, ["type": "runtime-request.respond", "threadId": thread.id,
                          "requestId": request.id, "answers": [question.id: option.value]])
    }

    func stop(_ thread: T3Thread) {
        guard let runId = thread.runId else { return }
        // holdQueue: same as T3's own stop button; queued follow-ups wait instead of starting.
        dispatch(thread, ["type": "run.interrupt", "threadId": thread.id, "runId": runId, "holdQueue": true])
    }

    /// Follow-up message. `deliveryIntent: auto` lets the server pick: steer the live run,
    /// queue behind it, or start a new run, the same way T3's composer does.
    func reply(_ thread: T3Thread, _ text: String) {
        dispatch(thread, ["type": "message.dispatch", "createdBy": "user", "creationSource": "web",
                          "threadId": thread.id, "messageId": UUID().uuidString.lowercased(),
                          "text": text, "attachments": [] as [Any],
                          "deliveryIntent": "auto", "dispatchMode": ["type": "start_immediately"]])
    }

    func dismissEvent() {
        eventClearTask?.cancel()
        eventId = nil
    }

    private func dispatch(_ thread: T3Thread, _ command: [String: Any]) {
        guard socket != nil else { failed[thread.id] = "Not connected to T3 Code"; return }
        var command = command
        command["commandId"] = "t3notch:\(UUID().uuidString.lowercased())"
        failed[thread.id] = nil
        sending.insert(thread.id)
        let requestId = send(tag: "orchestration.dispatchCommand", payload: command)
        commandThreads[requestId] = thread.id
    }

    // MARK: Connection

    private func connect() {
        generation += 1
        let gen = generation
        Task {
            do {
                guard let origin = Self.serverOrigin() else { throw ConnectError.serverDown }
                // Re-read every time: a restarted server may be on a new port (or a new install).
                if let env = await Self.fetchEnvironment(origin) {
                    environmentId = env.id ?? environmentId
                    commandOutputStreaming = env.commandOutputStreaming
                    if let v = env.protocolVersion, v != Self.protocolVersion {
                        incompatible = "T3 Code \(env.serverVersion ?? "") speaks protocol \(v); T3 Notch speaks \(Self.protocolVersion)"
                        throw ConnectError.incompatible
                    }
                    incompatible = nil
                }
                guard let token = try await auth.token() else { throw ConnectError.noToken }
                guard gen == generation else { return }
                open(origin: origin, token: token, gen: gen)
            } catch {
                scheduleReconnect(gen)
            }
        }
    }

    private func open(origin: URL, token: String, gen: Int) {
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        comps.scheme = origin.scheme == "https" ? "wss" : "ws"
        comps.path = "/ws"
        comps.queryItems = [.init(name: "orchestrationProtocol", value: String(Self.protocolVersion))]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024 // thread snapshots can be large
        socket = task
        threadRequests = [:]
        requestThreads = [:]
        fetchedEdits = [] // fresh snapshots drop fetched counts; fetch again
        task.resume()

        shellRequestId = send(tag: "orchestration.subscribeShell", payload: [:])
        receive(task, gen: gen)

        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendRaw(["_tag": "Ping"]) }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                // Parse off the main thread; snapshots can be hundreds of KB.
                let data: Data? = switch message {
                case .string(let s): s.data(using: .utf8)
                case .data(let d): d
                @unknown default: nil
                }
                if let size = data?.count, size > 200_000 { log.notice("large message: \(size) bytes") }
                let incoming = data.flatMap(Incoming.parse)
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    if !self.connected { self.connected = true; self.retryDelay = 1 }
                    if let incoming { self.handle(incoming) }
                    self.receive(task, gen: gen)
                }
            case .failure:
                let status = (task.response as? HTTPURLResponse)?.statusCode
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    if status == 401 || status == 403 { self.auth.discard() }
                    if status == 426 { // orchestration_protocol_incompatible
                        self.incompatible = "T3 Code needs a newer orchestration protocol than \(Self.protocolVersion)"
                    }
                    self.scheduleReconnect(gen)
                }
            }
        }
    }

    private func scheduleReconnect(_ gen: Int) {
        guard gen == generation else { return }
        connected = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pingTimer?.invalidate()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        // Don't leave "running" threads on screen if T3 Code went away for good;
        // short blips (server restart, sleep/wake) reconnect before this fires.
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard !connected else { return }
            threads = []
            dismissEvent()
            sending = []
        }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard gen == generation else { return }
            connect()
        }
    }

    @discardableResult
    private func send(tag: String, payload: [String: Any]) -> String {
        let id = String(nextRequestId)
        nextRequestId += 1
        sendRaw(["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] as [Any]])
        return id
    }

    private func sendRaw(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Incoming

    private func handle(_ incoming: Incoming) {
        switch incoming {
        case .chunk(let requestId, let values):
            sendRaw(["_tag": "Ack", "requestId": requestId]) // flow control: server waits for this
            if requestId == shellRequestId {
                values.compactMap(\.shell).forEach(apply)
                scheduleRecompute()
            } else if let threadId = requestThreads[requestId] {
                values.compactMap(\.thread).forEach { apply($0, to: threadId) }
                scheduleRecompute()
            } else if let watch = outputWatch, watch.requestId == requestId {
                for frame in values.compactMap(\.output) {
                    outputText = frame.replace ? frame.text : outputText + frame.text
                    if outputText.count > 8000 { outputText = String(outputText.suffix(4000)) }
                }
                commandOutput[watch.threadId] = Self.tailLines(outputText, 4)
            }
        case .exit(let requestId, let ok, let message):
            if outputWatch?.requestId == requestId { outputWatch = nil } // command finished
            if let threadId = commandThreads.removeValue(forKey: requestId) {
                sending.remove(threadId)
                if !ok { failed[threadId] = message ?? "T3 Code rejected that" }
            } else if requestId == shellRequestId {
                scheduleReconnect(generation) // shell stream should never end
            } else if let threadId = requestThreads.removeValue(forKey: requestId) {
                threadRequests[threadId] = nil
            }
        case .ignored:
            break
        }
    }

    private func apply(_ item: ShellItem) {
        switch item {
        case .snapshot(let threads, let projects):
            shell = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.projects = projects
        case .projects(let projects):
            self.projects.merge(projects) { _, new in new }
        case .threadUpdated(let thread):
            shell[thread.id] = thread
        case .threadRemoved(let id):
            shell[id] = nil
        }
    }

    private func apply(_ item: ThreadItem, to threadId: String) {
        switch item {
        case .snapshot(let items):
            details[threadId] = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        case .turnItem(var item):
            var d = details[threadId] ?? [:]
            if item.linesAdded == nil, let old = d[item.id], old.linesAdded != nil { // keep fetched counts
                item.linesAdded = old.linesAdded
                item.linesRemoved = old.linesRemoved
            }
            d[item.id] = item
            if d.count > 400 { // keep memory bounded on very long runs
                let keep = d.values.sorted { $0.ordinal > $1.ordinal }.prefix(300)
                d = Dictionary(keep.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            details[threadId] = d
        }
    }

    // MARK: Derived state

    /// A streaming agent sends many updates a second; derive state at most 4x/s (still reads live).
    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.recomputeScheduled = false
            self.recompute()
        }
    }

    private func recompute() {
        // Subagents ask through their parent: an app-owned child's question shows on its ancestors.
        var childRequests: [String: ThreadStatus] = [:]
        for child in shell.values {
            guard let request = child.subagentRequest else { continue }
            var seen: Set<String> = [child.id]
            var current: ShellThread? = child
            while let c = current, c.isSubagent, let parent = c.parentId, !seen.contains(parent) {
                seen.insert(parent)
                if childRequests[parent] != .pendingApproval { childRequests[parent] = request }
                current = shell[parent]
            }
        }
        // Only write where it changed: rewriting all ~400 structs per update was measurable.
        for (id, request) in childRequests where shell[id]?.childRequest != request { shell[id]?.childRequest = request }
        for (id, t) in shell where t.childRequest != nil && childRequests[id] == nil { shell[id]?.childRequest = nil }

        let candidates = shell.values.filter { !$0.isChild && !$0.archived && !$0.deleted }
        func rank(_ s: ThreadStatus) -> Int {
            s.needsYou || s == .guestRequest ? 0 : s == .waiting ? 2 : s.isBusy ? 1 : 3
        }
        // Active threads stream updates constantly, so ordering them by `updatedAt` makes rows
        // swap places under the cursor. Order them by when their run started instead (stable).
        func key(_ t: ShellThread) -> Date { t.status.isActive ? (t.startedAt ?? t.updatedAt) : t.updatedAt }
        let visible = candidates
            .sorted { a, b in
                let (ra, rb) = (rank(a.status), rank(b.status))
                if ra != rb { return ra < rb }
                let (ka, kb) = (key(a), key(b))
                return ka != kb ? ka > kb : a.id < b.id
            }
            .prefix(Self.visibleCount)

        syncDetailSubscriptions(Set(visible.map(\.id)))
        fetchEditCounts(visible)
        detectTransitions(candidates)

        var rows = visible.map(row)
        if !Self.demo.threads.isEmpty {
            // Demo shows only fake threads, so screenshots never include real work.
            rows = Array(Self.demo.threads.prefix(Self.visibleCount))
            if let id = Self.demo.eventId { eventId = id }
        }
        if rows != threads { threads = rows }
    }

    private func row(_ s: ShellThread) -> T3Thread {
        var t = T3Thread(
            id: s.id, title: s.title, project: projects[s.projectId] ?? "", status: s.status,
            startedAt: s.startedAt, updatedAt: s.updatedAt, runId: s.runId,
            model: s.model.map(Self.prettyModel), provider: s.provider, branch: s.branch, pullRequest: s.pullRequest
        )
        t.pr = s.pr
        if s.status == .waiting, s.runtimeStatus == "idle", let done = s.latestRunCompletedAt {
            t.startedAt = done // parked on background work: T3 counts from when the run finished
        }
        t.usageLimited = s.usageLimited
        t.usageLimitResetAt = s.usageLimitResetAt
        guard let items = details[s.id]?.values.sorted(by: { $0.ordinal < $1.ordinal }) else { return t }

        // Finished messages only: a message being streamed changes every few tokens, and each
        // change would republish the list and redraw the notch ~10x/s for a preview nobody sees yet.
        t.lastMessage = items.last {
            $0.type == "assistant_message" && $0.status != "running" && !($0.text ?? "").isEmpty
        }?.text.flatMap(Self.firstLines)
        if let runId = s.runId {
            let run = items.filter { $0.runId == runId }
            t.filesChanged = run.filter { $0.type == "file_change" }.count
            t.toolCalls = run.filter { ["command_execution", "dynamic_tool", "web_search", "subagent"].contains($0.type) }.count
            // The run's checkpoint has the real per-file totals; until it lands, sum live edits.
            if let checkpoint = run.last(where: { $0.type == "checkpoint" && $0.linesAdded != nil }) {
                t.linesAdded = checkpoint.linesAdded ?? 0
                t.linesRemoved = checkpoint.linesRemoved ?? 0
            } else {
                let edits = run.filter { $0.type == "file_change" }
                t.linesAdded = edits.reduce(0) { $0 + ($1.linesAdded ?? 0) }
                t.linesRemoved = edits.reduce(0) { $0 + ($1.linesRemoved ?? 0) }
            }
            if t.status.isBusy {
                t.runningCommandId = run.last { $0.type == "command_execution" && $0.status == "running" }?.id
            }
        }

        if t.status.needsYou, let pendingId = s.pendingRequestId {
            t.request = items.last { $0.requestId == pendingId }.flatMap(Self.pendingRequest)
        }

        let live = t.status.isActive
        if t.status == .waiting, let task = s.waitingOn {
            (t.activity, t.activityIcon) = (task, "hourglass")
        } else if live, let item = items.last(where: { !Self.quietTypes.contains($0.type) }) {
            (t.activity, t.activityIcon) = Self.describe(item)
        } else if let message = t.lastMessage {
            (t.activity, t.activityIcon) = (Self.firstLine(message), "text.bubble")
        }
        return t
    }

    /// Live "+N −M" before the run's checkpoint lands. The server strips the patch (`diffStr`)
    /// from file edits in every response, so read just that field from T3's local database,
    /// read-only, by item id. If T3 changes its storage this quietly yields nothing and the
    /// exact numbers still arrive with the checkpoint when the run ends.
    private func fetchEditCounts(_ visible: some Sequence<ShellThread>) {
        var wanted: [String: String] = [:] // itemId -> threadId
        for thread in visible {
            guard let runId = thread.runId, let items = details[thread.id]?.values else { continue }
            let run = items.filter { $0.runId == runId }
            if run.contains(where: { $0.type == "checkpoint" && $0.linesAdded != nil }) { continue }
            for edit in run where edit.type == "file_change" && edit.linesAdded == nil
                && edit.status == "completed" && !fetchedEdits.contains(edit.id) {
                wanted[edit.id] = thread.id
            }
        }
        guard !wanted.isEmpty else { return }
        fetchedEdits.formUnion(wanted.keys)
        let ids = Array(wanted.keys)
        Task {
            let counts = await Task.detached { EditStats.lineCounts(itemIds: ids) }.value
            for (itemId, (added, removed)) in counts {
                guard let threadId = wanted[itemId], details[threadId]?[itemId] != nil else { continue }
                details[threadId]?[itemId]?.linesAdded = added
                details[threadId]?[itemId]?.linesRemoved = removed
            }
            if !counts.isEmpty { scheduleRecompute() }
        }
    }

    // MARK: Live command output

    /// Stream the running command of `threadId` (nil stops). One stream at a time.
    func watchOutput(of threadId: String?) {
        let itemId = threadId.flatMap { id in threads.first { $0.id == id }?.runningCommandId }
        if let w = outputWatch, w.threadId == threadId, w.itemId == itemId { return }
        if let w = outputWatch {
            sendRaw(["_tag": "Interrupt", "requestId": w.requestId, "interruptors": [] as [Any]])
            outputWatch = nil
        }
        guard commandOutputStreaming, socket != nil, let threadId, let itemId else { return }
        outputText = ""
        let requestId = send(tag: "orchestration.subscribeCommandOutput",
                             payload: ["threadId": threadId, "itemId": itemId])
        outputWatch = (threadId, itemId, requestId)
    }

    /// Terminal text -> last `n` visible lines: strip ANSI escapes, honor carriage returns.
    nonisolated static func tailLines(_ text: String, _ n: Int) -> [String] {
        let plain = text
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        // Swift's isNewline also matches a lone "\r", which terminals use to *overwrite* a line
        // (progress bars). So split on real newlines only, then keep what follows the last "\r".
        let lines = plain.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in line.components(separatedBy: "\r").last ?? "" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(n))
    }

    private static func pendingRequest(_ item: TurnItem) -> PendingRequest? {
        guard let id = item.requestId else { return nil }
        switch item.type {
        case "approval_request":
            let options = item.approvalOptions.isEmpty
                ? [ApprovalOption(decision: "decline", label: "Deny", warning: nil),
                   ApprovalOption(decision: "accept", label: "Approve", warning: nil)]
                : item.approvalOptions
            return .init(id: id, kind: .approval(prompt: item.prompt, reason: item.reason, options: options))
        case "user_input_request":
            return .init(id: id, kind: .questions(item.questions))
        default:
            return nil
        }
    }

    /// Fake threads for checking layouts without waiting for real events:
    /// `T3NOTCH_DEMO=approval|question|finished|list` (list: PR markers, usage limit, every status).
    private static let demo: (threads: [T3Thread], eventId: String?) = {
        guard let mode = ProcessInfo.processInfo.environment["T3NOTCH_DEMO"] else { return ([], nil) }
        func make(_ id: String, _ title: String, _ status: ThreadStatus, started: Double = -200, updated: Double = -30) -> T3Thread {
            T3Thread(id: id, title: title, project: "custom-dock", status: status,
                     startedAt: Date().addingTimeInterval(started), updatedAt: Date().addingTimeInterval(updated),
                     model: "Opus 5.5", branch: "main")
        }
        switch mode {
        case "approval", "question":
            var t = make("demo", "Clean up old build artifacts", mode == "question" ? .awaitingInput : .pendingApproval)
            t.activity = "Waiting for your answer"
            t.activityIcon = "questionmark.bubble"
            t.request = mode == "question"
                ? .init(id: "demo", kind: .questions([Question(
                    id: "q", header: "Scope", text: "How far should the cleanup go? The build folder alone is 2 GB, /tmp also has old test fixtures.",
                    options: [.init(label: "Build folders only", value: "a", description: nil),
                              .init(label: "Everything in /tmp", value: "b", description: nil),
                              .init(label: "Skip it", value: "c", description: nil)],
                    multiSelect: false)]))
                : .init(id: "demo", kind: .approval(
                    prompt: "rm -rf .build T3Notch.app && swift build -c release",
                    reason: "This command deletes files and could not be checked",
                    options: [.init(decision: "decline", label: "Decline", warning: nil),
                              .init(decision: "accept", label: "Approve", warning: nil)]))
            return ([t], "demo")
        case "finished":
            var t = make("demo", "Ship the notch performance pass", .completed)
            t.lastMessage = "Done. CPU is down from 12–15% to under 1% while threads run, SwiftUI is gone, and the springs are back on Core Animation. 33 tests pass."
            t.activity = t.lastMessage
            t.linesAdded = 812; t.linesRemoved = 431
            return ([t], "demo")
        case "list":
            var a = make("d1", "Fix checkout flow regression", .working, started: -754)
            a.provider = "codex"; a.model = "GPT-5.3 Codex"
            a.activity = "$ pnpm test --filter checkout"; a.activityIcon = "terminal"
            a.linesAdded = 128; a.linesRemoved = 37; a.toolCalls = 22
            a.pr = PullRequestInfo(number: 212, url: "", state: "open", isDraft: false,
                                   checks: .failing, review: .changesRequested, conflicting: true)
            var b = make("d2", "Upgrade auth library", .waiting, started: -1960)
            b.provider = "cursor"; b.model = "Composer 2"
            b.activity = "Subagent: audit session handling"; b.activityIcon = "person.2"
            b.pr = PullRequestInfo(number: 208, url: "", state: "open", isDraft: true,
                                   checks: .pending, review: .reviewRequired, conflicting: false)
            var c = make("d3", "Release notes for 2.4", .completed, updated: -300)
            c.provider = "claudeAgent"
            c.activity = "Drafted the notes and opened the PR."
            c.linesAdded = 64; c.linesRemoved = 3
            c.pr = PullRequestInfo(number: 205, url: "", state: "open", isDraft: false,
                                   checks: .passing, review: .approved, conflicting: false)
            var d = make("d4", "Migrate billing to the new API", .failed, updated: -5400)
            d.provider = "grok"; d.model = "Grok 5"
            d.usageLimited = true; d.usageLimitResetAt = Date().addingTimeInterval(72 * 60)
            var e = make("d5", "Plan the onboarding redesign", .planReady, updated: -900)
            e.provider = "opencode"; e.model = "Kimi K3"
            e.activity = "Plan ready: 6 steps, starting with the empty states"
            var f = make("d6", "Add dark mode to the dashboard", .working, started: -95)
            f.provider = "claudeAgent"
            f.activity = "Editing ThemeProvider.tsx"; f.activityIcon = "pencil"
            f.linesAdded = 37; f.linesRemoved = 12; f.toolCalls = 9
            return ([f, a, b, c, d, e], nil)
        default:
            return ([], nil)
        }
    }()

    private static let quietTypes: Set<String> = ["checkpoint", "user_message", "notification", "system_notice"]

    private static func describe(_ item: TurnItem) -> (String?, String) {
        switch item.type {
        case "command_execution": (item.input.flatMap(firstLine).map { "$ \($0)" }, "terminal")
        case "file_change": (item.fileName.map { "Editing \(($0 as NSString).lastPathComponent)" }, "pencil")
        case "dynamic_tool": (item.title ?? item.toolName, "wrench.and.screwdriver")
        case "web_search": ("Searching the web", "globe")
        case "reasoning": ("Thinking…", "brain")
        case "subagent": (item.title.map { "Subagent: \($0)" } ?? "Running a subagent", "person.2")
        case "approval_request", "user_input_request", "secret_request":
            (item.question.flatMap(firstLine) ?? "Waiting for your answer", "questionmark.bubble")
        case "assistant_message":
            // While streaming, the first line grows token by token; don't redraw for each one.
            (item.status == "running" ? "Writing…" : item.text.flatMap(firstLine), "text.bubble")
        default: (item.title, "sparkles")
        }
    }

    private func syncDetailSubscriptions(_ wanted: Set<String>) {
        guard socket != nil else { return }
        for (threadId, requestId) in threadRequests where !wanted.contains(threadId) {
            sendRaw(["_tag": "Interrupt", "requestId": requestId, "interruptors": [] as [Any]])
            threadRequests[threadId] = nil
            requestThreads[requestId] = nil
            if let ids = details.removeValue(forKey: threadId)?.keys { fetchedEdits.subtract(ids) }
            commandOutput[threadId] = nil
            failed[threadId] = nil
        }
        for threadId in wanted where threadRequests[threadId] == nil {
            log.notice("subscribe thread \(threadId, privacy: .public)")
            let requestId = send(tag: "orchestration.subscribeThread",
                                 payload: ["threadId": threadId, "acceptBoundedSnapshot": true])
            threadRequests[threadId] = requestId
            requestThreads[requestId] = threadId
        }
    }

    /// Sounds and pop-ups follow the *run*, not the pill: T3 hides "Completed" once you've
    /// looked at a thread, but a run you're watching finishing still deserves its click.
    private func detectTransitions(_ threads: [ShellThread]) {
        let now = Dictionary(threads.map { ($0.id, $0.phase) }, uniquingKeysWith: { a, _ in a })
        let prs = Dictionary(threads.compactMap { t in t.pr.map { (t.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let firstLoad = lastPhases.isEmpty
        defer {
            lastPhases = now
            lastPRs = prs
            limitChimed.formIntersection(now.keys) // forget threads that are gone
        }
        guard !firstLoad else { return } // first snapshot: no peeks

        // PR news: checks went red, or a review decision arrived.
        for (id, pr) in prs {
            let before = lastPRs[id]
            if pr.checks == .failing && before?.checks != .failing {
                log.notice("checks failing: \(id, privacy: .public)")
                Chime.shared.play(.failed)
            } else if pr.review != nil && pr.review != .reviewRequired && pr.review != before?.review {
                log.notice("review: \(id, privacy: .public)")
                Chime.shared.play(.needsYou)
            }
        }

        // The "needs you" card goes away by itself once the request is answered (here or in T3).
        if let id = eventId, lastPhases[id] == .needsYou, now[id] != .needsYou {
            dismissEvent()
        }

        for (id, phase) in now {
            let before = lastPhases[id]
            let wasActive = before == .active || before == .needsYou
            switch phase {
            case .needsYou where before != .needsYou:
                show(id, for: nil) // sticky until answered
                log.notice("needs you: \(id, privacy: .public)")
                Chime.shared.play(.needsYou)
                return
            case .completed where wasActive, .failed where wasActive:
                show(id, for: 7)
                log.notice("\(phase == .failed ? "failed" : "done", privacy: .public): \(id, privacy: .public)")
                Chime.shared.play(phase == .failed ? .failed : .done)
                return
            default:
                continue
            }
        }
    }

    /// Click once when a usage-limited thread's limit resets (checked by the store's timer).
    private func checkLimitResets() {
        let now = Date()
        for t in threads where t.usageLimited {
            guard let reset = t.usageLimitResetAt, reset <= now, !limitChimed.contains(t.id) else { continue }
            limitChimed.insert(t.id)
            log.notice("limit reset: \(t.id, privacy: .public)")
            Chime.shared.play(.done)
        }
    }

    private func show(_ id: String, for seconds: Double?) {
        eventId = id
        eventClearTask?.cancel()
        guard let seconds else { return }
        eventClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.eventId = nil
        }
    }

    // MARK: Helpers

    private static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Message text flattened to a short paragraph (markdown noise stripped).
    private static func firstLines(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") }
        return lines.prefix(3).joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    /// "claude-opus-5-5" -> "Opus 5.5"; anything else is shown as-is.
    private static func prettyModel(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst(7).split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    private static var userdata: URL {
        URL(fileURLWithPath: NSString(string: "~/.t3/userdata").expandingTildeInPath)
    }

    /// Where the running server listens, from the file it writes on startup.
    private static func serverOrigin() -> URL? {
        let file = ProcessInfo.processInfo.environment["T3NOTCH_RUNTIME_FILE"].map { URL(fileURLWithPath: $0) }
            ?? userdata.appendingPathComponent("server-runtime.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = json["origin"] as? String else { return nil }
        if let pid = json["pid"] as? Int32, kill(pid, 0) != 0, errno == ESRCH { return nil } // stale file
        return URL(string: origin)
    }

    /// Orchestration protocol this client speaks (`ORCHESTRATION_PROTOCOL_VERSION` in t3code contracts).
    static let protocolVersion = 2

    private struct Environment {
        let id, serverVersion: String?
        let protocolVersion: Int?
        let commandOutputStreaming: Bool
    }

    private static func fetchEnvironment(_ origin: URL) async -> Environment? {
        let url = origin.appendingPathComponent(".well-known/t3/environment")
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let caps = json["capabilities"] as? [String: Any]
        return Environment(id: json["environmentId"] as? String,
                           serverVersion: json["serverVersion"] as? String,
                           protocolVersion: (json["orchestrationProtocolVersion"] as? NSNumber)?.intValue,
                           commandOutputStreaming: caps?["commandOutputStreaming"] as? Bool ?? false)
    }

    private enum ConnectError: Error { case serverDown, noToken, incompatible }
}

// MARK: - Auth token

/// A read-only (`orchestration:read`) bearer token minted with T3's own CLI
/// (`t3 auth session issue`), cached in Application Support with 0600 permissions.
@MainActor
final class TokenStore {
    private var cached: String?
    private var lastMint = Date.distantPast

    /// Bump when the scopes change so an older, narrower token isn't reused.
    nonisolated private static let scopes = ["orchestration:read", "orchestration:operate"]

    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("T3Notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("token-operate")
    }

    func token() async throws -> String? {
        if let cached { return cached }
        if let saved = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            cached = saved
            return saved
        }
        // Don't spam new sessions if something is persistently wrong.
        guard Date().timeIntervalSince(lastMint) > 60 else { return nil }
        lastMint = Date()
        guard let minted = await Self.mint() else { return nil }
        FileManager.default.createFile(atPath: file.path, contents: Data(minted.utf8),
                                       attributes: [.posixPermissions: 0o600])
        cached = minted
        return minted
    }

    func discard() {
        cached = nil
        try? FileManager.default.removeItem(at: file)
    }

    private static func mint() async -> String? {
        await Task.detached {
            let cli = NSString(string: "~/.t3/bin/t3").expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: cli) else { return nil }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["auth", "session", "issue"]
                + TokenStore.scopes.flatMap { ["--scope", $0] }
                + ["--ttl", "30d", "--label", "T3 Notch", "--token-only"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty || token.contains(" ") ? nil : token
        }.value
    }
}

// MARK: - Wire format (Effect RPC, JSON)

enum RunPhase: Sendable { case active, needsYou, completed, failed, other }

struct ShellThread: Sendable {
    let id, title, projectId: String
    let startedAt: Date?
    let updatedAt: Date
    let runId, model, branch, pullRequest, pendingRequestId: String?
    var provider: String?
    let isChild, archived, deleted: Bool
    let parentId: String?
    let isSubagent: Bool
    /// What this thread asks its parent for, if it's a live app-owned subagent with a request.
    let subagentRequest: ThreadStatus?
    /// T3's pill inputs (see `presentThreadShell` / `shellRuntime` in client-runtime models.ts).
    let hasPendingApprovals, hasPendingUserInput: Bool
    let runtimeStatus: String?
    let latestRunStatus: String?
    let latestRunCompletedAt: Date?
    let lastVisitedAt: Date?
    let blockedOnThreadWait, backgroundHoldsCompletion, planMode, hasActionableProposedPlan: Bool
    /// Guest messages waiting for the owner to send or dismiss (newer servers).
    let pendingGuestMessages: Int
    /// What a parked thread is waiting on ("Wait for Vercel web deploy").
    let waitingOn: String?
    let pr: PullRequestInfo?
    /// T3 keeps status "failed" for usage limits; the class says why.
    let usageLimited: Bool
    let usageLimitResetAt: Date?
    /// Set by the store from children's requests.
    var childRequest: ThreadStatus? {
        didSet { if childRequest != oldValue { status = resolveStatus() } }
    }
    /// Cached: sorting ~400 threads reads it thousands of times per update.
    private(set) var status: ThreadStatus = .idle

    /// `resolveThreadStatusPill`, in the same order.
    func resolveStatus() -> ThreadStatus {
        if hasPendingApprovals || childRequest == .pendingApproval { return .pendingApproval }
        if hasPendingUserInput || childRequest == .awaitingInput { return .awaitingInput }
        if pendingGuestMessages > 0 { return .guestRequest }
        if (runtimeStatus == "running" && !blockedOnThreadWait) || runtimeStatus == "waiting" { return .working }
        if ["preparing", "starting", "queued"].contains(runtimeStatus) { return .connecting }
        if (runtimeStatus == "running" && blockedOnThreadWait) || backgroundHoldsCompletion { return .waiting }
        if latestRunStatus == "failed", lastVisitedAt.map({ v in latestRunCompletedAt.map { $0 > v } ?? true }) ?? true {
            return .failed
        }
        if planMode && runSettled && hasActionableProposedPlan { return .planReady }
        if let done = latestRunCompletedAt, let seen = lastVisitedAt, done > seen { return .completed }
        return .idle
    }

    mutating func refreshStatus() { status = resolveStatus() }

    private var runSettled: Bool {
        !["preparing", "starting", "running", "waiting", "queued"].contains(runtimeStatus ?? "")
    }

    var phase: RunPhase {
        if status.needsYou { return .needsYou }
        if status.isBusy { return .active }
        if latestRunStatus == "failed" { return .failed }
        if latestRunStatus == "completed" { return .completed }
        return .other
    }
}

struct TurnItem: Sendable {
    let id: String
    let ordinal: Int
    let type: String
    let runId, title, toolName, input, fileName, text, question: String?
    var requestId, prompt, reason: String?
    var status: String?
    /// From `files[].additions/deletions` (checkpoint and file_change items).
    var linesAdded, linesRemoved: Int?
    var approvalOptions: [ApprovalOption] = []
    var questions: [Question] = []
}

enum ShellItem: Sendable {
    case snapshot(threads: [ShellThread], projects: [String: String])
    case projects([String: String])
    case threadUpdated(ShellThread)
    case threadRemoved(String)
}

enum ThreadItem: Sendable {
    case snapshot([TurnItem])
    case turnItem(TurnItem)
}

struct OutputFrame: Sendable {
    let replace: Bool
    let text: String
}

struct StreamValue: Sendable {
    var shell: ShellItem?
    var thread: ThreadItem?
    var output: OutputFrame?
}

enum Incoming: Sendable {
    case chunk(requestId: String, values: [StreamValue])
    case exit(requestId: String, ok: Bool, message: String?)
    case ignored

    static func parse(_ data: Data) -> Incoming? {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let requestId = (msg["requestId"] as? String) ?? (msg["requestId"] as? NSNumber)?.stringValue ?? ""
        switch msg["_tag"] as? String {
        case "Chunk":
            let values = (msg["values"] as? [[String: Any]] ?? []).map { v in
                StreamValue(shell: parseShell(v), thread: parseThread(v), output: parseOutput(v))
            }
            return .chunk(requestId: requestId, values: values)
        case "Exit":
            let exit = msg["exit"] as? [String: Any]
            let ok = exit?["_tag"] as? String == "Success"
            // Failure cause: [{_tag: "Fail", error: {message?...}}]
            let cause = (exit?["cause"] as? [[String: Any]])?.first
            let message = ((cause?["error"] as? [String: Any])?["message"] as? String)
                ?? (cause?["defect"] as? String)
            return .exit(requestId: requestId, ok: ok, message: message)
        default:
            return .ignored
        }
    }

    private static func parseShell(_ v: [String: Any]) -> ShellItem? {
        switch v["kind"] as? String {
        case "snapshot":
            guard let snap = v["snapshot"] as? [String: Any] else { return nil }
            var projects: [String: String] = [:]
            for p in snap["projects"] as? [[String: Any]] ?? [] {
                if let id = p["id"] as? String { projects[id] = p["title"] as? String ?? "" }
            }
            // Metadata-only refreshes (repository identity) carry no thread list.
            if v["resolvedRepositoryIdentityRoots"] != nil { return .projects(projects) }
            let threads = (snap["threads"] as? [[String: Any]] ?? []).compactMap(shellThread)
            return .snapshot(threads: threads, projects: projects)
        case "thread.updated":
            guard let t = (v["thread"] as? [String: Any]).flatMap(shellThread) else { return nil }
            return .threadUpdated(t)
        case "thread.removed":
            return (v["threadId"] as? String).map(ShellItem.threadRemoved)
        case "project.updated":
            guard let p = v["project"] as? [String: Any], let id = p["id"] as? String else { return nil }
            return .projects([id: p["title"] as? String ?? ""])
        default:
            return nil
        }
    }

    private static func parseOutput(_ v: [String: Any]) -> OutputFrame? {
        guard let kind = v["kind"] as? String, kind == "replace" || kind == "append",
              let text = v["text"] as? String else { return nil }
        return OutputFrame(replace: kind == "replace", text: text)
    }

    private static func parseThread(_ v: [String: Any]) -> ThreadItem? {
        switch v["kind"] as? String {
        case "snapshot":
            let items = ((v["projection"] as? [String: Any])?["turnItems"] as? [[String: Any]] ?? [])
                .compactMap(turnItem)
            return .snapshot(items)
        case "event":
            guard let e = v["event"] as? [String: Any], e["type"] as? String == "turn-item.updated",
                  let item = (e["payload"] as? [String: Any]).flatMap(turnItem) else { return nil }
            return .turnItem(item)
        default:
            return nil
        }
    }

    private static func shellThread(_ t: [String: Any]) -> ShellThread? {
        guard let id = t["id"] as? String else { return nil }
        let status = t["status"] as? String ?? "idle"
        let pending = t["pendingRuntimeRequest"] as? [String: Any]
        let pendingKind = pending?["kind"] as? String
        let lineage = t["lineage"] as? [String: Any]
        let isSubagent = lineage?["relationshipToParent"] as? String == "subagent"

        // shellRuntime(): background work (subagent/monitor/task, not plain commands) parks the
        // run at idle; otherwise the activity run's status wins over the latest run's.
        let tasks = t["pendingBackgroundTasks"] as? [[String: Any]] ?? []
        // backgroundWorkHoldsCompletion(): awaited work of any kind, or subagent/monitor/task work.
        func holdsCompletion(_ task: [String: Any]) -> Bool {
            task["awaited"] as? Bool == true
                || ["subagent", "monitor", "background_task"].contains(task["kind"] as? String ?? "")
        }
        let holds = tasks.contains(where: holdsCompletion)
        let parkAtIdle = holds && status != "failed"
        let hasRuntime = t["latestRunId"] is String || t["activeProviderThreadId"] is String || parkAtIdle
        let runtimeStatus: String? = !hasRuntime ? nil
            : parkAtIdle ? "idle" : (t["activityRunStatus"] as? String ?? status)
        let runtimeWorking = ["preparing", "starting", "running"].contains(runtimeStatus ?? "")

        let hasPendingApprovals = pending != nil && pendingKind != "user_input" && pendingKind != "auth_refresh"
        let hasPendingUserInput = pendingKind == "user_input"
            && ((pending?["blocking"] as? Bool) != false || !runtimeWorking)

        // latestRun as presentThreadShell() builds it.
        let hasLatestRun = t["latestRunId"] is String
        let terminal = ["completed", "failed", "interrupted", "cancelled", "idle"].contains(status)
        let completedAt: Date? = !hasLatestRun ? nil
            : t.keys.contains("latestRunCompletedAt") ? date(t["latestRunCompletedAt"])
            : terminal ? date(t["updatedAt"]) : nil

        // A live app-owned subagent's request surfaces on its parent (provider-native ones ask there already).
        let activity = t["activityRunStatus"]
        let childLive = activity is NSNull ? false
            : activity != nil ? true
            : ["preparing", "starting", "running", "waiting"].contains(status)
        let subagentRequest: ThreadStatus? = {
            guard let kind = pendingKind, kind != "auth_refresh", isSubagent,
                  t["creationSource"] as? String != "provider", childLive else { return nil }
            return kind == "user_input" ? .awaitingInput : .pendingApproval
        }()

        let pr = (t["pullRequests"] as? [[String: Any]])?.last
        let prText = (pr?["number"] as? NSNumber).map { n in
            ((pr?["snapshot"] as? [String: Any])?["state"] as? String).map { "#\(n) \($0)" } ?? "#\(n)"
        }
        var thread = ShellThread(
            id: id,
            title: t["title"] as? String ?? "Untitled",
            projectId: t["projectId"] as? String ?? "",
            startedAt: date(t["activityRunStartedAt"]) ?? date(t["latestRunStartedAt"]),
            updatedAt: date(t["updatedAt"]) ?? .distantPast,
            runId: (t["activeRunId"] as? String) ?? (t["latestRunId"] as? String),
            model: (t["modelSelection"] as? [String: Any])?["model"] as? String,
            branch: t["branch"] as? String,
            pullRequest: prText,
            pendingRequestId: pending?["id"] as? String,
            provider: provider(t),
            isChild: lineage?["parentThreadId"] as? String != nil,
            archived: t["archivedAt"] is String,
            deleted: t["deletedAt"] is String,
            parentId: lineage?["parentThreadId"] as? String,
            isSubagent: isSubagent,
            subagentRequest: subagentRequest,
            hasPendingApprovals: hasPendingApprovals,
            hasPendingUserInput: hasPendingUserInput,
            runtimeStatus: runtimeStatus,
            latestRunStatus: hasLatestRun ? (status == "idle" ? "completed" : status) : nil,
            latestRunCompletedAt: completedAt,
            lastVisitedAt: date(t["lastVisitedAt"]),
            blockedOnThreadWait: t["blockedOnThreadWait"] as? Bool ?? false,
            backgroundHoldsCompletion: holds,
            planMode: t["interactionMode"] as? String == "plan",
            hasActionableProposedPlan: t["hasActionableProposedPlan"] as? Bool ?? false,
            pendingGuestMessages: (t["pendingGuestMessageCount"] as? NSNumber)?.intValue ?? 0,
            waitingOn: tasks.first(where: holdsCompletion)?["description"] as? String,
            pr: pullRequest(t),
            usageLimited: status == "failed" && t["lastErrorClass"] as? String == "usage_limit",
            usageLimitResetAt: date(t["usageLimitResetAt"])
        )
        thread.refreshStatus()
        return thread
    }

    /// Driver from the provider thread id ("provider-thread:provider:claudeAgent:…"), else
    /// guessed from the model id.
    private static func provider(_ t: [String: Any]) -> String? {
        if let id = t["activeProviderThreadId"] as? String,
           let r = id.range(of: #"provider:([A-Za-z]+):"#, options: .regularExpression) {
            return String(id[r].dropFirst("provider:".count).dropLast())
        }
        let model = ((t["modelSelection"] as? [String: Any])?["model"] as? String ?? "").lowercased()
        if model.hasPrefix("claude") { return "claudeAgent" }
        if model.hasPrefix("gpt") || model.hasPrefix("o3") || model.hasPrefix("o4") || model.contains("codex") { return "codex" }
        if model.hasPrefix("grok") { return "grok" }
        return nil
    }

    /// Latest PR the thread is tracking (stack-dismissed ones are hidden in T3 too).
    private static func pullRequest(_ t: [String: Any]) -> PullRequestInfo? {
        guard let pr = (t["pullRequests"] as? [[String: Any]])?.last(where: { $0["source"] as? String != "stack-dismissed" }),
              let number = (pr["number"] as? NSNumber)?.intValue else { return nil }
        let snap = pr["snapshot"] as? [String: Any]
        return PullRequestInfo(
            number: number,
            url: pr["url"] as? String ?? "",
            state: snap?["state"] as? String ?? "open",
            isDraft: snap?["isDraft"] as? Bool ?? false,
            checks: (snap?["checksState"] as? String).flatMap(PullRequestInfo.Checks.init(rawValue:)),
            review: (snap?["reviewDecision"] as? String).flatMap(PullRequestInfo.Review.init(rawValue:)),
            conflicting: snap?["mergeability"] as? String == "conflicting"
        )
    }

    private static func turnItem(_ i: [String: Any]) -> TurnItem? {
        guard let id = i["id"] as? String else { return nil }
        let question = ((i["questions"] as? [[String: Any]])?.first?["question"] as? String)
            ?? (i["prompt"] as? String) ?? (i["reason"] as? String)
        var item = TurnItem(
            id: id,
            ordinal: (i["ordinal"] as? NSNumber)?.intValue ?? 0,
            type: i["type"] as? String ?? "",
            runId: i["runId"] as? String,
            title: i["title"] as? String,
            toolName: i["toolName"] as? String,
            input: (i["input"] as? String).map { String($0.prefix(300)) },
            fileName: i["fileName"] as? String,
            text: (i["text"] as? String).map { String($0.prefix(1200)) },
            question: question
        )
        item.requestId = i["requestId"] as? String
        item.status = i["status"] as? String
        if let files = i["files"] as? [[String: Any]] { // empty = run changed nothing (+0 −0)
            item.linesAdded = files.reduce(0) { $0 + (($1["additions"] as? NSNumber)?.intValue ?? 0) }
            item.linesRemoved = files.reduce(0) { $0 + (($1["deletions"] as? NSNumber)?.intValue ?? 0) }
        } else if i["additions"] != nil || i["deletions"] != nil {
            item.linesAdded = (i["additions"] as? NSNumber)?.intValue
            item.linesRemoved = (i["deletions"] as? NSNumber)?.intValue
        } else if let diff = i["diffStr"] as? String, let counts = lineCounts(diffStr: diff) {
            // Live edits carry no totals until the run's checkpoint; count the patch ourselves.
            (item.linesAdded, item.linesRemoved) = counts
        }
        item.prompt = (i["prompt"] as? String).map { String($0.prefix(600)) }
        item.reason = i["reason"] as? String
        item.approvalOptions = (i["options"] as? [[String: Any]] ?? []).compactMap { o in
            guard let decision = o["decision"] as? String, let label = o["label"] as? String else { return nil }
            return ApprovalOption(decision: decision, label: label, warning: o["warning"] as? String)
        }
        item.questions = (i["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let qid = q["id"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> QuestionOption? in
                guard let label = o["label"] as? String else { return nil }
                return QuestionOption(label: label, value: o["value"] as? String ?? label,
                                      description: o["description"] as? String)
            }
            return Question(id: qid, header: q["header"] as? String ?? "",
                            text: q["question"] as? String ?? qid, options: options,
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        return item
    }

    /// +/- line counts from a file_change `diffStr`: Claude's tool result JSON
    /// (`structuredPatch` hunks, or `content` for a new file), else a plain unified diff.
    static func lineCounts(diffStr: String) -> (Int, Int)? {
        func count(_ lines: [Substring]) -> (Int, Int) {
            var added = 0, removed = 0
            for line in lines {
                if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
                else if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
            }
            return (added, removed)
        }
        if let data = diffStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let hunks = json["structuredPatch"] as? [[String: Any]] ?? []
            if !hunks.isEmpty {
                return count(hunks.flatMap { ($0["lines"] as? [String] ?? []).map { Substring($0) } })
            }
            if json["type"] as? String == "create", let content = json["content"] as? String {
                return (content.split(separator: "\n", omittingEmptySubsequences: false).count, 0)
            }
            return nil
        }
        let lines = diffStr.split(separator: "\n")
        guard lines.contains(where: { $0.hasPrefix("@@") }) else { return nil }
        return count(lines)
    }

    // Shared: creating a formatter per timestamp (6 per thread × 400 threads per snapshot) was
    // the single biggest parse cost. ISO8601DateFormatter is thread-safe.
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let whole = ISO8601DateFormatter()

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return fractional.date(from: s) ?? whole.date(from: s)
    }
}

/// The one thing the server won't hand out: each file edit's patch. Read-only lookups by id.
enum EditStats {
    static func lineCounts(itemIds: [String]) -> [String: (Int, Int)] {
        let path = NSString(string: "~/.t3/userdata/statev2.sqlite").expandingTildeInPath
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT turn_item_id, json_extract(payload_json, '$.diffStr')
        FROM orchestration_v2_projection_turn_items WHERE turn_item_id IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, id) in itemIds.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), id, -1, transient) }
        var out: [String: (Int, Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let diff = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let counts = Incoming.lineCounts(diffStr: diff) else { continue }
            out[id] = counts
        }
        return out
    }
}
