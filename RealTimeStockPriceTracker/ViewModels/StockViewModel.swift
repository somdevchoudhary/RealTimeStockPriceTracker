//
//  StockViewModel.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import Foundation
import Combine
import OSLog

/// Owns feed lifecycle and screen state; decoding, quote storage, and sorting stay in StockStore.
@MainActor
final class StockViewModel: ObservableObject {
    // MARK: - Published screen state

    @Published private(set) var feed = FeedSnapshot.empty
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isRunning = false
    @Published var sort: StockSort = .price {
        didSet {
            if sort != oldValue, feedObservationTask != nil {
                observeFeedSnapshots()
            }
        }
    }

    var sortedSymbols: [StockSymbol] { feed.rows }

    var isLoadingPrices: Bool {
        connectionState == .connected && feed.missingPriceCount > 0
    }

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.realtimestockpricetracker", category: "Feed")
    private let store: StockStore
    private let webSocket: any WebSocketServiceType
    private let clock: any FeedClockType
    private let generator: any PriceGenerating
    private let maximumBufferedMessages: Int

    // MARK: - Owned work

    private var clockTask: Task<Void, Never>?
    private var socketEventsTask: Task<Void, Never>?
    private var feedObservationTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var messageIngestionTask: Task<Void, Never>?
    private var priceGenerationTask: Task<Void, Never>?
    private var incomingMessages: AsyncStream<Data>.Continuation?
    private var sessionID: UUID?

    init(
        store: StockStore,
        webSocket: any WebSocketServiceType,
        clock: (any FeedClockType)? = nil,
        generator: (any PriceGenerating)? = nil,
        maximumBufferedMessages: Int = 2_048
    ) {
        precondition(maximumBufferedMessages > 0)
        self.store = store
        self.webSocket = webSocket
        self.clock = clock ?? FeedClock()
        self.generator = generator ?? RandomPriceGenerator()
        self.maximumBufferedMessages = maximumBufferedMessages

        observeFeedSnapshots()
    }

    isolated deinit {
        clockTask?.cancel()
        socketEventsTask?.cancel()
        webSocket.disconnect()
        if let id = sessionID {
            Task { [store] in await store.endSession(id) }
        }
        feedObservationTask?.cancel()
        connectionTask?.cancel()
        messageIngestionTask?.cancel()
        priceGenerationTask?.cancel()
        incomingMessages?.finish()
    }

    // MARK: - Feed lifecycle

    func toggleFeed() {
        if isRunning {
            stopFeed()
        } else {
            startFeed()
        }
    }

    func startFeed() {
        guard !isRunning else { return }
        let id = UUID()
        sessionID = id
        isRunning = true
        connectionState = .connecting
        startMessageIngestion(sessionID: id)
        connectSocket(sessionID: id)
    }

    func stopFeed() {
        cancelFeedWork()
        webSocket.disconnect()
        connectionState = .disconnected
    }

    private func startMessageIngestion(sessionID: UUID) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedMessages)
        )
        incomingMessages = continuation
        // One ordered consumer handles all incoming frames, rather than one Task per frame.
        messageIngestionTask = Task.detached(priority: .userInitiated) { [store] in
            await store.consume(stream, session: sessionID)
        }
    }

    private func connectSocket(sessionID: UUID) {
        connectionTask = Task { [weak self, store] in
            await store.beginSession(sessionID)
            guard !Task.isCancelled, let self, self.sessionID == sessionID else { return }
            let events = self.webSocket.connect()
            self.observeSocketEvents(events, sessionID: sessionID)
        }
    }

    private func cancelFeedWork() {
        isRunning = false
        clockTask?.cancel()
        clockTask = nil
        socketEventsTask?.cancel()
        socketEventsTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        messageIngestionTask?.cancel()
        messageIngestionTask = nil
        incomingMessages?.finish()
        incomingMessages = nil
        priceGenerationTask?.cancel()
        priceGenerationTask = nil
        if let id = sessionID {
            sessionID = nil
            Task { [store] in await store.endSession(id) }
        }
    }

    // MARK: - Socket events

    private func observeSocketEvents(_ events: SocketEventStream, sessionID: UUID) {
        socketEventsTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled, let self, self.sessionID == sessionID else { return }
                    switch event {
                    case .state(let state):
                        self.handleConnectionState(state)
                    case .message(let data):
                        self.receiveMessage(data)
                    }
                }
                guard !Task.isCancelled, let self, self.sessionID == sessionID else { return }
                // Normal completion means an explicit disconnect; transport failures throw.
                self.stopFeed()
            } catch {
                guard !Task.isCancelled, let self, self.sessionID == sessionID else { return }
                self.failFeed()
            }
        }
    }

    private func failFeed() {
        stopFeed()
        connectionState = .failed
    }

    private func receiveMessage(_ data: Data) {
        guard isRunning, connectionState == .connected else { return }
        if case .dropped = incomingMessages?.yield(data) {
            // Fail explicitly instead of silently dropping an unprocessed quote.
            logger.error("Incoming quote buffer is full; stopping the connection to avoid silently skipping prices.")
            failFeed()
        }
    }

    private func handleConnectionState(_ state: ConnectionState) {
        guard connectionState != state else { return }
        connectionState = state

        switch state {
        case .connected where isRunning:
            sendRandomUpdates()
            startClock()
        case .failed, .disconnected:
            cancelFeedWork()
        default:
            break
        }
    }

    // MARK: - Simulated outgoing prices

    private func startClock() {
        guard let id = sessionID else { return }
        clockTask?.cancel()
        let ticks = clock.ticks()
        clockTask = Task { [weak self] in
            for await _ in ticks {
                guard !Task.isCancelled, let self, self.sessionID == id else { return }
                self.sendRandomUpdates()
            }
        }
    }

    private func sendRandomUpdates() {
        guard isRunning,
              connectionState == .connected,
              priceGenerationTask == nil,
              let id = sessionID else {
            return
        }

        priceGenerationTask = Task { [weak self, store, generator] in
            let updates = await store.simulatedUpdates(using: generator)
            guard !Task.isCancelled, let self, self.sessionID == id else { return }
            for update in updates {
                self.webSocket.send(update)
            }
            self.priceGenerationTask = nil
        }
    }

    // MARK: - Feed presentation

    func resumePresentation() {
        guard feedObservationTask == nil else { return }
        observeFeedSnapshots()
    }

    func pausePresentation() {
        feedObservationTask?.cancel()
        feedObservationTask = nil
    }

    private func observeFeedSnapshots() {
        feedObservationTask?.cancel()
        let selection = sort
        feedObservationTask = Task { [weak self, store] in
            let snapshots = await store.feedSnapshots(sort: selection)
            for await snapshot in snapshots {
                guard !Task.isCancelled else { break }
                guard let self, self.sort == selection else { continue }
                self.feed = snapshot
            }
        }
    }
}
