import Foundation

/// Stable catalog information, stored separately from changing prices.
nonisolated struct StockMetadata: Sendable, Equatable {
    let symbol: String
    let name: String
    let descriptionKey: String
    let currencyCode: String
}

/// Latest price and its immediately preceding received price; no price history is retained.
nonisolated struct StockQuote: Sendable, Equatable {
    let price: Double?
    let previousPrice: Double?

    var change: Double? {
        guard let price, let previousPrice else { return nil }
        return ((price - previousPrice) * 100).rounded() / 100
    }

    /// Fractional change: 0.05 represents 5% when formatted as a percentage.
    var percentageChange: Double? {
        guard let change, let previousPrice, previousPrice > 0 else { return nil }
        return change / previousPrice
    }
}

/// Immutable UI snapshot. Its symbol remains the same identity across quote updates.
nonisolated struct StockSymbol: Identifiable, Equatable, Sendable {
    let metadata: StockMetadata
    let quote: StockQuote

    var id: String { symbol }
    var symbol: String { metadata.symbol }
    var name: String { metadata.name }
    var descriptionKey: String { metadata.descriptionKey }
    var currencyCode: String { metadata.currencyCode }
    var price: Double? { quote.price }
    var previousPrice: Double? { quote.previousPrice }
    var change: Double? { quote.change }
    var percentageChange: Double? { quote.percentageChange }

    init(metadata: StockMetadata, quote: StockQuote) {
        self.metadata = metadata
        self.quote = quote
    }

    init(
        symbol: String,
        name: String = "",
        descriptionKey: String = "",
        currencyCode: String = "USD",
        price: Double? = nil,
        previousPrice: Double? = nil
    ) {
        metadata = StockMetadata(
            symbol: symbol,
            name: name.isEmpty ? symbol : name,
            descriptionKey: descriptionKey,
            currencyCode: currencyCode
        )
        quote = StockQuote(price: price, previousPrice: previousPrice)
    }
}

nonisolated enum StockSort: String, CaseIterable, Identifiable, Sendable {
    case price
    case priceChange

    var id: Self { self }
}

/// One sorted feed publication, shared by subscribers using the same sort order.
nonisolated struct FeedSnapshot: Sendable {
    let rows: [StockSymbol]
    let sort: StockSort
    let revision: UInt64
    let missingPriceCount: Int

    static let empty = FeedSnapshot(
        rows: [],
        sort: .price,
        revision: 0,
        missingPriceCount: 0
    )
}
