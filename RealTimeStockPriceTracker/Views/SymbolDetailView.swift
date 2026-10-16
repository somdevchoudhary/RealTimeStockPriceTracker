//
//  SymbolDetailView.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import SwiftUI

struct SymbolDetailView: View {
    @StateObject private var viewModel: SymbolDetailViewModel
    let symbol: String

    init(symbol: String, store: StockStore) {
        self.symbol = symbol
        _viewModel = StateObject(wrappedValue: SymbolDetailViewModel(symbol: symbol, store: store))
    }

    var body: some View {
        ScrollView {
            content
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView("Loading prices…")
        } else if let stock = viewModel.stock {
            stockDetails(stock)
        } else {
            ContentUnavailableView("Symbol not found", systemImage: "magnifyingglass")
        }
    }

    private func stockDetails(_ stock: StockSymbol) -> some View {
        VStack(spacing: 20) {
            SymbolNameView(name: stock.name).equatable()
            SymbolQuoteView(stock: stock).equatable()
            changeExplanation
            SymbolDescriptionView(descriptionKey: stock.descriptionKey).equatable()
            feedCaption
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var changeExplanation: some View {
        Text("Change since previous received price")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var feedCaption: some View {
        Text("Simulated prices • USD")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct SymbolNameView: View, Equatable {
    let name: String

    var body: some View {
        Text(name).font(.title.bold())
    }
}

/// Only quote/currency changes require reformatting; locale remains an environment dependency.
private struct SymbolQuoteView: View, Equatable {
    @Environment(\.locale) private var locale
    let stock: StockSymbol

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stock.quote == rhs.stock.quote && lhs.stock.currencyCode == rhs.stock.currencyCode
    }

    var body: some View {
        let presentation = StockPresentation(stock: stock, locale: locale)
        // Preserve the parent's spacing between the price and its change indicator.
        Group {
            Text(presentation.priceText)
                .font(.largeTitle.bold())
                .monospacedDigit()
                .accessibilityIdentifier("detailPrice")
            PriceChangeView(presentation: presentation)
        }
    }
}

private struct SymbolDescriptionView: View, Equatable {
    let descriptionKey: String

    var body: some View {
        Text(LocalizedStringKey(descriptionKey))
            .font(.body)
            .multilineTextAlignment(.leading)
    }
}
