# Contributing to PingPongBar

Thank you for your interest in contributing to PingPongBar! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- Swift 5.9+

### Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/PrometheusSourse/PingPongBar.git
   cd PingPongBar
   ```
3. Open `PingPongBar.xcodeproj` in Xcode
4. Build and run (Cmd+R)

## Development Guidelines

### Code Style

- Follow Swift API Design Guidelines
- Use `swift-format` or Xcode's default formatting
- Keep files focused — one responsibility per file
- No dead code, unused imports, or commented-out blocks

### Architecture

PingPongBar uses a modified MVVM pattern with SwiftUI's `@Observable`. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

Key rules:
- **Views** never call services directly — always go through `NetworkMonitor`
- **Services** are stateless enums with static methods
- **Dependencies flow downward** — lower layers don't know about upper layers
- **All observable models are `@MainActor`**

### Adding a New Service

1. Create a new file in `PingPongBar/Services/`
2. Implement as an `enum` with `static` methods
3. Use `async/await` for all I/O operations
4. Validate inputs at the boundary using `HostValidator` where applicable
5. Wire it through `NetworkMonitor` — don't call from views

### Adding a New View

1. Create a new file in `PingPongBar/Views/`
2. Access state via `@Environment(NetworkMonitor.self)`
3. Add a new case to `PopoverPage` enum if it needs navigation
4. Use the `navigate` / `goBack` closures for navigation (not `NavigationStack`)

## Submitting Changes

### Pull Request Process

1. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. Make your changes with clear, focused commits
3. Ensure the project builds without warnings
4. Test on macOS — verify the menu bar icon and popover work correctly
5. Open a pull request with:
   - A clear description of what changed and why
   - Screenshots for UI changes
   - Any relevant testing notes

### Commit Messages

Use clear, descriptive commit messages:
```
feat: Add custom DNS server configuration
fix: Resolve false incidents during VPN switching
refactor: Extract throughput calculation into ThroughputEngine
docs: Update architecture documentation
```

## Reporting Issues

### Bug Reports

Please include:
- macOS version
- Steps to reproduce
- Expected vs actual behavior
- Diagnostic report (available from the app's popover menu)

### Feature Requests

Describe the use case and why the feature would be valuable. If possible, include a rough idea of how it might work in the UI.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
