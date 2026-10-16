//
//  StockPresentation.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import Foundation

/// Direction relative to the immediately preceding received price.
enum PriceChangeDirection {
    case up
    case down
    case flat
    case none
}

/// Locale-aware display strings shared by the feed and detail screen.
struct StockPresentation {
    let symbol: String
    let priceText: String
    let changeSymbol: String?
    let changeText: String?
    let direction: PriceChangeDirection

    init(stock: StockSymbol, locale: Locale = .current) {
        symbol = stock.symbol
        let currency = FloatingPointFormatStyle<Double>.Currency(code: stock.currencyCode)
            .precision(.fractionLength(2))
            .locale(locale)
        priceText = stock.price.map { $0.formatted(currency) } ?? "—"
        guard let change = stock.change else {
            direction = .none
            changeSymbol = nil
            changeText = nil
            return
        }
        let indicator: String
        if change == 0 {
            direction = .flat
            indicator = "="
        } else if change > 0 {
            direction = .up
            indicator = "↑"
        } else {
            direction = .down
            indicator = "↓"
        }
        changeSymbol = indicator

        let amount = abs(change).formatted(currency)
        let percentage = stock.percentageChange.map {
            abs($0).formatted(
                .percent.precision(.fractionLength(2)).locale(locale)
            )
        }
        changeText = "\(indicator) \(amount)" + (percentage.map { " (\($0))" } ?? "")
    }
}
