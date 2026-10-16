# Real-Time Stock Price Tracker

A SwiftUI iOS app that displays live simulated prices for 25 stock symbols, with sorting, symbol details, and deep-link navigation. A shared actor keeps the Stocks and detail screens consistent while asynchronous services handle the price feed.

Prices are **simulated**. The app generates updates locally, sends them as JSON text messages to `wss://ws.postman-echo.com/raw`, and displays the echoed responses. This endpoint echoes messages; it does not supply stock-market data.

## Getting started

- **Minimum OS:** iOS 17.6 for the app and test targets.
- **Verified toolchain:** Xcode 27.0; Swift 5 language mode with modern Swift concurrency features.
- **Dependencies:** Apple frameworks only. No API key or third-party package installation is required.
- **Network:** Required for normal app use. Unit and UI tests use offline dependencies.

1. Open `RealTimeStockPriceTracker.xcodeproj`.
2. Select the `RealTimeStockPriceTracker` scheme and a compatible simulator or device. Select your development team when running on a physical device.
3. Build and run. On **Stocks**, tap **Start** to connect and load prices.

## Features and behavior

| Feature | Behavior |
| --- | --- |
| Stocks screen | `StockView` displays a scrollable catalog with symbol codes, company names, prices, and change indicators. |
| Sorting | Price or price change in currency units, highest first. Positive changes rank above negative changes; symbols break ties, and unavailable values appear last. |
| Symbol details | `SymbolDetailView` uses the selected symbol as its title and displays its name, live quote, change indicator, and description area. |
| Start / Stop | Start connects and generates an initial batch. Stop disconnects and retains the last accepted prices. Connection failures can be retried with Start. |
| Connection status | The screen distinguishes connecting, connected, and disconnected states, with a retry message after failure. |
| App lifecycle | A running feed stops in the background and resumes when the app becomes active. A manually stopped feed remains stopped. |
| Deep links | A custom URL scheme navigates directly to a known stock's detail screen using its symbol code. |

A price is unavailable until its first valid echo arrives. Changes compare the current price with the **previous received price**, rather than the previous market close. Percentage change is calculated as a fraction and displayed using percentage formatting. A change is unavailable until both prices exist.

## Deep links

The app registers the `stocks` URL scheme in `Info.plist`.

```text
stocks://symbol/<SYMBOL>

stocks://symbol/AAPL   → Apple detail screen, titled AAPL
stocks://symbol/NVDA   → NVIDIA detail screen, titled NVDA
```

`RealTimeStockPriceTrackerApp.onOpenURL` passes the URL to `Navigation/SymbolRoute.swift`. The route parser validates the scheme, host, and single symbol path, then normalizes the code to uppercase. The app checks that the symbol exists in `StockStore` before setting the navigation path to that symbol. Invalid URLs and unknown symbols leave the current navigation unchanged.

For example, `stocks://symbol/aapl` resolves to `AAPL`. URLs with extra path components, query parameters, or fragments are rejected.

With the app installed on a booted simulator, open a detail screen from Terminal:

```sh
xcrun simctl openurl booted "stocks://symbol/AAPL"
```

Detail navigation reuses the shared store and does not itself start the price feed. If the feed is running, the linked detail screen continues receiving live updates. If prices have not loaded, the screen shows the available metadata while quote values remain unavailable.

## Architecture and data flow

The app uses MVVM for screen state and an actor for shared stock data. `AppDependencies`, defined in `RealTimeStockPriceTrackerApp.swift`, assembles dependencies once. `AppNavigation` owns the navigation path and foreground-resume flag.

| Component | Responsibility |
| --- | --- |
| `Models/SymbolCatalog.swift` | Fixed assessment catalog: symbol codes, company names, and description keys. |
| `Models/StockSymbol.swift` | Immutable stock metadata and quote values, change calculations, sort options, and feed snapshots. |
| `Models/PriceUpdate.swift` | Codable price-update payload and decoding helper. |
| `Stores/StockStore.swift` | Authoritative metadata and quotes, ordered ingestion, validation, previous-price tracking, sorted snapshots, and selected-symbol subscriptions. |
| `ViewModels/StockViewModel.swift` | Stocks screen state, connection lifecycle, message ingestion, clock consumption, generation, and sort selection. |
| `ViewModels/SymbolDetailViewModel.swift` | One selected-symbol subscription, with duplicate-state suppression and cancellation on release. |
| `Services/WebSocketService.swift` | Ordered async connection/message events and serial outgoing sends through a catalog-bound queue. |
| `Services/WebSocketTransport.swift` | URLSession handshake, receive loop, opening timeout, message limits, and explicit JSON text-frame encoding. |
| `Services/PriceSimulator.swift` | `RandomPriceGenerator`, `PriceGenerating`, and the cancellable async tick sequence supplied by `FeedClock`. |
| `Services/PendingPriceQueue.swift` | Latest unsent price per allowed symbol, preserving pending-symbol order. |
| `Presentation/StockPresentation.swift` | Locale-aware price, currency-change, percentage, and direction presentation shared by both screens. |
| `Navigation/SymbolRoute.swift` | URL-scheme parsing and symbol syntax validation. |
| `DebugSupport/UITestDependencies.swift` | Debug-only `UITestEchoTransport` and predictable `UITestPriceGenerator`. |

```text
StockStore → simulated price generation → PendingPriceQueue
                                               ↓
                                    WebSocket JSON text message
                                               ↓
                                         Postman echo
                                               ↓
Transport events → service events → ordered store-ingress stream
                                               ↓
                                           StockStore
                                               ↓
                        StockViewModel / SymbolDetailViewModel
                                               ↓
                              StockView / SymbolDetailView
```

Generating or sending a price does not update the displayed quote directly. The store processes its echoed response, validates the symbol and price, rounds to cents, and publishes the resulting state.

Services use `AsyncStream` and `AsyncThrowingStream`; WebSocket send/receive operations use async/await. State transitions and messages share one ordered service stream per connection. Clock ticks sleep in the consuming task. Combine remains for SwiftUI observable screen state, while URLSession delegate callbacks stay inside the transport.

## Performance and memory

- **Shared ownership:** One actor stores stable metadata separately from current and previous quotes. There is no observable object or task per catalog stock, and no unbounded price history.
- **Batched list updates:** The first quote publishes promptly; subsequent Stocks-screen changes use a 100 ms publication interval. Snapshots are reused for subscribers with the same sort order. Simulation runs immediately after connection and then every two seconds.
- **Targeted details:** Only the selected symbol reaches its detail model. Stocks-screen presentation pauses while hidden, while ingestion and detail updates continue.
- **Bounded streams:** Transport and service buffers each hold up to 2,048 ordered events; store ingress holds up to 2,048 frames. Transport messages are limited to 4 KiB. Overflow fails explicitly, and terminal errors remain observable even when a buffer is full. UI streams retain only the latest value.
- **Bounded outgoing work:** The queue retains one latest unsent value per catalog symbol, plus one separate in-flight send. Unknown outgoing symbols are ignored. Dequeue uses a head index and occasional compaction.
- **View boundaries:** Stable identities and equality checks allow unchanged rows, controls, names, and descriptions to skip unnecessary body evaluations while quote and locale updates remain supported.
- **Lifecycle safety:** Task cancellation, session identifiers, connection generations, weak captures, and stream cleanup prevent cancelled work from changing a restarted session. Cancelling a socket consumer disconnects its transport.

Accepted incoming quotes are processed in order. Pending outgoing prices and UI snapshots may coalesce under load; the UI does not guarantee a distinct rendered frame for every intermediate tick.

## Testing and CI

The current suite contains **37 unit tests and 2 UI tests**. Both targets run offline; there is no real-connection unit test.

Unit tests inject `MockSocket`, `FakeTransport`, `ManualClock`, and `FixedGenerator`. They cover quote validation and rounding, previous-price semantics, sorting, route validation, snapshot reuse, 1,000-symbol bursts, bounded buffers, event ordering, failures, Stop/restart, stale work, and subscription cleanup. Socket tests exercise the real service with a fake network transport.

UI tests cover sorting, navigation, live detail prices, and retained prices after Stop. They launch with:

```swift
app.launchArguments = ["--ui-testing"]
```

In a Debug build, `AppDependencies` detects that flag and selects `UITestEchoTransport`, `UITestPriceGenerator`, and a 0.25-second clock. The transport echoes data in memory, while the real service, store, view models, and views remain in use. Language and locale are inherited from the simulator; no launch overrides are applied. Normal launches use the URLSession transport and random generator.

Run **Product → Test** in Xcode, or use this command from the repository root on a CI machine with the required Xcode and simulator runtime:

```sh
xcodebuild test \
  -project RealTimeStockPriceTracker.xcodeproj \
  -scheme RealTimeStockPriceTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

Replace the simulator name with one installed on the machine.

## Project layout

```text
.
├── .gitignore
├── README.md
├── RealTimeStockPriceTracker.xcodeproj/
├── RealTimeStockPriceTracker/
│   ├── RealTimeStockPriceTrackerApp.swift
│   ├── Info.plist
│   ├── Models/
│   │   ├── PriceUpdate.swift
│   │   ├── StockSymbol.swift
│   │   └── SymbolCatalog.swift
│   ├── Stores/
│   │   └── StockStore.swift
│   ├── Services/
│   │   ├── PendingPriceQueue.swift
│   │   ├── PriceSimulator.swift
│   │   ├── WebSocketService.swift
│   │   └── WebSocketTransport.swift
│   ├── Navigation/
│   │   └── SymbolRoute.swift
│   ├── Presentation/
│   │   └── StockPresentation.swift
│   ├── ViewModels/
│   │   ├── StockViewModel.swift
│   │   └── SymbolDetailViewModel.swift
│   ├── Views/
│   │   ├── SplashView.swift
│   │   ├── StockRowView.swift
│   │   ├── StockView.swift
│   │   └── SymbolDetailView.swift
│   ├── DebugSupport/
│   │   └── UITestDependencies.swift
│   └── Assets.xcassets/
├── RealTimeStockPriceTrackerTests/
│   └── RealTimeStockPriceTrackerTests.swift
└── RealTimeStockPriceTrackerUITests/
    └── RealTimeStockPriceTrackerUITests.swift
```

`.gitignore` excludes local Xcode settings, macOS metadata, build output, and package build caches while keeping shared project settings, schemes, and dependency lockfiles trackable.

## Current scope

This assessment uses a fixed catalog, simulated USD prices, in-memory state, and manual retry. Formatting respects the current locale. Description keys are available in metadata, but localized company-description resources are not currently bundled. `SplashView` is a standalone component; the app currently opens directly on Stocks.

Production extensions include a market-data provider, a server-supplied catalog, localized descriptions, regional market/currency rules, persistence, authentication, and a defined reconnect policy. Dependency injection and the shared store provide boundaries for those additions.
