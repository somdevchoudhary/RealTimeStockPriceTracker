import Foundation

/// Keeps only the latest unsent price for each catalog symbol.
/// Pending values cannot exceed the catalog size; one additional send may be in flight.
/// Lookup is O(1) on average, and dequeue is amortized O(1).
nonisolated struct PendingPriceQueue {
    private static let compactionThreshold = 1_024

    private let allowedSymbols: Set<String>
    private var updates: [String: PriceUpdate] = [:]
    private var order: [String?] = []
    private var head = 0

    var count: Int { updates.count }

    init(allowedSymbols: Set<String>) {
        self.allowedSymbols = allowedSymbols
    }

    mutating func enqueue(_ update: PriceUpdate) -> Bool {
        guard allowedSymbols.contains(update.symbol) else { return false }

        // Replacing a pending value preserves its existing place in send order.
        if updates[update.symbol] != nil {
            updates[update.symbol] = update
            return true
        }

        updates[update.symbol] = update
        order.append(update.symbol)
        return true
    }

    mutating func pop() -> PriceUpdate? {
        guard head < order.count, let symbol = order[head] else { return nil }

        // Release consumed symbol references without shifting on every dequeue.
        order[head] = nil
        head += 1
        let update = updates.removeValue(forKey: symbol)
        compactConsumedSlotsIfNeeded()
        return update
    }

    mutating func removeAll() {
        updates.removeAll()
        order.removeAll()
        head = 0
    }

    private mutating func compactConsumedSlotsIfNeeded() {
        if head == order.count {
            order.removeAll(keepingCapacity: true)
            head = 0
        } else if head > Self.compactionThreshold, head * 2 >= order.count {
            // Occasionally reclaim consumed slots during a continuous feed.
            order.removeFirst(head)
            head = 0
        }
    }
}
