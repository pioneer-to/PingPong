//
//  IncidentHistoryView.swift
//  PingPongBar
//
//  Push-navigated incident history view grouped by day.
//

import SwiftUI

struct IncidentHistoryView: View {
    @Environment(NetworkMonitor.self) private var monitor
    var goBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PopoverNavigationHeader(onBack: goBack) {
                Text("Incident History")
                    .font(.headline)
            }

            Divider()

            if monitor.incidentManager.incidents.isEmpty {
                emptyState
            } else {
                incidentList
            }

            Divider()

            // Clear history button
            if !monitor.incidentManager.incidents.isEmpty {
                Button {
                    monitor.clearHistory()
                } label: {
                    HStack {
                        Text("Clear History")
                            .font(.body)
                            .foregroundStyle(.red.opacity(0.8))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.green)
            Text("No incidents recorded")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var incidentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedIncidents, id: \.key) { group in
                    // Section header
                    Text(group.key)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    ForEach(group.incidents) { incident in
                        IncidentRow(incident: incident)
                    }
                }
            }
        }
        .frame(maxHeight: 250)
    }

    /// Group incidents by day label.
    private var groupedIncidents: [IncidentGroup] {
        let dict = Dictionary(grouping: monitor.incidentManager.incidents) { incident in
            Formatters.dayGroup(incident.startTime)
        }

        // Define a sort order for day groups
        let order = ["Today", "Yesterday", "Earlier this week"]

        return dict.map { IncidentGroup(key: $0.key, incidents: $0.value) }
            .sorted { a, b in
                let aIndex = order.firstIndex(of: a.key) ?? Int.max
                let bIndex = order.firstIndex(of: b.key) ?? Int.max
                if aIndex != bIndex { return aIndex < bIndex }
                return a.key < b.key
            }
    }
}

/// A group of incidents sharing the same day label.
private struct IncidentGroup {
    let key: String
    let incidents: [Incident]
}

/// A single incident row in the history with category badge.
private struct IncidentRow: View {
    let incident: Incident

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(incident.category?.color ?? dotColor)
                .frame(width: 6, height: 6)

            Text(Formatters.timeOnly(incident.startTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(incident.summary)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Text(incident.isStale ? "unknown" : incident.durationString)
                .font(.caption)
                .foregroundStyle(incident.isStale ? .orange : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var dotColor: Color {
        switch incident.target {
        case .internet: return .red
        case .router: return .red
        case .dns: return .yellow
        case .vpn: return .cyan
        }
    }
}
