//
//  SymbolDetailViewModel.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import Foundation
import Combine

/// One subscription for this screen's symbol; unrelated quotes never reach this model.
@MainActor
final class SymbolDetailViewModel: ObservableObject {
    let symbol: String
    @Published private(set) var isLoading = true
    @Published private(set) var stock: StockSymbol?

    private var updatesTask: Task<Void, Never>?

    init(symbol: String, store: StockStore) {
        self.symbol = symbol
        observeStock(in: store)
    }

    deinit {
        updatesTask?.cancel()
    }

    private func observeStock(in store: StockStore) {
        updatesTask = Task { [weak self, store, symbol] in
            let updates = await store.stockUpdates(for: symbol)
            for await stock in updates {
                guard !Task.isCancelled else { break }
                // Compare the whole value, including previous price and its direction.
                if self?.stock != stock {
                    self?.stock = stock
                }
                if self?.isLoading == true {
                    self?.isLoading = false
                }
            }
        }
    }
}
