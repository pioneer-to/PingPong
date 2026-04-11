# Architecture

This document describes the internal architecture of PongBar, a macOS menu bar network monitoring application.

## Overview

PongBar follows a **modified MVVM** pattern adapted for SwiftUI's `@Observable` macro system. The `@Observable` objects serve as both model containers and reactive state providers that views observe directly through the `@Environment` mechanism, eliminating the need for explicit ViewModel bindings.

## Layer Diagram

```
┌─────────────────────────────────────────────────┐
│                   App Entry                      │
│              PongBarApp.swift                     │
│         MenuBarExtra + Settings Scene            │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│                  View Layer                       │
│           16 SwiftUI Views                        │
│   PopoverContentView → MainStatusView            │
│   StatusRowView, DNSRowView, SparklineView ...   │
│   TargetDetailView, TracerouteView, MTRView ...  │
│   SettingsView                                    │
└──────────────────────┬──────────────────────────┘
                       │ @Environment(NetworkMonitor.self)
┌──────────────────────▼──────────────────────────┐
│            Observable Model Layer                 │
│                                                   │
│   NetworkMonitor (central orchestrator)           │
│       ├── MetricsEngine                           │
│       ├── IncidentManager                         │
│       └── ThroughputEngine                        │
│                                                   │
│   All @Observable, all @MainActor                 │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│              Service Layer                        │
│        12 stateless enum services                 │
│                                                   │
│   PingService          DNSResolveService          │
│   GatewayService       NetworkInterfaceService    │
│   ThroughputService    InterfaceSnapshot          │
│   TracerouteService    MTRService                 │
│   PublicIPService      NotificationService        │
│   DNSSwitcherService   DiagnosticReportService    │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│              Storage Layer                        │
│                                                   │
│   SQLiteStorage.shared (singleton)                │
│   - WAL mode, serial DispatchQueue               │
│   - Pre-compiled prepared statements             │
│   - Batch transaction writes                     │
│   - Schema versioning (currently v3)             │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│             Configuration                         │
│                                                   │
│   Config enum → UserDefaults + Defaults           │
│   Read-only, cross-cutting concern                │
└─────────────────────────────────────────────────┘
```

## Core Monitoring Loop

The monitoring pipeline executes every `pingInterval` seconds (default 3s):

```
NetworkMonitor.performChecks()
    │
    ├─ 1. InterfaceSnapshot.capture()          ← Single getifaddrs() call
    │      Shared across all services
    │
    ├─ 2. Concurrent network checks (async let)
    │      ├── PingService.ping(internetHost)
    │      ├── PingService.ping(routerIP)
    │      ├── DNSResolveService.resolve()
    │      └── PingService.ping(publicIP)       ← Optional
    │
    ├─ 3. Infrastructure updates
    │      ├── GatewayService.getGatewayIP()
    │      ├── NetworkInterfaceService.detect()
    │      └── ThroughputEngine.update(snapshot)
    │
    ├─ 4. Metrics processing
    │      └── MetricsEngine.update(result)
    │          ├── Update latency history
    │          ├── Compute jitter (stddev of deltas)
    │          ├── Compute rolling packet loss
    │          └── Persist LatencySample to SQLite
    │
    ├─ 5. Incident evaluation
    │      └── IncidentManager.checkIncident(result)
    │          ├── Grace period check (consecutive failures)
    │          ├── Create/resolve incidents
    │          ├── Classify category
    │          └── Trigger notifications
    │
    ├─ 6. Custom targets (TaskGroup)
    │      └── Ping all enabled custom targets concurrently
    │
    └─ 7. Persistence
           ├── SQLiteStorage.flush()            ← Batch transaction
           └── Save incidents (every 10th cycle)
```

## Dependency Graph

Dependencies flow strictly downward. No service knows about `NetworkMonitor`. No model knows about views.

```
Views ──────────► NetworkMonitor ──────► MetricsEngine ────► SQLiteStorage
                       │
                       ├──────────────► IncidentManager ──► SQLiteStorage
                       │                                  ► NotificationService
                       │
                       ├──────────────► ThroughputEngine ─► ThroughputService
                       │
                       ├──────────────► PingService
                       ├──────────────► DNSResolveService
                       ├──────────────► GatewayService
                       ├──────────────► NetworkInterfaceService
                       ├──────────────► PublicIPService
                       └──────────────► InterfaceSnapshot
```

`Config` is referenced by all layers as a read-only cross-cutting concern.

## State Management

### Observable Pattern

All mutable application state lives in `@Observable` classes isolated to `@MainActor`:

| Class | Role | Owned By |
|-------|------|----------|
| `NetworkMonitor` | Root orchestrator, single source of truth | `PongBarApp` (`@State`) |
| `MetricsEngine` | Per-target rolling metrics | `NetworkMonitor` |
| `IncidentManager` | Incident lifecycle | `NetworkMonitor` |
| `ThroughputEngine` | Interface throughput | `NetworkMonitor` |
| `MTRSession` | Active MTR session | Created on-demand by views |

Views access `NetworkMonitor` via `@Environment(NetworkMonitor.self)`. Sub-engines are accessed as properties of the monitor (e.g., `monitor.metrics`, `monitor.incidents`).

### Thread Safety Model

| Component | Strategy |
|-----------|----------|
| Observable models | `@MainActor` isolation |
| `SQLiteStorage` | Serial `DispatchQueue` |
| `OutputBox` | `NSLock` |
| `GatewayService` | `@MainActor` (cached state) |
| `PublicIPService` | `@MainActor` |
| Stateless services | No shared mutable state |

## Navigation

PongBar uses a **manual page stack** instead of `NavigationStack`. This is a deliberate workaround for a known macOS bug where `NavigationStack` causes the `MenuBarExtra` popover to dismiss on push.

```swift
// PopoverContentView.swift
@State private var pageStack: [PopoverPage] = []

// Navigation via closures passed to child views:
navigate: { page in pageStack.append(page) }
goBack:   { _ = pageStack.popLast() }
```

Available pages:
- `.main` — Dashboard (default)
- `.targetDetail(PingTarget)` — Latency chart for built-in target
- `.customTargetDetail(CustomTarget)` — Latency chart for custom target
- `.traceroute(String)` — Traceroute to host
- `.mtr(String)` — MTR session to host
- `.networkMap` — Network topology
- `.incidentHistory` — Past incidents
- `.settings` — Preferences

## Service Layer Design

All services follow a consistent pattern:

1. **Enum namespace** — Prevents accidental instantiation
2. **Static async methods** — All network operations are async/await
3. **No shared mutable state** — Stateless by design
4. **Validation at boundary** — `HostValidator.isValid()` called before any host reaches a process or socket

### Subprocess Execution Pattern

Services that shell out (`PingService`, `TracerouteService`, `DNSSwitcherService`) use a standardized pattern:

```
Process + Pipe + OutputBox + DispatchGroup + terminationHandler + withCheckedContinuation
```

This avoids blocking Swift Concurrency threads while reading subprocess output, which is a known pitfall with `Process` in async contexts.

### Network Data Acquisition

| Service | Method | Why |
|---------|--------|-----|
| `PingService` | `/sbin/ping` subprocess | Raw ICMP requires root/entitlements |
| `DNSResolveService` | Raw UDP socket | Bypasses system cache, measures true RTT |
| `GatewayService` | `sysctl()` kernel routing table | No subprocess overhead |
| `NetworkInterfaceService` | `getifaddrs()` + `CoreWLAN` + `SCDynamicStore` | Direct API access |
| `ThroughputService` | `getifaddrs()` traffic counters | OS-level counters via shared snapshot |
| `TracerouteService` | `/usr/sbin/traceroute` subprocess | Standard tool, parsed output |
| `PublicIPService` | HTTP (ipify, ifconfig.me, icanhazip) | Redundant endpoints for reliability |

## Storage

### SQLite Schema

**`samples` table:**
```sql
CREATE TABLE samples (
    timestamp REAL,
    target    TEXT,
    latency   REAL,      -- NULL for packet loss
    vpn       INTEGER
);
CREATE INDEX idx_samples ON samples(target, timestamp);
```

**`incidents` table:**
```sql
CREATE TABLE incidents (
    id         TEXT PRIMARY KEY,
    target     TEXT,
    start_time REAL,
    end_time   REAL,      -- NULL for ongoing
    category   TEXT,
    is_stale   INTEGER
);
```

### Write Strategy

- Samples are queued via `record()` during the monitoring tick
- All pending samples are batch-flushed in a single `BEGIN/COMMIT` transaction via `flush()`
- Incidents are batch-saved every 10th monitoring cycle and at app termination
- Auto-trim deletes samples older than `retentionPeriod` every 500 inserts

### Pragmas

```sql
PRAGMA journal_mode = WAL;     -- Concurrent reads during writes
PRAGMA synchronous = NORMAL;   -- Performance (safe with WAL)
```

## VPN Awareness

VPN detection is deeply integrated throughout the stack:

| Component | VPN Behavior |
|-----------|-------------|
| `NetworkInterfaceService` | Detects VPN via `SCDynamicStore` service keys (WireGuard, OpenVPN, IKEv2, L2TP) |
| `GatewayService` | Filters to physical `en*` interface, ignoring VPN tunnel interfaces |
| `DNSResolveService` | VPN-aware DNS server fallback chain: Global → VPN → Any → Setup |
| `ThroughputEngine` | Displays VPN interface separately when active |
| `LatencySample` | Records VPN state per sample for chart coloring |
| `DNSSwitcherService` | Uses `scutil` with admin privileges for VPN DNS override; includes VPN restart |
| `IncidentManager` | Grace period prevents false incidents during VPN switching |

## Menu Bar Integration

PongBar uses SwiftUI's `MenuBarExtra` with `.window` style:

```swift
MenuBarExtra {
    PopoverContentView()
        .environment(monitor)
} label: {
    HStack(spacing: 4) {
        Circle()  // Colored status dot
        Text(...)  // Optional latency/loss text
    }
}
.menuBarExtraStyle(.window)
```

The `.window` style provides a full SwiftUI popover (not a system menu). The Settings window is a separate `Settings {}` scene accessible via `SettingsLink` or `⌘,`.

## Incident Classification

When an outage is detected, `IncidentManager` classifies it into categories based on which targets are affected:

| Category | Condition |
|----------|-----------|
| `fullOutage` | Internet + Router both unreachable |
| `ispUpstream` | Internet unreachable, Router reachable |
| `localNetwork` | Router unreachable, Internet status varies |
| `dnsOnly` | DNS unreachable, Internet + Router fine |
| `unknown` | Unclassifiable pattern |

## Security Considerations

- **Input validation**: `HostValidator` prevents flag injection (leading dashes), shell metacharacters, and buffer overflow attempts before any string reaches a `Process()` or socket
- **IP validation**: Uses `inet_pton()` for strict IP address validation
- **No raw sockets**: Subprocess-based ping requires no elevated privileges
- **DNS privacy**: Public IP detection is opt-in and respects the `showPublicIP` preference
- **VPN name validation**: Validated before passing to `scutil` commands
