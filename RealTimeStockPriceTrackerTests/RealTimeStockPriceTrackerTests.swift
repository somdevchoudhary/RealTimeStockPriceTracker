import XCTest
import Combine
@testable import RealTimeStockPriceTracker

nonisolated func testStocks(_ count: Int) -> [StockSymbol] {
    (0..<count).map { StockSymbol(symbol: String(format: "S%04d", $0)) }
}

@MainActor
func eventually(_ condition: @MainActor () async -> Bool,
                file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Expected asynchronous state was not reached", file: file, line: line)
}

/// In-memory socket events and sent-message recording; never opens a connection.
@MainActor
final class MockSocket: WebSocketServiceType {
    private let maximumBufferedEvents: Int
    private(set) var overflowCount = 0
    private var continuation: SocketEventStream.Continuation?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var sent: [PriceUpdate] = []

    init(maximumBufferedEvents: Int = 2_048) {
        self.maximumBufferedEvents = maximumBufferedEvents
    }

    func connect() -> SocketEventStream {
        connectCount += 1
        continuation?.finish()
        let (events, continuation) = SocketEventStream.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedEvents)
        )
        self.continuation = continuation
        emitState(.connecting)
        return events
    }

    func disconnect() {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }

    func send(_ update: PriceUpdate) { sent.append(update) }
    func emitState(_ state: ConnectionState) { emit(.state(state)) }
    func emitMessage(_ data: Data) { emit(.message(data)) }
    func echo(_ update: PriceUpdate) throws { emitMessage(try JSONEncoder().encode(update)) }

    private func emit(_ event: SocketEvent) {
        if case .dropped = continuation?.yield(event) {
            overflowCount += 1
            continuation?.finish(throwing: SocketStreamError.bufferOverflow)
        }
    }
}

@MainActor
final class ManualClock: FeedClockType {
    private var continuation: AsyncStream<Void>.Continuation?
    private var generation = UUID()
    var active: Bool { continuation != nil }

    func ticks() -> AsyncStream<Void> {
        continuation?.finish()
        let id = UUID()
        generation = id
        let (ticks, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.continuation = nil
            }
        }
        return ticks
    }

    func tick() { continuation?.yield(()) }
}

nonisolated struct FixedGenerator: PriceGenerating {
    func nextPrice(for stock: StockSymbol) -> Double { 123.45 }
}

/// Exercises the real service with an in-memory transport instead of URLSession.
@MainActor
final class FakeTransport: WebSocketTransportType {
    private(set) var continuation: WebSocketEventStream.Continuation?
    var onSend: ((Data) async throws -> Void)?
    private(set) var sent: [Data] = []
    private(set) var disconnectCount = 0

    func connect(to url: URL) -> WebSocketEventStream {
        let (events, continuation) = WebSocketEventStream.makeStream(bufferingPolicy: .bufferingOldest(2_048))
        self.continuation = continuation
        return events
    }

    func emit(_ event: WebSocketEvent) {
        if case .dropped = continuation?.yield(event) {
            continuation?.finish(throwing: SocketStreamError.bufferOverflow)
        }
    }

    func disconnect() {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }

    func send(_ data: Data) async throws {
        sent.append(data)
        try await onSend?(data)
    }
}

// A bounded test-only gate makes ingress overflow deterministic instead of relying on thread timing.
extension StockStore {
    func holdProcessing(ready: CheckedContinuation<Void, Never>, until gate: DispatchSemaphore) {
        ready.resume()
        _ = gate.wait(timeout: .now() + 5)
    }
}

final class StoreTests: XCTestCase {
    func testCatalogAndValidationAndPreviousPrice() async {
        XCTAssertEqual(SymbolCatalog.stocks.count, 25)
        XCTAssertEqual(Set(SymbolCatalog.stocks.map(\.id)).count, 25)
        let store = StockStore()
        for value in [0, -1, Double.infinity, Double.nan, 0.001] {
            await store.apply(PriceUpdate(symbol: "AAPL", price: value))
        }
        await store.apply(PriceUpdate(symbol: "UNKNOWN", price: 10))
        let missing = await store.stock(for: "AAPL")
        XCTAssertNil(missing?.price)
        for value in [100.004, 100.014, 100.014] {
            await store.apply(PriceUpdate(symbol: "AAPL", price: value))
        }
        let stock = await store.stock(for: "AAPL")
        XCTAssertEqual(stock?.price, 100.01)
        XCTAssertEqual(stock?.previousPrice, 100.01)
        XCTAssertEqual(stock?.change, 0)
    }

    func testSessionsRejectLateAndCancelledWork() async throws {
        let store = StockStore()
        let first = UUID(), second = UUID()
        func data(_ price: Double) throws -> Data {
            try JSONEncoder().encode(PriceUpdate(symbol: "AAPL", price: price))
        }
        await store.beginSession(first)
        await store.ingest(try data(100), session: first)
        await store.beginSession(second)
        await store.endSession(first)
        await store.ingest(try data(999), session: first)
        await store.ingest(try data(101), session: second)
        let invalid = Data("not json".utf8)
        await store.ingest(invalid, session: second)
        let cancelledData = try data(900)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.ingest(cancelledData, session: second)
        }
        await task.value
        let stock = await store.stock(for: "AAPL")
        XCTAssertEqual(stock?.price, 101)
        XCTAssertEqual(stock?.previousPrice, 100)
    }

    func testBothSortsTieBreakersAndMissingPrices() async {
        let store = StockStore()
        for (symbol, initial, current) in [("AAPL",100.0,110.0),("AMZN",50,60),("GOOG",200,205),("TSLA",100,95)] {
            await store.apply(PriceUpdate(symbol: symbol, price: initial))
            await store.apply(PriceUpdate(symbol: symbol, price: current))
        }
        let prices = await store.snapshot(sort: .price)
        let changes = await store.snapshot(sort: .priceChange)
        XCTAssertEqual(Array(prices.rows.prefix(4).map(\.symbol)), ["GOOG","AAPL","TSLA","AMZN"])
        XCTAssertEqual(Array(changes.rows.prefix(4).map(\.symbol)), ["AAPL","AMZN","GOOG","TSLA"])
        XCTAssertEqual(prices.missingPriceCount, 21)
    }

    func testThousandQuoteBurstBuildsOneTrailingSnapshot() async {
        let store = StockStore(symbols: testStocks(1_000), publicationInterval: .seconds(3_600))
        let stream = await store.feedSnapshots(sort: .price)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        // First price publishes promptly; subsequent prices are grouped.
        await store.apply(PriceUpdate(symbol: "S0000", price: 100))
        let first = await iterator.next()
        XCTAssertEqual(first?.missingPriceCount, 999)
        let before = await store.snapshotBuildCount
        for index in 0..<1_000 {
            await store.apply(PriceUpdate(symbol: String(format: "S%04d", index), price: 200 + Double(index)))
        }
        let during = await store.snapshotBuildCount
        XCTAssertEqual(during, before, "No per-message sorting or snapshot construction")
        await store.flushFeed()
        let snapshot = await iterator.next()
        let after = await store.snapshotBuildCount
        XCTAssertEqual(after - before, 1)
        XCTAssertEqual(snapshot?.rows.count, 1_000)
        XCTAssertEqual(snapshot?.rows.first?.symbol, "S0999")
        XCTAssertEqual(snapshot?.rows.last?.previousPrice, 100)
        let processed = await store.processedUpdateCount
        XCTAssertEqual(processed, 1_001)
        let pending = await store.hasPendingFeedChanges
        XCTAssertFalse(pending)
    }

    func testSlowUIKeepsLatestSnapshotWithCorrectPreviousQuote() async {
        let store = StockStore(publicationInterval: .seconds(3_600))
        let stream = await store.feedSnapshots(sort: .price)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        for price in [100.0, 101, 102, 103] {
            await store.apply(PriceUpdate(symbol: "AAPL", price: price))
            await store.flushFeed()
        }
        let snapshot = await iterator.next()
        let apple = snapshot?.rows.first { $0.symbol == "AAPL" }
        XCTAssertEqual(apple?.price, 103)
        XCTAssertEqual(apple?.previousPrice, 102)
    }

    func testHotStreamProcessesEveryQuoteWithBoundedPendingState() async throws {
        let store = StockStore(symbols: testStocks(1_000), publicationInterval: .seconds(3_600))
        let feed = await store.feedSnapshots(sort: .price)
        let id = UUID()
        await store.beginSession(id)
        let (messages, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(10_000))
        for round in 0..<10 {
            for index in 0..<1_000 {
                continuation.yield(try JSONEncoder().encode(PriceUpdate(
                    symbol: String(format: "S%04d", index), price: 100 + Double(round))))
            }
        }
        continuation.finish()
        await store.consume(messages, session: id)
        let processed = await store.processedUpdateCount
        let pending = await store.hasPendingFeedChanges
        let latest = await store.stock(for: "S0999")
        XCTAssertEqual(processed, 10_000)
        XCTAssertTrue(pending, "A single flag tracks any number of unpublished changes")
        XCTAssertEqual(latest?.price, 109)
        XCTAssertEqual(latest?.previousPrice, 108)
        await store.flushFeed()
        let cleared = await store.hasPendingFeedChanges
        XCTAssertFalse(cleared)
        withExtendedLifetime(feed) {}
    }

    func testRoutingSyntaxAndStoreValidation() async {
        XCTAssertEqual(SymbolRoute.symbol(from: URL(string: "stocks://symbol/aapl")!), "AAPL")
        for url in ["stocks://symbol", "stocks://symbol/extra/AAPL", "stocks://symbol/%2FAAPL",
                    "https://symbol/AAPL", "stocks://symbol/AAPL?price=0", "stocks://symbol/AAPL#x"] {
            XCTAssertNil(SymbolRoute.symbol(from: URL(string: url)!))
        }
        let store = StockStore()
        let unknown = await store.stock(for: "UNKNOWN")
        XCTAssertNil(unknown, "A valid route must still resolve to an existing instrument")
    }

    func testSnapshotsReusedAcrossSubscribersWithSameSort() async {
        let store = StockStore()
        let first = await store.feedSnapshots(sort: .price)
        let second = await store.feedSnapshots(sort: .price)
        let builds = await store.snapshotBuildCount
        XCTAssertEqual(builds, 1)
        withExtendedLifetime((first, second)) {}
    }

    func testMetadataIterationKeepsCatalogCompleteAndSortsDeterministic() async {
        let input = [StockSymbol(symbol: "TSLA"), StockSymbol(symbol: "AAPL"), StockSymbol(symbol: "GOOG")]
        let store = StockStore(symbols: input)
        let generated = await store.simulatedUpdates(using: FixedGenerator())
        XCTAssertEqual(generated.map(\.symbol).sorted(), ["AAPL", "GOOG", "TSLA"])
        XCTAssertTrue(generated.allSatisfy { $0.price == 123.45 })
        for stock in input {
            await store.apply(PriceUpdate(symbol: stock.symbol, price: 100))
            await store.apply(PriceUpdate(symbol: stock.symbol, price: 101))
        }
        for sort in StockSort.allCases {
            let snapshot = await store.snapshot(sort: sort)
            XCTAssertEqual(snapshot.rows.map(\.symbol), ["AAPL", "GOOG", "TSLA"])
        }
    }

    func testDuplicateCatalogSymbolsKeepFirstMetadataAndMissingCount() async {
        let store = StockStore(symbols: [
            StockSymbol(symbol: "AAPL", name: "Original", price: 100),
            StockSymbol(symbol: "AAPL", name: "Duplicate"),
            StockSymbol(symbol: "GOOG")
        ])
        let snapshot = await store.snapshot(sort: .price)
        let apple = await store.stock(for: "AAPL")
        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(snapshot.missingPriceCount, 1)
        XCTAssertEqual(apple?.name, "Original")
        XCTAssertEqual(apple?.price, 100)
    }

    func testExplicitFlushInvalidatesOldWaitAndAllowsNextPublication() async {
        let store = StockStore(publicationInterval: .milliseconds(5))
        let stream = await store.feedSnapshots(sort: .price)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await store.apply(PriceUpdate(symbol: "AAPL", price: 100))
        _ = await iterator.next()
        await store.apply(PriceUpdate(symbol: "AAPL", price: 101))
        await store.flushFeed()
        let explicit = await iterator.next()
        XCTAssertEqual(explicit?.rows.first?.price, 101)
        await store.apply(PriceUpdate(symbol: "AAPL", price: 102))
        let scheduled = await iterator.next()
        XCTAssertEqual(scheduled?.rows.first?.price, 102)
        XCTAssertEqual(scheduled?.rows.first?.previousPrice, 101)
    }

    func testAutomaticTrailingPublication() async {
        let store = StockStore(publicationInterval: .milliseconds(5))
        let stream = await store.feedSnapshots(sort: .price)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await store.apply(PriceUpdate(symbol: "AAPL", price: 100))
        _ = await iterator.next()
        await store.apply(PriceUpdate(symbol: "AAPL", price: 101))
        let trailing = await iterator.next()
        XCTAssertEqual(trailing?.rows.first?.price, 101)
    }
}

@MainActor
final class DetailTests: XCTestCase {
    func testSelectedStockChangesButOtherSymbolsDoNotPublish() async {
        let store = StockStore()
        let model = SymbolDetailViewModel(symbol: "AAPL", store: store)
        var received: [StockSymbol?] = []
        let token = model.$stock.sink { received.append($0) }
        await eventually { model.stock != nil }
        let initialCount = received.count
        await store.apply(PriceUpdate(symbol: "GOOG", price: 100))
        await store.apply(PriceUpdate(symbol: "TSLA", price: 200))
        XCTAssertEqual(received.count, initialCount)
        await store.apply(PriceUpdate(symbol: "AAPL", price: 100))
        await eventually { model.stock?.price == 100 }
        await store.apply(PriceUpdate(symbol: "AAPL", price: 101))
        await eventually { model.stock?.price == 101 }
        XCTAssertEqual(model.stock?.previousPrice, 100)
        // A repeated quote changes direction once (up -> flat), then identical state is suppressed.
        await store.apply(PriceUpdate(symbol: "AAPL", price: 101))
        await eventually { model.stock?.previousPrice == 101 }
        let flatCount = received.count
        await store.apply(PriceUpdate(symbol: "AAPL", price: 101))
        XCTAssertEqual(received.count, flatCount)
        withExtendedLifetime(token) {}
    }

    func testRepeatedNavigationReleasesModelsAndSubscriptions() async {
        let store = StockStore()
        for _ in 0..<100 {
            var model: SymbolDetailViewModel? = SymbolDetailViewModel(symbol: "AAPL", store: store)
            await eventually { model?.stock != nil }
            weak var weakModel = model
            model = nil
            XCTAssertNil(weakModel)
            weakModel = nil
        }
        await eventually { await store.activeDetailSubscriptionCount == 0 }
    }

    func testUnknownSymbolCompletesWithoutLeakingSubscription() async {
        let store = StockStore()
        let model = SymbolDetailViewModel(symbol: "UNKNOWN", store: store)
        await eventually { !model.isLoading }
        let count = await store.activeDetailSubscriptionCount
        XCTAssertEqual(count, 0)
        XCTAssertNil(model.stock)
    }
}

@MainActor
final class FeedTests: XCTestCase {
    func fixture(maximumBufferedMessages: Int = 2_048,
                 maximumSocketBufferedEvents: Int = 2_048) -> (StockStore, MockSocket, ManualClock, StockViewModel) {
        let store = StockStore(publicationInterval: .seconds(3_600))
        let socket = MockSocket(maximumBufferedEvents: maximumSocketBufferedEvents), clock = ManualClock()
        let model = StockViewModel(store: store, webSocket: socket, clock: clock,
                                  generator: FixedGenerator(), maximumBufferedMessages: maximumBufferedMessages)
        return (store, socket, clock, model)
    }

    func testImmediateSendEchoOnlyPricesAndPeriodicGeneration() async throws {
        let (store, socket, clock, model) = fixture()
        await eventually { model.sortedSymbols.count == 25 }
        model.startFeed()
        model.startFeed()
        await eventually { socket.connectCount == 1 }
        XCTAssertEqual(socket.sent.count, 0)
        socket.emitState(.connected)
        await eventually { socket.sent.count == 25 }
        XCTAssertTrue(model.isLoadingPrices)
        let beforeEcho = await store.stock(for: "AAPL")
        XCTAssertNil(beforeEcho?.price)
        try socket.echo(PriceUpdate(symbol: "AAPL", price: 123.45))
        await eventually { await store.stock(for: "AAPL")?.price == 123.45 }
        await store.flushFeed()
        await eventually { model.sortedSymbols.first?.symbol == "AAPL" }
        clock.tick()
        await eventually { socket.sent.count == 50 }
        model.stopFeed()
        let count = socket.sent.count
        clock.tick()
        try socket.echo(PriceUpdate(symbol: "AAPL", price: 999))
        let afterStop = await store.stock(for: "AAPL")
        XCTAssertEqual(afterStop?.price, 123.45)
        XCTAssertEqual(socket.sent.count, count)
        await eventually { !clock.active }
    }

    func testSortChangesAndFeedLifetimeCleanup() async {
        let store = StockStore()
        var model: StockViewModel? = StockViewModel(store: store, webSocket: MockSocket(), clock: ManualClock())
        await eventually { model?.sortedSymbols.count == 25 }
        await store.apply(PriceUpdate(symbol: "AAPL", price: 100))
        await store.apply(PriceUpdate(symbol: "AAPL", price: 110))
        await store.apply(PriceUpdate(symbol: "GOOG", price: 200))
        await store.apply(PriceUpdate(symbol: "GOOG", price: 205))
        model?.sort = .priceChange
        await eventually { model?.sortedSymbols.first?.symbol == "AAPL" }
        model?.sort = .price
        await eventually { model?.sortedSymbols.first?.symbol == "GOOG" }
        weak var weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        weakModel = nil
        await eventually { await store.activeFeedSubscriptionCount == 0 }
    }

    func testIngressOverflowFailsInsteadOfDroppingPricesSilently() async throws {
        let (store, socket, _, model) = fixture(maximumBufferedMessages: 2, maximumSocketBufferedEvents: 10_002)
        model.startFeed()
        await eventually { socket.connectCount == 1 }
        socket.emitState(.connected)
        await eventually { model.connectionState == .connected }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        await withCheckedContinuation { ready in
            Task.detached { await store.holdProcessing(ready: ready, until: gate) }
        }
        let data = try JSONEncoder().encode(PriceUpdate(symbol: "AAPL", price: 100))
        // Keep the store occupied while the socket consumer fills the two-frame ingress buffer.
        for _ in 0..<10_000 { socket.emitMessage(data) }
        await eventually { model.connectionState == .failed }
        XCTAssertEqual(model.connectionState, .failed)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(socket.overflowCount, 0, "This test must fail at store ingress, not the socket stream")
    }

    func testReleasingRunningFeedDisconnectsAndReleasesSubscriptions() async {
        let store = StockStore()
        let socket = MockSocket()
        var model: StockViewModel? = StockViewModel(store: store, webSocket: socket, clock: ManualClock())
        model?.startFeed()
        await eventually { socket.connectCount == 1 }
        socket.emitState(.connected)
        await eventually { model?.connectionState == .connected }
        weak var weakModel = model
        model = nil
        await eventually { weakModel == nil }
        XCTAssertEqual(socket.disconnectCount, 1)
        await eventually { await store.activeFeedSubscriptionCount == 0 }
        weakModel = nil
    }

    func testHiddenFeedDoesNotSortWhileDetailRemainsLive() async {
        let store = StockStore()
        let model = StockViewModel(store: store, webSocket: MockSocket(), clock: ManualClock())
        let detail = SymbolDetailViewModel(symbol: "AAPL", store: store)
        await eventually { model.sortedSymbols.count == 25 && detail.stock != nil }
        model.pausePresentation()
        await eventually { await store.activeFeedSubscriptionCount == 0 }
        let before = await store.snapshotBuildCount
        await store.apply(PriceUpdate(symbol: "AAPL", price: 200))
        await store.apply(PriceUpdate(symbol: "AAPL", price: 201))
        await eventually { detail.stock?.price == 201 }
        let hidden = await store.snapshotBuildCount
        XCTAssertEqual(hidden, before)
        model.sort = .priceChange
        model.resumePresentation()
        await eventually { model.sortedSymbols.first?.price == 201 }
        XCTAssertEqual(detail.stock?.previousPrice, 200)
    }

    func testFailureRetryAndRapidStopStartIgnoreOldWork() async throws {
        let (store, socket, _, model) = fixture()
        model.startFeed()
        await eventually { socket.connectCount == 1 }
        socket.emitState(.connected)
        socket.emitState(.failed)
        await eventually { !model.isRunning }
        XCTAssertFalse(model.isRunning)
        model.startFeed()
        model.stopFeed()
        model.startFeed()
        await eventually { socket.connectCount == 2 }
        socket.emitState(.connected)
        try socket.echo(PriceUpdate(symbol: "AAPL", price: 200))
        await eventually { await store.stock(for: "AAPL")?.price == 200 }
        XCTAssertTrue(model.isRunning)
        model.stopFeed()
    }
}

@MainActor
final class SocketTests: XCTestCase {
    func testQueueHandlesThousandSymbolsAndCoalescesPendingValues() async {
        var queue = PendingPriceQueue(allowedSymbols: Set((0..<1_000).map { "S\($0)" }))
        for index in 0..<1_000 { XCTAssertTrue(queue.enqueue(PriceUpdate(symbol: "S\(index)", price: 100))) }
        XCTAssertTrue(queue.enqueue(PriceUpdate(symbol: "S0", price: 101)))
        XCTAssertFalse(queue.enqueue(PriceUpdate(symbol: "OVERFLOW", price: 100)))
        XCTAssertEqual(queue.count, 1_000)
        XCTAssertEqual(queue.pop()?.price, 101)
        for index in 1..<1_000 { XCTAssertEqual(queue.pop()?.symbol, "S\(index)") }
        XCTAssertNil(queue.pop())
        XCTAssertEqual(queue.count, 0)
        queue.removeAll()
    }

    func testServiceSendsAllThousandCatalogQuotesUsingMockTransport() async {
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: Set((0..<1_000).map { "S\($0)" }), makeTransport: { transport })
        let events = socket.connect()
        defer { socket.disconnect(); withExtendedLifetime(events) {} }
        transport.emit(.opened)
        await eventually { socket.connectionState == .connected }
        for index in 0..<1_000 { socket.send(PriceUpdate(symbol: "S\(index)", price: 100)) }
        await eventually { transport.sent.count == 1_000 }
        XCTAssertEqual(socket.pendingSendCount, 0)
    }

    func testTextWireFormatAndSendFailure() async throws {
        let update = PriceUpdate(symbol: "AAPL", price: 123.45)
        let data = try JSONEncoder().encode(update)
        guard case .string(let text) = try WebSocketMessageCodec.outgoingJSON(data) else {
            return XCTFail("Echo server requires JSON text frames")
        }
        XCTAssertEqual(PriceUpdateCodec.decode(Data(text.utf8)), update)
        let transport = FakeTransport()
        transport.onSend = { _ in throw URLError(.networkConnectionLost) }
        let socket = WebSocketService(allowedSymbols: ["AAPL"], makeTransport: { transport })
        let events = socket.connect()
        transport.emit(.opened)
        await eventually { socket.connectionState == .connected }
        socket.send(update)
        await eventually { socket.connectionState == .failed }
        XCTAssertEqual(transport.disconnectCount, 1)
        var iterator = events.makeAsyncIterator()
        do {
            while let _ = try await iterator.next() {}
            XCTFail("Send failure must terminate the stream with an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    func testOldSuspendedSendCannotDisconnectNewSocket() async {
        let old = FakeTransport(), new = FakeTransport()
        var gate: CheckedContinuation<Void, Error>?
        old.onSend = { _ in try await withCheckedThrowingContinuation { gate = $0 } }
        var attempts = 0
        let socket = WebSocketService(allowedSymbols: ["AAPL"], makeTransport: { attempts += 1; return attempts == 1 ? old : new })
        let oldEvents = socket.connect()
        old.emit(.opened)
        await eventually { socket.connectionState == .connected }
        socket.send(PriceUpdate(symbol: "AAPL", price: 100))
        await eventually { gate != nil }
        socket.disconnect()
        let newEvents = socket.connect()
        defer { socket.disconnect(); withExtendedLifetime((oldEvents, newEvents)) {} }
        new.emit(.opened)
        await eventually { socket.connectionState == .connected }
        gate?.resume(throwing: URLError(.cancelled))
        old.emit(.failed)
        new.emit(.message(Data("new-session".utf8)))
        var iterator = newEvents.makeAsyncIterator()
        _ = try? await iterator.next()
        _ = try? await iterator.next()
        if case .message(let data) = try? await iterator.next() {
            XCTAssertEqual(data, Data("new-session".utf8))
        } else {
            XCTFail("Old work must not terminate the new event stream")
        }
        XCTAssertEqual(socket.connectionState, .connected)
    }

    func testQueueRejectsUnknownAndHandlesEmptyCatalogAndReuse() async {
        var empty = PendingPriceQueue(allowedSymbols: [])
        XCTAssertFalse(empty.enqueue(PriceUpdate(symbol: "AAPL", price: 100)))
        XCTAssertNil(empty.pop())
        var queue = PendingPriceQueue(allowedSymbols: ["AAPL", "GOOG"])
        for round in 0..<3 {
            for value in 1...100 {
                XCTAssertTrue(queue.enqueue(PriceUpdate(symbol: "AAPL", price: Double(value))))
                XCTAssertTrue(queue.enqueue(PriceUpdate(symbol: "GOOG", price: Double(value))))
                XCTAssertFalse(queue.enqueue(PriceUpdate(symbol: "UNKNOWN", price: 999)))
                XCTAssertEqual(queue.count, 2)
            }
            XCTAssertEqual(queue.pop(), PriceUpdate(symbol: "AAPL", price: 100))
            XCTAssertTrue(queue.enqueue(PriceUpdate(symbol: "AAPL", price: 101)))
            XCTAssertEqual(queue.pop()?.symbol, "GOOG")
            if round == 1 { queue.removeAll() }
            else { XCTAssertEqual(queue.pop(), PriceUpdate(symbol: "AAPL", price: 101)) }
            XCTAssertNil(queue.pop())
        }
    }

    func testUnknownOutgoingSymbolDoesNotDisconnectOrBlockCatalogQuotes() async {
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: ["AAPL"], makeTransport: { transport })
        let events = socket.connect()
        defer { socket.disconnect(); withExtendedLifetime(events) {} }
        transport.emit(.opened)
        await eventually { socket.connectionState == .connected }
        socket.send(PriceUpdate(symbol: "UNKNOWN", price: 999))
        XCTAssertEqual(socket.connectionState, .connected)
        XCTAssertEqual(socket.pendingSendCount, 0)
        XCTAssertEqual(transport.disconnectCount, 0)
        socket.send(PriceUpdate(symbol: "AAPL", price: 100))
        await eventually { transport.sent.count == 1 }
        XCTAssertEqual(PriceUpdateCodec.decode(transport.sent[0])?.symbol, "AAPL")
        XCTAssertEqual(socket.connectionState, .connected)
    }

    func testCatalogMetadataSurvivesEchoAndLiveDetailUpdates() async {
        let catalog = SymbolCatalog.stocks
        let store = StockStore(symbols: catalog)
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: Set(catalog.map(\.symbol)), makeTransport: { transport })
        transport.onSend = { transport.emit(.message($0)) }
        let model = StockViewModel(store: store, webSocket: socket, clock: ManualClock(), generator: FixedGenerator())
        let detail = SymbolDetailViewModel(symbol: "AAPL", store: store)
        model.startFeed()
        await eventually { transport.continuation != nil }
        transport.emit(.opened)
        await eventually { model.feed.missingPriceCount == 0 && model.feed.rows.count == catalog.count }
        for original in catalog {
            let updated = await store.stock(for: original.symbol)
            XCTAssertEqual(updated?.metadata, original.metadata)
            XCTAssertFalse(original.descriptionKey.isEmpty)
        }
        socket.send(PriceUpdate(symbol: "AAPL", price: 150))
        await eventually { detail.stock?.price == 150 }
        socket.send(PriceUpdate(symbol: "AAPL", price: 151))
        await eventually { detail.stock?.price == 151 }
        XCTAssertEqual(detail.stock?.previousPrice, 150)
        XCTAssertEqual(detail.stock?.metadata, catalog.first { $0.symbol == "AAPL" }?.metadata)
        model.stopFeed()
    }
}

@MainActor
final class AsyncPipelineTests: XCTestCase {
    func testQueuedOldEventsCannotChangeRestartedFeed() async throws {
        let store = StockStore()
        let socket = MockSocket()
        let model = StockViewModel(store: store, webSocket: socket,
                                  clock: ManualClock(), generator: FixedGenerator())
        model.startFeed()
        await eventually { socket.connectCount == 1 }
        socket.emitState(.connected)
        await eventually { model.connectionState == .connected }
        // These events are queued, then their session is cancelled before the consumer runs.
        try socket.echo(PriceUpdate(symbol: "AAPL", price: 999))
        socket.emitState(.failed)
        model.stopFeed()
        model.startFeed()
        await eventually { socket.connectCount == 2 }
        socket.emitState(.connected)
        await eventually { model.connectionState == .connected }
        try socket.echo(PriceUpdate(symbol: "AAPL", price: 200))
        await eventually { await store.stock(for: "AAPL")?.price == 200 }
        let stock = await store.stock(for: "AAPL")
        XCTAssertNil(stock?.previousPrice, "The cancelled session's queued price must not be applied")
        XCTAssertTrue(model.isRunning)
        model.stopFeed()
    }

    func testExplicitSocketStreamEndShowsDisconnectedState() async {
        let socket = MockSocket()
        let model = StockViewModel(store: StockStore(), webSocket: socket, clock: ManualClock())
        model.startFeed()
        await eventually { socket.connectCount == 1 }
        socket.emitState(.connected)
        await eventually { model.connectionState == .connected }
        socket.disconnect()
        await eventually { !model.isRunning }
        XCTAssertEqual(model.connectionState, .disconnected)
    }

    func testSocketStateAndMessagesStayOrdered() async throws {
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: ["AAPL"], makeTransport: { transport })
        let events = socket.connect()
        defer { socket.disconnect() }
        transport.emit(.opened)
        transport.emit(.message(Data("first".utf8)))
        transport.emit(.message(Data("second".utf8)))
        transport.emit(.closed)
        var received: [String] = []
        do {
            for try await event in events {
                switch event {
                case .state(.connecting): received.append("connecting")
                case .state(.connected): received.append("connected")
                case .message(let data): received.append(String(decoding: data, as: UTF8.self))
                default: XCTFail("Unexpected state")
                }
            }
            XCTFail("Unexpected closure must surface as a failure")
        } catch {
            XCTAssertEqual(error as? SocketStreamError, .connectionLost)
        }
        XCTAssertEqual(received, ["connecting", "connected", "first", "second"])
    }

    func testFullServiceBufferStillReportsTerminalFailure() async {
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: ["AAPL"], maximumBufferedEvents: 2,
                                      makeTransport: { transport })
        let events = socket.connect()
        transport.emit(.opened)
        transport.emit(.message(Data("cannot-fit".utf8)))
        await eventually { socket.connectionState == .failed }
        var states: [ConnectionState] = []
        do {
            for try await event in events {
                if case .state(let state) = event { states.append(state) }
            }
            XCTFail("Buffer overflow must remain observable after buffered events drain")
        } catch {
            XCTAssertEqual(error as? SocketStreamError, .bufferOverflow)
        }
        XCTAssertEqual(states, [.connecting, .connected])
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    func testCancellingSocketConsumerDisconnectsTransport() async {
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: ["AAPL"], makeTransport: { transport })
        let events = socket.connect()
        let consumer = Task {
            do { for try await _ in events {} } catch {}
        }
        transport.emit(.opened)
        await eventually { socket.connectionState == .connected }
        consumer.cancel()
        await consumer.value
        await eventually { transport.disconnectCount == 1 }
        XCTAssertEqual(socket.connectionState, .disconnected)
    }

    func testUnexpectedTransportStreamEndFailsConnection() async {
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: ["AAPL"], makeTransport: { transport })
        let events = socket.connect()
        defer { withExtendedLifetime(events) {} }
        transport.emit(.opened)
        await eventually { socket.connectionState == .connected }
        transport.continuation?.finish()
        await eventually { socket.connectionState == .failed }
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    func testTransportStreamOverflowPropagatesToService() async {
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: ["AAPL"], makeTransport: { transport })
        let events = socket.connect()
        defer { withExtendedLifetime(events) {} }
        transport.emit(.opened)
        for _ in 0..<3_000 { transport.emit(.message(Data("tick".utf8))) }
        await eventually { socket.connectionState == .failed }
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    func testReleasingFeedCancelsServiceAndClockConsumers() async {
        let store = StockStore()
        let transport = FakeTransport()
        let socket = WebSocketService(allowedSymbols: ["AAPL"], makeTransport: { transport })
        let clock = ManualClock()
        var model: StockViewModel? = StockViewModel(store: store, webSocket: socket,
                                                 clock: clock, generator: FixedGenerator())
        model?.startFeed()
        await eventually { transport.continuation != nil }
        transport.emit(.opened)
        await eventually { model?.connectionState == .connected && clock.active }
        weak var weakModel = model
        model = nil
        await eventually { weakModel == nil && !clock.active }
        weakModel = nil
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertEqual(socket.connectionState, .disconnected)
        await eventually { await store.activeFeedSubscriptionCount == 0 }
    }

    func testTaskClockProducesTicksAndCancels() async {
        let ticks = FeedClock(interval: 0.001).ticks()
        var received = 0
        let consumer = Task {
            for await _ in ticks { received += 1 }
        }
        await eventually { received > 0 }
        consumer.cancel()
        await consumer.value
        let countAfterCancellation = received
        await Task.yield()
        XCTAssertEqual(received, countAfterCancellation)
    }
}
