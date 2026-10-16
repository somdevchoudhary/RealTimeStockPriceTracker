import Foundation

nonisolated enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

/// State changes and data share one sequence so their relative order is preserved.
nonisolated enum SocketEvent: Sendable {
    case state(ConnectionState)
    case message(Data)
}

typealias SocketEventStream = AsyncThrowingStream<SocketEvent, Error>

@MainActor
protocol WebSocketServiceType: AnyObject {
    /// Each connection has one consumer and its own bounded stream.
    /// Explicit disconnect finishes normally; connection loss and overflow throw.
    func connect() -> SocketEventStream
    func disconnect()
    func send(_ message: PriceUpdate)
}

/// Coordinates connection state and serial outgoing sends; the transport owns URLSession work.
@MainActor
final class WebSocketService: WebSocketServiceType {
    // MARK: - Dependencies

    private let url: URL
    private let makeTransport: @MainActor () -> any WebSocketTransportType
    private let maximumBufferedEvents: Int
    private let encoder = PriceUpdateEncoder()

    // MARK: - Connection and outgoing queue

    private(set) var connectionState: ConnectionState = .disconnected
    private var transport: (any WebSocketTransportType)?
    private var transportEventsTask: Task<Void, Never>?
    private var eventContinuation: SocketEventStream.Continuation?
    private var generation = UUID()
    private var sender: Task<Void, Never>?
    private var pending: PendingPriceQueue

    var pendingSendCount: Int { pending.count }

    init(
        url: URL = URL(string: "wss://ws.postman-echo.com/raw")!,
        allowedSymbols: Set<String>,
        maximumBufferedEvents: Int = 2_048,
        makeTransport: @escaping @MainActor () -> any WebSocketTransportType = {
            URLSessionWebSocketTransport()
        }
    ) {
        precondition(maximumBufferedEvents > 0)
        self.url = url
        self.makeTransport = makeTransport
        self.maximumBufferedEvents = maximumBufferedEvents
        pending = PendingPriceQueue(allowedSymbols: allowedSymbols)
    }

    isolated deinit {
        sender?.cancel()
        transportEventsTask?.cancel()
        eventContinuation?.finish()
        transport?.disconnect()
    }

    // MARK: - Connection lifecycle

    func connect() -> SocketEventStream {
        // A repeated connect does not create a second consumer for the active session.
        guard transport == nil else { return SocketEventStream { $0.finish() } }
        let connectionID = UUID()
        generation = connectionID
        let (events, continuation) = SocketEventStream.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedEvents)
        )
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == connectionID else { return }
                self.disconnect()
            }
        }
        eventContinuation = continuation
        connectionState = .connecting
        emit(.state(.connecting))

        let transport = makeTransport()
        self.transport = transport
        observeTransport(transport.connect(to: url), connectionID: connectionID)
        return events
    }

    func disconnect() {
        closeConnection(state: .disconnected)
    }

    private func closeConnection(state: ConnectionState, error: Error? = nil) {
        // Invalidate old callbacks before cancelling their work.
        generation = UUID()
        sender?.cancel()
        sender = nil
        pending.removeAll()
        transportEventsTask?.cancel()
        transportEventsTask = nil
        transport?.disconnect()
        transport = nil
        connectionState = state
        let continuation = eventContinuation
        eventContinuation = nil
        // Throwing completion remains observable even when the buffer is full.
        continuation?.finish(throwing: error)
    }

    private func observeTransport(_ events: WebSocketEventStream, connectionID: UUID) {
        transportEventsTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled, let self, self.generation == connectionID else { return }
                    self.handleTransportEvent(event)
                }
                guard !Task.isCancelled, let self, self.generation == connectionID else { return }
                self.failConnection(SocketStreamError.connectionLost)
            } catch {
                guard !Task.isCancelled, let self, self.generation == connectionID else { return }
                self.failConnection(error)
            }
        }
    }

    private func handleTransportEvent(_ event: WebSocketEvent) {
        switch event {
        case .opened:
            connectionState = .connected
            emit(.state(.connected))
        case .message(let data):
            guard connectionState == .connected else { return }
            emit(.message(data))
        case .closed, .failed:
            failConnection(SocketStreamError.connectionLost)
        }
    }

    private func emit(_ event: SocketEvent) {
        if case .dropped = eventContinuation?.yield(event) {
            failConnection(SocketStreamError.bufferOverflow)
        }
    }

    private func failConnection(_ error: Error) {
        closeConnection(state: .failed, error: error)
    }

    // MARK: - Serial sending

    func send(_ message: PriceUpdate) {
        guard connectionState == .connected,
              message.price.isFinite,
              message.price > 0 else {
            return
        }
        guard pending.enqueue(message) else { return }
        startSenderIfNeeded()
    }

    private func startSenderIfNeeded() {
        guard sender == nil else { return }
        let connectionID = generation

        sender = Task { [weak self, encoder] in
            while !Task.isCancelled {
                guard let self,
                      self.generation == connectionID,
                      let transport = self.transport else {
                    return
                }
                guard let update = self.pending.pop() else {
                    self.sender = nil
                    return
                }
                do {
                    let data = try await encoder.encode(update)
                    guard !Task.isCancelled, self.generation == connectionID else { return }
                    try await transport.send(data)
                } catch {
                    guard self.generation == connectionID, !Task.isCancelled else { return }
                    self.failConnection(error)
                    return
                }
            }
        }
    }
}

private actor PriceUpdateEncoder {
    private let encoder = JSONEncoder()

    func encode(_ update: PriceUpdate) throws -> Data {
        try encoder.encode(update)
    }
}
