//
//  StockStore.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import Foundation

/// One authoritative, off-main-actor store. No observable object is allocated per stock.
actor StockStore {
    // MARK: - Catalog and quote state

    private let metadata: [String: StockMetadata]
    private var quotes: [String: StockQuote]
    private var missingPriceCount: Int
    private let decoder = JSONDecoder()
    private var activeSessionID: UUID?
    private var revision: UInt64 = 0
    private(set) var hasPendingFeedChanges = false

    // MARK: - Batched feed publication

    private let publicationInterval: Duration
    private var lastPublication: ContinuousClock.Instant?
    private var scheduledPublicationTask: Task<Void, Never>?
    private var publicationGeneration: UInt64 = 0
    private var cachedSnapshots: [StockSort: FeedSnapshot] = [:]

    // MARK: - Active subscribers

    private struct FeedObserver {
        let sort: StockSort
        let continuation: AsyncStream<FeedSnapshot>.Continuation
    }

    private var feedObservers: [UUID: FeedObserver] = [:]
    private var detailObservers: [String: [UUID: AsyncStream<StockSymbol?>.Continuation]] = [:]

    // Counts support lifecycle and performance verification without retaining price history.
    private(set) var processedUpdateCount = 0
    private(set) var snapshotBuildCount = 0

    var activeDetailSubscriptionCount: Int {
        detailObservers.values.reduce(0) { $0 + $1.count }
    }
    var activeFeedSubscriptionCount: Int { feedObservers.count }

    // MARK: - Initialization

    init(
        symbols stocks: [StockSymbol] = SymbolCatalog.stocks,
        publicationInterval: Duration = .milliseconds(100)
    ) {
        precondition(publicationInterval > .zero)
        var metadata: [String: StockMetadata] = [:]
        var quotes: [String: StockQuote] = [:]
        metadata.reserveCapacity(stocks.count)
        quotes.reserveCapacity(stocks.count)
        var missingPriceCount = 0
        // Duplicate catalog entries keep the first metadata and quote.
        for stock in stocks where metadata[stock.symbol] == nil {
            metadata[stock.symbol] = stock.metadata
            quotes[stock.symbol] = stock.quote
            if stock.price == nil {
                missingPriceCount += 1
            }
        }
        self.metadata = metadata
        self.quotes = quotes
        self.missingPriceCount = missingPriceCount
        self.publicationInterval = publicationInterval
    }

    deinit {
        scheduledPublicationTask?.cancel()
    }

    // MARK: - Session lifecycle

    func beginSession(_ id: UUID) {
        guard !Task.isCancelled else { return }
        activeSessionID = id
    }

    func endSession(_ id: UUID) {
        guard activeSessionID == id else { return }
        activeSessionID = nil
        flushFeed()
    }

    // MARK: - Incoming price processing

    /// A single long-lived consumer stays on this actor, avoiding an actor hop per quote.
    func consume(_ messages: AsyncStream<Data>, session id: UUID) async {
        var processedSinceYield = 0
        for await data in messages {
            guard !Task.isCancelled else { break }
            ingest(data, session: id)
            processedSinceYield += 1
            if processedSinceYield == 256 {
                processedSinceYield = 0
                await Task.yield() // Keep snapshots and detail subscriptions responsive during a hot stream.
            }
        }
    }

    /// Decoding and ordered quote processing happen on this actor, not the UI thread.
    func ingest(_ data: Data, session id: UUID) {
        guard !Task.isCancelled, activeSessionID == id,
              let update = try? decoder.decode(PriceUpdate.self, from: data) else {
            return
        }
        apply(update)
    }

    /// Internal mutation boundary, also exercised directly by deterministic store tests.
    func apply(_ update: PriceUpdate) {
        guard update.price.isFinite, update.price > 0,
              let previousQuote = quotes[update.symbol] else {
            return
        }
        let price = (update.price * 100).rounded() / 100
        guard price.isFinite, price > 0 else { return }
        processedUpdateCount += 1
        let newQuote = StockQuote(price: price, previousPrice: previousQuote.price)
        guard newQuote != previousQuote else { return }
        quotes[update.symbol] = newQuote
        if previousQuote.price == nil {
            missingPriceCount -= 1
        }
        revision &+= 1
        cachedSnapshots.removeAll(keepingCapacity: true)
        hasPendingFeedChanges = true
        publishDetailUpdate(newQuote, for: update.symbol)
        schedulePublication()
    }

    // MARK: - Catalog lookup and simulation

    func stock(for symbol: String) -> StockSymbol? {
        guard let stockMetadata = metadata[symbol] else { return nil }
        return makeStock(stockMetadata)
    }

    func simulatedUpdates(using generator: any PriceGenerating) -> [PriceUpdate] {
        metadata.values.compactMap { stockMetadata -> PriceUpdate? in
            guard let stock = makeStock(stockMetadata) else { return nil }
            return PriceUpdate(symbol: stockMetadata.symbol, price: generator.nextPrice(for: stock))
        }
    }

    // MARK: - Feed and detail subscriptions

    func feedSnapshots(sort: StockSort) -> AsyncStream<FeedSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FeedSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeFeed(id) }
        }
        feedObservers[id] = FeedObserver(sort: sort, continuation: continuation)
        continuation.yield(snapshot(sort: sort))
        return stream
    }

    func stockUpdates(for symbol: String) -> AsyncStream<StockSymbol?> {
        let (stream, continuation) = AsyncStream<StockSymbol?>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        guard let initialStock = stock(for: symbol) else {
            continuation.yield(nil)
            continuation.finish()
            return stream
        }
        let id = UUID()
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeDetail(id, symbol: symbol) }
        }
        detailObservers[symbol, default: [:]][id] = continuation
        continuation.yield(initialStock)
        return stream
    }

    // MARK: - Sorted snapshots and publication

    /// Flushes the last accepted quotes on Stop; tests can advance publication without sleeping.
    func flushFeed() {
        cancelScheduledPublication()
        guard hasPendingFeedChanges else { return }
        hasPendingFeedChanges = false
        guard !feedObservers.isEmpty else { return }
        lastPublication = .now
        // A snapshot is cached per revision and sort, even if several windows observe it.
        for observer in feedObservers.values {
            observer.continuation.yield(snapshot(sort: observer.sort))
        }
    }

    func snapshot(sort: StockSort) -> FeedSnapshot {
        if let cached = cachedSnapshots[sort] { return cached }
        snapshotBuildCount += 1
        let rows = metadata.values.compactMap { makeStock($0) }.sorted { lhs, rhs in
            isOrderedBefore(lhs, rhs, sort: sort)
        }
        let result = FeedSnapshot(
            rows: rows,
            sort: sort,
            revision: revision,
            missingPriceCount: missingPriceCount
        )
        cachedSnapshots[sort] = result
        return result
    }

    /// Highest known values first; ties and missing values use symbol order for stability.
    private func isOrderedBefore(_ lhs: StockSymbol, _ rhs: StockSymbol, sort: StockSort) -> Bool {
        let left = sort == .price ? lhs.price : lhs.change
        let right = sort == .price ? rhs.price : rhs.change
        switch (left, right) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.symbol < rhs.symbol
        }
    }

    /// Iterating metadata avoids a redundant symbols array and a second metadata lookup per row.
    private func makeStock(_ stockMetadata: StockMetadata) -> StockSymbol? {
        guard let quote = quotes[stockMetadata.symbol] else { return nil }
        return StockSymbol(metadata: stockMetadata, quote: quote)
    }

    private func cancelScheduledPublication() {
        publicationGeneration &+= 1 // Invalidate callbacks that already passed their cancellation check.
        scheduledPublicationTask?.cancel()
        scheduledPublicationTask = nil
    }

    private func schedulePublication() {
        guard !feedObservers.isEmpty else {
            hasPendingFeedChanges = false
            return
        }
        guard scheduledPublicationTask == nil else { return }
        // Leading-edge first quote, then bounded trailing publications. No two-second startup delay.
        guard let lastPublication else {
            flushFeed()
            return
        }
        let delay = max(.zero, publicationInterval - lastPublication.duration(to: .now))
        publicationGeneration &+= 1
        let generation = publicationGeneration
        scheduledPublicationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.publishIfCurrent(generation)
        }
    }

    private func publishIfCurrent(_ generation: UInt64) {
        guard publicationGeneration == generation else { return }
        flushFeed()
    }

    // MARK: - Detail delivery and subscriber cleanup

    private func publishDetailUpdate(_ quote: StockQuote, for symbol: String) {
        guard let observers = detailObservers[symbol],
              !observers.isEmpty,
              let stockMetadata = metadata[symbol] else {
            return
        }
        let stock = StockSymbol(metadata: stockMetadata, quote: quote)
        for continuation in observers.values {
            continuation.yield(stock)
        }
    }

    private func removeFeed(_ id: UUID) {
        feedObservers[id] = nil
        if feedObservers.isEmpty {
            cancelScheduledPublication()
            hasPendingFeedChanges = false
            cachedSnapshots.removeAll(keepingCapacity: true)
            lastPublication = nil
        }
    }

    private func removeDetail(_ id: UUID, symbol: String) {
        detailObservers[symbol]?[id] = nil
        if detailObservers[symbol]?.isEmpty == true {
            detailObservers[symbol] = nil
        }
    }
}
