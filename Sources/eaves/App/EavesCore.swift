import Foundation

/// Immutable snapshot handed from the socket queue to the UI.
struct Snapshot: Sendable {
    let aggregate: AggregateState
    let summary: String?
    let rows: [SessionRow]

    static let empty = Snapshot(aggregate: .off, summary: nil, rows: [])
}

/// Composition root shared by `app` and `--headless`: owns the SessionStore
/// on a serial queue, runs the socket server, sweeps TTLs, and publishes
/// snapshots after every mutation.
final class EavesCore {
    private let queue = DispatchQueue(label: "com.trevor.eaves.core")
    private let store = SessionStore()
    private var server: SocketServer?
    private var sweepTimer: DispatchSourceTimer?

    /// Called on the core queue after each state change; hop to MainActor inside.
    var onSnapshot: ((Snapshot) -> Void)?
    /// Called when a `quit` command arrives.
    var onQuit: (() -> Void)?

    func start() throws {
        let server = SocketServer(queue: queue) { [weak self] req in
            self?.handle(req) ?? WireResponse(ok: false, error: "shutting down")
        }
        try server.start()
        self.server = server

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.store.sweep()
            self.publish()
        }
        timer.resume()
        sweepTimer = timer
    }

    func stop() {
        sweepTimer?.cancel()
        server?.stop()
    }

    private func handle(_ req: WireRequest) -> WireResponse {
        switch req.cmd {
        case "ping":
            return WireResponse(ok: true, version: eavesVersion)
        case "event":
            store.apply(req)
            publish()
            return WireResponse(ok: true)
        case "status":
            let now = store.now()
            return WireResponse(
                ok: true,
                aggregate: store.aggregate().rawValue,
                summary: store.summary(),
                sessions: store.rows().map {
                    WireSessionInfo(
                        id: $0.id, project: $0.project, source: $0.source,
                        state: $0.state.rawValue, activity: $0.activity,
                        ageSeconds: Int(now.timeIntervalSince($0.lastEvent)))
                },
                version: eavesVersion)
        case "reset":
            store.reset()
            publish()
            return WireResponse(ok: true)
        case "quit":
            queue.async { [weak self] in self?.onQuit?() }
            return WireResponse(ok: true)
        default:
            return WireResponse(ok: false, error: "unknown cmd \(req.cmd)")
        }
    }

    private func publish() {
        onSnapshot?(Snapshot(
            aggregate: store.aggregate(),
            summary: store.summary(),
            rows: store.rows()))
    }
}
