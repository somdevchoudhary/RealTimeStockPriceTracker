//
//  StockRowView.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import SwiftUI

struct PriceChangeView: View {
    let presentation: StockPresentation

    var body: some View {
        Text(presentation.changeText ?? "—")
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityText)
            .monospacedDigit()
    }

    private var color: Color {
        switch presentation.direction {
        case .up: return .green
        case .down: return .red
        case .flat, .none: return .secondary
        }
    }

    private var accessibilityText: String {
        let label: String
        switch presentation.direction {
        case .up: label = String(localized: "Increased")
        case .down: label = String(localized: "Decreased")
        case .flat: label = String(localized: "Unchanged")
        case .none: label = String(localized: "Waiting for price change")
        }
        return label + " " + (presentation.changeText ?? "")
    }
}

struct StockRowView: View, Equatable {
    @Environment(\.locale) private var locale
    let stock: StockSymbol

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stock == rhs.stock
    }

    var body: some View {
        let presentation = StockPresentation(stock: stock, locale: locale)
        ViewThatFits(in: .horizontal) {
            horizontalLayout(presentation)
            verticalLayout(presentation)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        StockIdentityView(symbol: stock.symbol, name: stock.name).equatable()
    }

    private func horizontalLayout(_ presentation: StockPresentation) -> some View {
        HStack {
            identity
            Spacer(minLength: 12)
            prices(presentation)
        }
    }

    private func verticalLayout(_ presentation: StockPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            identity
            prices(presentation)
        }
    }

    private func prices(_ presentation: StockPresentation) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(presentation.priceText)
                .fontWeight(.semibold)
                .monospacedDigit()
            PriceChangeView(presentation: presentation).font(.caption)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Names and symbols remain unchanged when only the quote changes.
private struct StockIdentityView: View, Equatable {
    let symbol: String
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(symbol).font(.headline)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
