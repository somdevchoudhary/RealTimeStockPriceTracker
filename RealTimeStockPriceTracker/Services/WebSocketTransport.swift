//
//  WebSocketTransport.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import Foundation
import OSLog

/// Transport events are delivered on the main actor, including URLSession delegate events.
nonisolated enum WebSocketEvent: Sendable {
    case opened
    case message(Data)
    case closed
    case failed
}

typealias WebSocketEventStream = AsyncThrowingStream<WebSocketEvent, Error>

nonisolated enum SocketStreamError: Error, Equatable {
    case bufferOverflow
    case connectionLost
}

@MainActor
protocol WebSocketTransportType: AnyObject {
    func connect(to url: URL) -> WebSocketEventStream
    func disconnect()
    func send(_ data: Data) async throws
}

/// One instance per connection attempt; callbacks from old instances cannot affect a new socket.
@MainActor
final class URLSessionWebSocketTransport: NSObject, WebSocketTransportType, URLSessionWebSocketDelegate {
    private let logger = Logger(subsystem: "com.realtimepricetracker", category: "WebSocket")
    private let maximumBufferedEvents: Int
    private var eventContinuation: WebSocketEventStream.Continuation?
    private var generation = UUID()

    init(maximumBufferedEvents: Int = 2_048) {
        precondition(maximumBufferedEvents > 0)
        self.maximumBufferedEvents = maximumBufferedEvents
        super.init()
    }

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var openingTimeout: Task<Void, Never>?
    private var opened = false

    // MARK: - Connection lifecycle

    func connect(to url: URL) -> WebSocketEventStream {
        guard socket == nil else { return WebSocketEventStream { $0.finish() } }
        let connectionID = UUID()
        generation = connectionID
        let (events, continuation) = WebSocketEventStream.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedEvents)
        )
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == connectionID else { return }
                self.disconnect()
            }
        }
        eventContinuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 4 * 1_024
        self.socket = socket
        socket.resume()
        startOpeningTimeout(for: socket)
        startReceiving(from: socket)
        return events
    }

    func disconnect() {
        closeConnection()
    }

    private func closeConnection(error: Error? = nil) {
        generation = UUID()
        receiver?.cancel()
        receiver = nil
        openingTimeout?.cancel()
        openingTimeout = nil
        let oldSocket = socket
        socket = nil
        opened = false
        oldSocket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        let continuation = eventContinuation
        eventContinuation = nil
        continuation?.finish(throwing: error)
    }

    func send(_ data: Data) async throws {
        guard opened, let socket else {
            throw URLError(.notConnectedToInternet)
        }
        do {
            // Use UTF-8 JSON text frames for compatibility with the required echo endpoint.
            try await socket.send(WebSocketMessageCodec.outgoingJSON(data))
        } catch {
            logFailure(error, stage: "send")
            throw error
        }
    }

    // MARK: - Opening timeout and receive loop

    private func startOpeningTimeout(for socket: URLSessionWebSocketTask) {
        openingTimeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self, self.socket === socket, !self.opened else { return }
            self.logFailure(URLError(.timedOut), stage: "opening")
            self.finish(.failed)
        }
    }

    private func startReceiving(from socket: URLSessionWebSocketTask) {
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard !Task.isCancelled, let self, self.socket === socket else { return }
                    self.handleIncomingMessage(message)
                } catch {
                    guard !Task.isCancelled, let self, self.socket === socket else { return }
                    self.logFailure(error, stage: "receive")
                    self.finish(.failed)
                    return
                }
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            emit(.message(data))
        case .string(let text):
            emit(.message(Data(text.utf8)))
        @unknown default:
            break
        }
    }

    // MARK: - Completion and diagnostics

    private func logFailure(_ error: Error, stage: String) {
        let failure = error as NSError
        let status = (socket?.response as? HTTPURLResponse)?.statusCode ?? 0
        logger.error("WebSocket \(stage, privacy: .public) failed: \(failure.domain, privacy: .public) code=\(failure.code) HTTP=\(status)")
    }

    private func emit(_ event: WebSocketEvent) {
        if case .dropped = eventContinuation?.yield(event) {
            closeConnection(error: SocketStreamError.bufferOverflow)
        }
    }

    private func finish(_ event: WebSocketEvent) {
        emit(event)
        closeConnection()
    }

    // MARK: - URLSession delegate callbacks

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === webSocketTask else { return }
            self.opened = true
            self.openingTimeout?.cancel()
            self.openingTimeout = nil
            self.emit(.opened)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === webSocketTask else { return }
            self.finish(.closed)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === task else { return }
            if let error {
                self.logFailure(error, stage: "completion")
            }
            self.finish(error == nil ? .closed : .failed)
        }
    }
}

/// Keeps the JSON wire format explicit and testable independently of a network connection.
enum WebSocketMessageCodec {
    static func outgoingJSON(_ data: Data) throws -> URLSessionWebSocketTask.Message {
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                data,
                .init(codingPath: [], debugDescription: "Expected UTF-8 JSON")
            )
        }
        return .string(text)
    }
}
