# Real-Time Stock Price Tracker

A SwiftUI iOS app that demonstrates live price updates for 25 stock symbols, shared state across feed and detail screens, and a bounded, testable WebSocket pipeline.

Prices are **simulated**. The app generates prices locally, sends them to `wss://ws.postman-echo.com/raw`, and displays the echoed responses. The endpoint returns the messages it receives; it does not provide market data.

## Getting started

- **Deployment target:** iOS 17.6 or later.
- **Verified toolchain:** Xcode 27. The project uses Swift 5 language mode with modern Swift concurrency features.
- **Dependencies:** Apple frameworks only; no API key or third-party package installation is required.
- **Connectivity:** Internet access is required for the normal WebSocket feed. Automated UI tests use an offline echo transport.

1. Open `RealTimeStockPriceTracker.xcodeproj` in Xcode.
2. Select the `RealTimeStockPriceTracker` scheme and a compatible simulator or device. For a physical device, select your signing team.
3. Build and run, then tap **Start** to connect and load prices.

## App behavior

- **Feed:** A scrollable catalog of 25 symbols shows company names, current prices, and price-change indicators.
- **Sorting:** Sort by price or price change in currency units, highest first. Positive changes rank above negative changes; symbols break ties, and missing values appear last.
- **Details:** Selecting a symbol opens its current price, change indicator, and description area. The selected quote continues updating while this screen is open.
- **Connection controls:** Start opens the connection; Stop disconnects and retains the last accepted prices. A failed connection stops the feed and can be retried with Start.
- **Lifecycle:** An active feed stops when the app enters the background and resumes when the app becomes active again.
- **Deep links:** `stocks://symbol/AAPL` opens a catalog symbol. Invalid routes and unknown symbols are rejected.

Changes are measured against the **previous received price**, rather than the previous market close. A price remains unavailable until its first valid echo arrives; a change remains unavailable until there is a previous price to compare.

## Architecture

The app combines MVVM presentation with an actor that owns stock data. Dependencies are assembled once at the app entry point and injected into the feed and detail flows. Services use async sequences: socket state and data travel through one ordered stream per connection, while clock ticks are consumed in a cancellable task. Combine is retained only for SwiftUI observable screen state. URLSession delegate callbacks remain encapsulated inside the transport.

| Component | Responsibility |
| --- | --- |
| `SymbolCatalog` and models | Define the symbol universe, stable metadata, quote values, message payloads, and feed snapshots. |
| `StockStore` | Own metadata and quotes; decode and validate incoming messages; maintain previous prices; publish sorted feed snapshots and symbol-specific updates. |
| `FeedViewModel` | Coordinate connection state, the simulation clock, ordered message ingestion, sorting selection, and feed presentation. |
| `SymbolDetailViewModel` | Observe only the selected symbol and release its subscription when the model is released. |
| `WebSocketService` | Expose ordered connection-state/message events through an async stream; serialize outgoing sends through the catalog-bound queue. |
| `URLSessionWebSocketTransport` | Manage the handshake, receive loop, timeout, text frames, and URLSession callbacks. |
| `StockPresentation` and views | Format locale-aware display values and present immutable snapshots. |

### Price-update flow

```text
Catalog + current quotes
         ↓
Local price generation → outgoing queue → WebSocket text message
                                                   ↓
                                            Postman echo
                                                   ↓
Views ← view models ← StockStore ← ordered incoming-message stream
```

Generating or sending a price does not directly update the UI. The store accepts the echoed message, validates its symbol and price, rounds the price to cents, and then publishes the resulting state.

## Performance and memory

- **One shared store:** Metadata and current/previous prices are held separately. There is no observable object or task for every stock, and no unbounded price history.
- **Batched feed presentation:** The first quote publishes promptly. Subsequent feed changes are grouped using a 100 ms publication interval, with snapshots reused for subscribers using the same sort order. Simulation batches are generated immediately after connection and then every two seconds.
- **Targeted detail updates:** Only the selected symbol reaches its detail model. Feed presentation pauses while the feed screen is hidden, while ingestion and detail updates continue.
- **Bounded buffers:** UI streams retain the latest value. Transport and service event streams each buffer at most 2,048 ordered events; store ingress buffers at most 2,048 frames. The transport limits each message to 4 KiB. Overflow at any incoming boundary terminates the feed explicitly rather than silently skipping unprocessed quotes. Stream errors remain observable even when their buffers are full.
- **Catalog-bound outgoing queue:** At most one unsent value is retained per catalog symbol, plus one separate in-flight send. Repeated pending values are replaced with the latest value; unknown outgoing symbols are ignored. Dequeue uses a head index and occasional compaction.
- **Controlled view updates:** Stable symbol identities and equality boundaries let unchanged rows, controls, names, and descriptions skip unnecessary body evaluations. These boundaries preserve quote and locale updates.
- **Cancellation safety:** Session identifiers, connection generations, weak captures, and stream termination cleanup prevent stale work from changing a restarted feed. Cancelling a socket consumer disconnects its transport. Clock ticks sleep inside the consuming task, so stopping cancels the wait without a separate timer or producer task.

The store processes accepted incoming quotes in order. Under load, outgoing pending values and UI snapshots may coalesce; the UI does not promise a separately rendered frame for every intermediate tick.

## Testing

The unit-test suite uses in-memory socket mocks, fake transports, controllable clocks, and fixed price generators. It does not open real WebSocket connections or require internet access.

| Area | Coverage |
| --- | --- |
| Store | Price validation, cent rounding, previous-price semantics, both sorts, stable ordering, batched publication, snapshot reuse, and 1,000-symbol bursts. |
| Lifecycle and memory | Cancellation, rapid Stop/restart, stale sessions, model release, and subscriber cleanup. |
| Socket | Catalog bounds, pending-value replacement, 1,000-symbol sends, unknown symbols, text encoding, send failures, stale connection work, ordered events, stream overflow, and consumer cancellation. |
| UI | Sorting, navigation, live detail updates, and stable retained prices after Stop. |

Socket service tests exercise the real service with an injected `FakeTransport`; view-model tests use `MockSocket` or that fake transport with a `ManualClock`. Echoes, failures, and connection events are driven entirely in memory. UI tests launch with `--ui-testing`, using an offline echo transport and predictable prices. Both test targets run offline.

Run all tests with **Product → Test** in Xcode, or from the repository root:

```sh
xcodebuild test \
  -project RealTimeStockPriceTracker.xcodeproj \
  -scheme RealTimeStockPriceTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

Replace the simulator name with one installed on the test machine. This command can also be used by a CI runner with the required Xcode toolchain and simulator runtime.

## Project layout

```text
RealTimeStockPriceTracker/
├── RealTimeStockPriceTrackerApp.swift   # Composition, navigation, app lifecycle
├── Models/                             # Catalog, stock values, message payloads
├── Stores/                             # Shared stock-data actor
├── Services/                           # Socket transport, queue, simulation, clock
├── Navigation/                         # Deep-link parsing
├── Presentation/                       # Locale-aware display formatting
├── ViewModels/                         # Screen state and lifecycle
├── Views/                              # Stocks, detail, rows, splash view
├── DebugSupport/                       # Offline UI-test dependencies (Debug only)
└── Assets.xcassets/
RealTimeStockPriceTrackerTests/          # Offline unit tests
RealTimeStockPriceTrackerUITests/        # Offline UI tests
```

## Scope and extension points

The assessment uses a fixed catalog, USD prices, an in-memory store, and manual retry. Currency and percentage formatting respect the current locale. Description keys are retained in catalog metadata, but localized company-description resources are not currently bundled.

A production market-data integration would replace the echo/simulation source with a provider-specific subscription service. Server-supplied catalogs, localized descriptions, regional market/currency rules, persistence, authentication, and a defined reconnect policy are further extensions. The injected services and shared store provide boundaries for those additions.
