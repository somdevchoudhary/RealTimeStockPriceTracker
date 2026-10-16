import Foundation

/// Fixed assessment universe. No market prices are bundled with the catalog.
nonisolated enum SymbolCatalog {
    static let stocks: [StockSymbol] = [
        (symbol: "AAPL", name: "Apple"),
        (symbol: "GOOG", name: "Alphabet"),
        (symbol: "TSLA", name: "Tesla"),
        (symbol: "AMZN", name: "Amazon"),
        (symbol: "MSFT", name: "Microsoft"),
        (symbol: "NVDA", name: "NVIDIA"),
        (symbol: "META", name: "Meta Platforms"),
        (symbol: "BABA", name: "Alibaba Group"),
        (symbol: "ORCL", name: "Oracle"),
        (symbol: "NFLX", name: "Netflix"),
        (symbol: "INTC", name: "Intel"),
        (symbol: "QCOM", name: "Qualcomm"),
        (symbol: "IBM", name: "IBM"),
        (symbol: "AMD", name: "AMD"),
        (symbol: "ADBE", name: "Adobe"),
        (symbol: "CRM", name: "Salesforce"),
        (symbol: "SHOP", name: "Shopify"),
        (symbol: "PYPL", name: "PayPal"),
        (symbol: "PEP", name: "PepsiCo"),
        (symbol: "KO", name: "Coca-Cola"),
        (symbol: "V", name: "Visa"),
        (symbol: "MA", name: "Mastercard"),
        (symbol: "UBER", name: "Uber"),
        (symbol: "LYFT", name: "Lyft"),
        (symbol: "SPOT", name: "Spotify")
    ].map { entry in
        StockSymbol(
            symbol: entry.symbol,
            name: entry.name,
            descriptionKey: "description." + entry.symbol
        )
    }
}
