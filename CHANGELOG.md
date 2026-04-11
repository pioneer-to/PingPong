# Changelog

All notable changes to PongBar will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Real-time ICMP ping monitoring for internet, router, and DNS targets
- Raw UDP DNS query with cache-bypassing RTT measurement
- Per-interface throughput monitoring via OS traffic counters
- VPN-aware network detection (WireGuard, OpenVPN, IKEv2, L2TP)
- On-demand traceroute with parsed hop-by-hop results
- Continuous MTR (My Traceroute) sessions with per-hop statistics
- Incident management with grace period, categorization, and notifications
- Custom user-defined monitoring targets
- DNS server quick-switching (Cloudflare, Google, Quad9, custom)
- SQLite-backed latency history with configurable retention
- Interactive latency charts with multiple time ranges (5m to 7d)
- Network topology map visualization
- Uptime tracking with visual bar charts
- One-click diagnostic report generation
- Jitter analysis using standard deviation of consecutive deltas
- Rolling packet loss tracking with spike detection
- WiFi signal strength monitoring (SSID, RSSI)
- Configurable thresholds for latency, jitter, loss, and WiFi quality
- macOS notification alerts for outages and recovery
- Sleep/wake-aware monitoring with configurable resume delay
- Menu bar status icon with optional latency/loss text display
- Comprehensive Settings UI with General, Targets, Thresholds, DNS, Notifications, and Advanced sections
