//
//  PriceSimulator.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import Foundation

@MainActor
protocol FeedClockType {
    /// Each consumer owns its tick sequence and cancels it when the feed stops.
    func ticks() -> AsyncStream<Void>
}

@MainActor
struct FeedClock: FeedClockType {
    var interval: TimeInterval = 2

    func ticks() -> AsyncStream<Void> {
        precondition(interval > 0 && interval.isFinite)
        let interval = Duration.seconds(interval)
        // Pull-based ticks sleep in the consumer's task: no timer, producer task, or tick backlog.
        return AsyncStream(unfolding: {
            do {
                try await Task.sleep(for: interval)
                return Task.isCancelled ? nil : ()
            } catch {
                return nil
            }
        })
    }
}

nonisolated protocol PriceGenerating: Sendable {
    func nextPrice(for stock: StockSymbol) -> Double
}

nonisolated struct RandomPriceGenerator: PriceGenerating {
    func nextPrice(for stock: StockSymbol) -> Double {
        let nextPrice: Double
        if let currentPrice = stock.price {
            nextPrice = currentPrice * Double.random(in: 0.98...1.02)
        } else {
            nextPrice = Double.random(in: 100...700)
        }
        return max(0.01, (nextPrice * 100).rounded() / 100)
    }
}
