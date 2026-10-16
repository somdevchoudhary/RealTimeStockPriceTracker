//
//  StockView.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import SwiftUI

struct StockView: View {
    @EnvironmentObject private var viewModel: StockViewModel

    var body: some View {
        VStack(spacing: 8) {
            header
            sortPicker
            feedCaption
            status
            symbolsList
        }
        .onAppear { viewModel.resumePresentation() }
        .onDisappear { viewModel.pausePresentation() }
        .navigationTitle("Stocks")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        FeedHeaderView(
            viewModel: viewModel,
            connectionState: viewModel.connectionState,
            isRunning: viewModel.isRunning
        )
        .equatable()
    }

    private var sortPicker: some View {
        Picker("Sort by", selection: $viewModel.sort) {
            Text("Price").tag(StockSort.price)
            Text("Price Change").tag(StockSort.priceChange)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("sortPicker")
        .padding(.horizontal)
    }

    private var feedCaption: some View {
        Text("Simulated prices • USD • Highest first")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var status: some View {
        FeedStatusView(
            isLoading: viewModel.isLoadingPrices,
            showsStartHint: showsStartHint,
            hasFailed: viewModel.connectionState == .failed
        )
        .equatable()
    }

    private var showsStartHint: Bool {
        !viewModel.isRunning
            && viewModel.connectionState != .failed
            && viewModel.feed.missingPriceCount == viewModel.feed.rows.count
    }

    private var symbolsList: some View {
        List(viewModel.sortedSymbols) { stock in
            NavigationLink(value: stock.symbol) {
                StockRowView(stock: stock).equatable()
            }
            .accessibilityIdentifier("stock-" + stock.symbol)
        }
        .listStyle(.plain)
    }
}

/// The model reference supplies actions only; this view does not observe quote publications.
private struct FeedHeaderView: View, Equatable {
    let viewModel: StockViewModel
    let connectionState: ConnectionState
    let isRunning: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.connectionState == rhs.connectionState
            && lhs.isRunning == rhs.isRunning
    }

    var body: some View {
        HStack {
            connectionIndicator
            connectionLabel
            Spacer()
            feedToggle
        }
        .padding([.horizontal, .top])
    }

    private var connectionIndicator: some View {
        Circle()
            .fill(connectionState == .connected ? Color.green : Color.red)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }

    private var connectionLabel: some View {
        connectionText
            .font(.caption)
            .accessibilityIdentifier("connectionStatus")
    }

    private var connectionText: Text {
        switch connectionState {
        case .connected: return Text("Connected")
        case .connecting: return Text("Connecting…")
        case .disconnected, .failed: return Text("Disconnected")
        }
    }

    private var feedToggle: some View {
        Button(action: viewModel.toggleFeed) {
            if isRunning {
                Text("Stop")
            } else {
                Text("Start")
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("feedToggle")
    }
}

/// Quote changes do not rebuild status content while these three flags remain unchanged.
private struct FeedStatusView: View, Equatable {
    let isLoading: Bool
    let showsStartHint: Bool
    let hasFailed: Bool

    var body: some View {
        if isLoading {
            ProgressView("Loading prices…")
                .font(.caption)
                .accessibilityIdentifier("priceLoading")
        } else if showsStartHint {
            Text("Tap Start to load prices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if hasFailed {
            Text("Connection lost. Tap Start to retry.")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }
}
