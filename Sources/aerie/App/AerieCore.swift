import Foundation

/// Immutable snapshot handed from the socket queue to the UI.
struct Snapshot: Sendable {
    let aggregate: AggregateState
    let summary: String?
    let rows: [SessionRow]
    let approvals: [PendingApproval]
    let recents: [RecentSession]
    let lastSeenBySource: [String: Date]

    static let empty = Snapshot(
        aggregate: .off, summary: nil, rows: [], approvals: [], recents: [],
        lastSeenBySource: [:])
}

/// Composition root shared by `app` and `--headless`: owns the SessionStore
/// on a serial queue, runs the socket server, sweeps TTLs, parks approval
/// replies, and publishes snapshots after every mutation.
final class AerieCore {
    private let queue = DispatchQueue(label: "com.trevor.aerie.core")
    private let store = SessionStore()
    private var server: SocketServer?
    private var sweepTimer: DispatchSourceTimer?
    /// Parked approval connections + their expiry timers, keyed by approval
    /// id. Every entry ends in exactly ONE of: resolve, timeout, hangup.
    private var pendingReplies: [String: ConnectionReply] = [:]
    private var approvalTimers: [String: DispatchSourceTimer] = [:]

    /// Server-side auto-"none" deadline. Must be < the hook's socket read
    /// timeout (55s) which must be < the hook entry timeout in tool config
    /// (60s), so every layer resolves before the one above gives up.
    var approvalTimeout: TimeInterval = 50

    /// Called on the core queue after each state change; hop to MainActor inside.
    var onSnapshot: ((Snapshot) -> Void)?
    /// Called when a `quit` command arrives.
    var onQuit: (() -> Void)?

    func start() throws {
        let server = SocketServer(queue: queue) { [weak self] req, reply in
            guard let self else {
                reply.send(WireResponse(ok: false, error: "shutting down"))
                return
            }
            self.handle(req, reply)
        }
        try server.start()
        self.server = server

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.store.sweep()
            // defensive: a lost timer must not wedge a card forever
            for id in self.store.expireApprovals() {
                self.finishApproval(id: id, decision: "none")
            }
            self.publish()
        }
        timer.resume()
        sweepTimer = timer
    }

    func stop() {
        sweepTimer?.cancel()
        queue.sync {
            for (id, reply) in pendingReplies {
                reply.send(WireResponse(ok: true, decision: "none", approvalID: id))
            }
            pendingReplies.removeAll()
            approvalTimers.values.forEach { $0.cancel() }
            approvalTimers.removeAll()
        }
        server?.stop()
    }

    /// Resolve a pending approval from the UI (or `aerie approve/deny`).
    /// Callable from any thread.
    func resolveApproval(id: String, decision: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.store.resolveApproval(id: id, decision: decision) != nil else { return }
            self.finishApproval(id: id, decision: decision)
            self.publish()
        }
    }

    // MARK: core-queue internals

    private func handle(_ req: WireRequest, _ reply: ConnectionReply) {
        switch req.cmd {
        case "ping":
            reply.send(WireResponse(ok: true, version: aerieVersion))
        case "event":
            store.apply(req)
            publish()
            reply.send(WireResponse(ok: true))
        case "status":
            reply.send(statusResponse())
        case "approval":
            handleApproval(req, reply)
        case "approval_resolve":
            guard let id = req.approvalID,
                  let decision = req.decision, ["allow", "deny"].contains(decision) else {
                reply.send(WireResponse(ok: false, error: "need approval_id and decision allow|deny"))
                return
            }
            if store.resolveApproval(id: id, decision: decision) != nil {
                finishApproval(id: id, decision: decision)
                publish()
                reply.send(WireResponse(ok: true, decision: decision, approvalID: id))
            } else {
                reply.send(WireResponse(ok: false, error: "no such approval \(id)"))
            }
        case "reset":
            for (id, parked) in pendingReplies {
                parked.send(WireResponse(ok: true, decision: "none", approvalID: id))
            }
            pendingReplies.removeAll()
            approvalTimers.values.forEach { $0.cancel() }
            approvalTimers.removeAll()
            store.reset()
            publish()
            reply.send(WireResponse(ok: true))
        case "quit":
            reply.send(WireResponse(ok: true))
            queue.async { [weak self] in self?.onQuit?() }
        default:
            reply.send(WireResponse(ok: false, error: "unknown cmd \(req.cmd)"))
        }
    }

    private func handleApproval(_ req: WireRequest, _ reply: ConnectionReply) {
        guard req.sessionID != nil else {
            reply.send(WireResponse(ok: false, error: "approval needs session_id"))
            return
        }
        let id = UUID().uuidString
        let timeout = min(TimeInterval(req.timeoutS ?? Int(approvalTimeout)), approvalTimeout)

        store.addApproval(req, id: id, timeout: timeout)
        pendingReplies[id] = reply

        reply.onHangup = { [weak self] in
            guard let self else { return }
            // client gave up (its own timeout) or died — clear the card
            self.pendingReplies[id] = nil
            self.approvalTimers[id]?.cancel()
            self.approvalTimers[id] = nil
            self.store.resolveApproval(id: id, decision: "none")
            self.publish()
        }
        reply.park()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.store.resolveApproval(id: id, decision: "none")
            self.finishApproval(id: id, decision: "none")
            self.publish()
        }
        timer.resume()
        approvalTimers[id] = timer

        publish()
    }

    /// Send the parked reply (if any) and clear bookkeeping. Store state is
    /// the caller's responsibility.
    private func finishApproval(id: String, decision: String) {
        approvalTimers[id]?.cancel()
        approvalTimers[id] = nil
        guard let reply = pendingReplies.removeValue(forKey: id) else { return }
        reply.send(WireResponse(ok: true, decision: decision, approvalID: id))
    }

    private func statusResponse() -> WireResponse {
        let now = store.now()
        return WireResponse(
            ok: true,
            aggregate: store.aggregate().rawValue,
            summary: store.summary(),
            sessions: store.rows().map {
                WireSessionInfo(
                    id: $0.id, project: $0.project, source: $0.source,
                    model: $0.model, state: $0.state.rawValue,
                    activity: $0.activity,
                    ageSeconds: Int(now.timeIntervalSince($0.lastEvent)))
            },
            lastSeenBySource: store.lastSeenBySource.mapValues { $0.timeIntervalSince1970 },
            approvals: store.approvals.map {
                WireApprovalInfo(
                    id: $0.id, sessionID: $0.sessionID, source: $0.source,
                    project: $0.project, toolName: $0.toolName,
                    toolInputJSON: $0.toolInputJSON,
                    expiresInS: max(0, Int($0.expiresAt.timeIntervalSince(now))),
                    canAllow: $0.canAllow)
            },
            version: aerieVersion)
    }

    private func publish() {
        onSnapshot?(Snapshot(
            aggregate: store.aggregate(),
            summary: store.summary(),
            rows: store.rows(),
            approvals: store.approvals,
            recents: store.recents,
            lastSeenBySource: store.lastSeenBySource))
    }
}
