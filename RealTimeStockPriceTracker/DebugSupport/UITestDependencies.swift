#if DEBUG
import Foundation

/// Offline dependencies are used only when launched explicitly by the UI test target.
@MainActor
final class UITestEchoTransport: WebSocketTransportType {
    private var continuation: WebSocketEventStream.Continuation?

    func connect(to url: URL) -> WebSocketEventStream {
        let (events, continuation) = WebSocketEventStream.makeStream(
            bufferingPolicy: .bufferingOldest(2_048)
        )
        self.continuation = continuation
        continuation.yield(.opened)
        return events
    }

    func disconnect() {
        continuation?.finish()
        continuation = nil
    }

    func send(_ data: Data) async throws {
        if case .dropped = continuation?.yield(.message(data)) {
            continuation?.finish(throwing: SocketStreamError.bufferOverflow)
        }
    }
}

nonisolated struct UITestPriceGenerator: PriceGenerating {
    func nextPrice(for stock: StockSymbol) -> Double {
        // Separate starting prices keep rows stable while UI automation taps them.
        // All symbols still receive live changes on every test clock tick.
        let index = SymbolCatalog.stocks.firstIndex { $0.symbol == stock.symbol } ?? 0
        let initialPrice = Double(SymbolCatalog.stocks.count - index) * 1_000
        return (stock.price ?? initialPrice) + 1
    }
}
#endif
