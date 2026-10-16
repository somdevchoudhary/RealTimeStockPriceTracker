//
//  PriceUpdate.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import Foundation

/// JSON message sent to, and received from, the echo server.
nonisolated struct PriceUpdate: Codable, Equatable, Sendable {
    let symbol: String
    let price: Double
}

/// Decodes valid positive prices. The store also enforces catalog membership and cent rounding.
nonisolated enum PriceUpdateCodec {
    static func decode(_ data: Data) -> PriceUpdate? {
        guard let update = try? JSONDecoder().decode(PriceUpdate.self, from: data) else {
            return nil
        }
        guard update.price.isFinite, update.price > 0 else {
            return nil
        }
        return update
    }
}
