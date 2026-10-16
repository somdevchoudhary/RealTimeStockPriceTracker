import Foundation

/// Accepts stocks://symbol/AAPL routes. Catalog membership is checked separately by the store.
nonisolated enum SymbolRoute {
    private static let allowedSymbolCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
    )
    private static let maximumSymbolByteCount = 64

    static func symbol(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "stocks",
              url.host?.lowercased() == "symbol",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 1 else { return nil }

        let symbol = pathComponents[0].uppercased()
        guard !symbol.isEmpty,
              symbol.utf8.count <= maximumSymbolByteCount,
              symbol.unicodeScalars.allSatisfy({ allowedSymbolCharacters.contains($0) }) else {
            return nil
        }
        return symbol
    }
}
