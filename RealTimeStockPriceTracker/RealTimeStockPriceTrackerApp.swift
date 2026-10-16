import SwiftUI
import Combine

@main
struct RealTimeStockPriceTrackerApp: App {
    @StateObject private var dependencies = AppDependencies()
    @StateObject private var navigation = AppNavigation()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $navigation.path) {
                StockView()
                    .navigationDestination(for: String.self) { symbol in
                        SymbolDetailView(symbol: symbol, store: dependencies.store).id(symbol)
                    }
            }
            .environmentObject(dependencies.stockViewModel)
            .onOpenURL { url in
                guard let symbol = SymbolRoute.symbol(from: url) else { return }
                Task { @MainActor in
                    guard await dependencies.store.stock(for: symbol) != nil else { return }
                    navigation.path = [symbol]
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    navigation.resumeOnForeground = dependencies.stockViewModel.isRunning
                    dependencies.stockViewModel.stopFeed()
                } else if phase == .active, navigation.resumeOnForeground {
                    navigation.resumeOnForeground = false
                    dependencies.stockViewModel.startFeed()
                }
            }
        }
    }
}

/// Lifetime owner only; quote mutations do not invalidate the root view.
@MainActor
private final class AppDependencies: ObservableObject {
    let store: StockStore
    let stockViewModel: StockViewModel

    init() {
        let catalog = SymbolCatalog.stocks
        let allowedSymbols = Set(catalog.map(\.symbol))
        store = StockStore(symbols: catalog)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            stockViewModel = StockViewModel(store: store,
                webSocket: WebSocketService(allowedSymbols: allowedSymbols, makeTransport: { UITestEchoTransport() }),
                clock: FeedClock(interval: 0.25), generator: UITestPriceGenerator())
        } else {
            stockViewModel = StockViewModel(store: store, webSocket: WebSocketService(allowedSymbols: allowedSymbols))
        }
        #else
        stockViewModel = StockViewModel(store: store, webSocket: WebSocketService(allowedSymbols: allowedSymbols))
        #endif
    }
}

@MainActor
private final class AppNavigation: ObservableObject {
    @Published var path: [String] = []
    var resumeOnForeground = false
}
