# Configuration Reference

All PingPongBar settings are stored in `UserDefaults` and can be modified via the Settings UI or `defaults write` commands.

## Monitoring

| Parameter | Key | Default | Range | Description |
|-----------|-----|---------|-------|-------------|
| Ping Interval | `pingInterval` | `3.0` s | > 0 | Time between monitoring cycles |
| Ping Timeout | `pingTimeout` | `2` s | 1 – (interval-1) | Per-ping subprocess timeout |
| DNS Timeout | `dnsTimeout` | `3` s | 1 – 30 | Raw UDP DNS query timeout |

## Default Hosts

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Internet Host | `internetHost` | `1.1.1.1` | Primary connectivity test target |
| DNS Test Domain | `dnsTestDomain` | `apple.com` | Domain used for DNS RTT measurement |

## Latency Thresholds

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Good Threshold | `latencyGoodThreshold` | `50` ms | At or below = green |
| Fair Threshold | `latencyFairThreshold` | `150` ms | At or below = yellow, above = red |

## Jitter

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Display Threshold | `jitterDisplayThreshold` | `0.1` ms | Minimum jitter to show in status row |
| Warning Threshold | `jitterWarningThreshold` | `5.0` ms | Jitter above this = yellow warning |
| Window Size | `jitterWindow` | `20` | Number of recent deltas for computation |

## Packet Loss

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Rolling Window | `lossWindow` | `60` | Number of checks for loss calculation |
| Spike Threshold | `lossSpikeThreshold` | `20` % | Jump per tick to trigger spike alert |

## Uptime Display

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Green Threshold | `uptimeGreenThreshold` | `90` % | At or above = green |
| Yellow Threshold | `uptimeYellowThreshold` | `50` % | At or above = yellow, below = red |

## WiFi Signal (RSSI)

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Excellent | `wifiExcellent` | `-50` dBm | RSSI at or above = excellent |
| Good | `wifiGood` | `-60` dBm | RSSI at or above = good |
| Fair | `wifiFair` | `-70` dBm | RSSI at or above = fair, below = poor |

## Notifications

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Cooldown | `notificationCooldown` | `30` s | Minimum time between alerts per target |

Per-target notification enable/disable is managed through the Settings UI.

## Storage & History

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Sparkline Samples | `maxHistorySamples` | `30` | Max samples per target for sparkline |
| Max Incidents | `maxIncidents` | `200` | Max incidents kept in history |
| Retention Period | `retentionPeriod` | `604800` s (7 days) | SQLite sample retention |
| Trim Interval | `storageTrimInterval` | `500` | Writes between trim operations |

Data is stored in `~/Library/Application Support/PingPongBar/samples.sqlite`.

## Network Switch Grace Period

| Parameter | Key | Default | Range | Description |
|-----------|-----|---------|-------|-------------|
| Grace Pings | `networkSwitchGracePings` | `3` | 1 – 30 | Consecutive failures before incident |

This prevents false incidents during VPN switching, WiFi roaming, or brief network transitions. At the default 3-second interval, 3 grace pings means a 9-second minimum detection time.

## MTR (My Traceroute)

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Hop Timeout | `mtrHopTimeout` | `1` s | Per-hop ping timeout |
| Round Interval | `mtrRoundInterval` | `1.0` s | Time between MTR rounds |

## Traceroute

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Max Hops | `tracerouteMaxHops` | `20` | Maximum traceroute hops |
| Timeout | `tracerouteTimeout` | `2` s | Per-hop timeout |

## Miscellaneous

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| Wake Delay | `wakeDelay` | `2.0` s | Delay after system wake before resuming |
| Chart Refresh | `chartRefreshInterval` | `3.0` s | Auto-refresh interval for chart views |
| Diagnostic Incidents | `diagnosticRecentIncidents` | `20` | Recent incidents in diagnostic report |
| Pause During Sleep | `pauseDuringSleep` | (bool) | Suspend monitoring during system sleep |
| Show Public IP | `showPublicIP` | (bool) | Enable public IP detection and display |

## Command-Line Override Examples

```bash
# Set ping interval to 5 seconds
defaults write com.timo.PingPongBar pingInterval -float 5.0

# Use Google DNS as test target
defaults write com.timo.PingPongBar internetHost -string "8.8.8.8"

# Increase grace period to 5 consecutive failures
defaults write com.timo.PingPongBar networkSwitchGracePings -int 5

# Set data retention to 30 days
defaults write com.timo.PingPongBar retentionPeriod -float 2592000

# Reset a setting to default
defaults delete com.timo.PingPongBar pingInterval
```

> **Note:** Changes take effect on the next monitoring cycle (no restart required for most settings).
