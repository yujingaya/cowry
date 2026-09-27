import Foundation
internal import GRDB
import LedgerCore
import Synchronization

/// Published after ops are applied, locally or by sync. The sets name what may have changed;
/// a list checks each changed ID against the new snapshot to decide whether to insert, move,
/// update or remove its row.
public struct LedgerChange: Sendable {
    public let snapshot: LedgerSnapshot
    public let entries: Set<Entry.ID>
    public let accounts: Set<Account.ID>
    public let commodities: Set<Commodity.ID>
    public let prices: Bool
    public let balanceAssertions: Bool
    public let settings: Bool
    public let conflicts: Bool
}

/// Delivers changes in log order. Each commit records its changes inside its write transaction,
/// so by the time any commit flushes, every earlier commit's changes are already recorded; the
/// flush then publishes them all, in order, with a snapshot that includes them.
final class ChangePublisher: Sendable {
    private struct State {
        var pending: [Int64: ChangeCollector] = [:]
        var published: Int64
        var subscribers: [UUID: AsyncStream<LedgerChange>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(head: Int64) {
        state = Mutex(State(published: head))
    }

    func record(seq: Int64, _ changes: ChangeCollector) {
        state.withLock { $0.pending[seq] = changes }
    }

    func flush(_ pool: DatabasePool) {
        state.withLock { state in
            var merged = ChangeCollector()
            var head = state.published
            while let changes = state.pending.removeValue(forKey: head + 1) {
                merged.merge(changes)
                head += 1
            }
            guard head > state.published else { return }
            state.published = head
            guard !state.subscribers.isEmpty else { return }

            let snapshot = LedgerSnapshot(reader: Self.snapshotReader(pool), head: head)
            let change = LedgerChange(
                snapshot: snapshot, entries: merged.entries, accounts: merged.accounts,
                commodities: merged.commodities, prices: merged.prices,
                balanceAssertions: merged.balanceAssertions, settings: merged.settings, conflicts: merged.conflicts)
            for continuation in state.subscribers.values { continuation.yield(change) }
        }
    }

    func stream() -> AsyncStream<LedgerChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LedgerChange>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        state.withLock { $0.subscribers[id] = continuation }
        return stream
    }

    func finish() {
        state.withLock { state in
            for continuation in state.subscribers.values { continuation.finish() }
            state.subscribers.removeAll()
        }
    }

    /// A WAL snapshot when possible. SQLite can't take one right after the WAL was truncated; the
    /// live pool is a correct, if not pinned, fallback.
    static func snapshotReader(_ pool: DatabasePool) -> any DatabaseReader {
        (try? pool.makeSnapshotPool()) ?? pool
    }
}
