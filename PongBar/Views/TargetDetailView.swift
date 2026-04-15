//
//  TargetDetailView.swift
//  PongBar
//
//  Inline latency chart view for a single target, shown inside the menu bar popover
//  via push navigation. Uses Swift Charts with time range selection and hover tooltip.
//

import SwiftUI
import Charts

/// Available time ranges for the chart.
enum TimeRange: String, CaseIterable, Identifiable {
    case fifteenMin = "15M"
    case oneHour = "1H"
    case sixHours = "6H"
    case oneDay = "24H"
    case sevenDays = "7D"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .fifteenMin: return 900
        case .oneHour: return 3600
        case .sixHours: return 6 * 3600
        case .oneDay: return 24 * 3600
        case .sevenDays: return 7 * 24 * 3600
        }
    }

    /// Appropriate date format for x-axis labels.
    var dateFormat: Date.FormatStyle {
        switch self {
        case .fifteenMin:
            return .dateTime.hour().minute()
        case .oneHour, .sixHours:
            return .dateTime.hour().minute()
        case .oneDay:
            return .dateTime.hour()
        case .sevenDays:
            return .dateTime.month(.abbreviated).day()
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .fifteenMin: return .minute
        case .oneHour: return .minute
        case .sixHours: return .hour
        case .oneDay: return .hour
        case .sevenDays: return .day
        }
    }

    var strideCount: Int {
        switch self {
        case .fifteenMin: return 3
        case .oneHour: return 10
        case .sixHours: return 1
        case .oneDay: return 4
        case .sevenDays: return 1
        }
    }
}

struct TargetDetailView: View {
    let target: PingTarget
    let detail: String
    var goBack: () -> Void
    var navigate: ((PopoverPage) -> Void)?

    @Environment(PopoverState.self) private var popoverState

    @State private var selectedRange: TimeRange = .fifteenMin
    @State private var samples: [LatencySample] = []      // downsampled for chart rendering
    @State private var rawStats = LatencyStatsResult(avg: 0, min: 0, max: 0, loss: 0, jitter: 0)
    @State private var hoveredSample: LatencySample?
    @State private var loadTask: Task<Void, Never>?
    @State private var timeOffset: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            // Navigation header
            headerSection

            Divider()

            // Range picker
            rangePicker

            // Chart
            chartSection

            Divider()

            // Stats footer
            statsSection
        }
        .task {
            loadSamples()
            // Auto-refresh only for short ranges (15M, 1H) — skip for 6H/24H/7D to save CPU
            while !Task.isCancelled {
                let interval = selectedRange.seconds <= 3600
                    ? Config.chartRefreshInterval
                    : 30.0  // Slow refresh for long ranges
                try? await Task.sleep(for: .seconds(interval))
                if timeOffset == 0 && popoverState.isVisible {
                    loadSamples()
                }
            }
        }
        .onChange(of: selectedRange) { _, _ in
            timeOffset = 0
            loadSamples()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Button {
                goBack()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                    Text("Back")
                        .font(.body)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Circle()
                .fill(currentStatusColor)
                .frame(width: 8, height: 8)

            Text(target.displayName)
                .font(.headline)

            Spacer()

            // Time navigation arrows
            HStack(spacing: 2) {
                Button {
                    timeOffset = max(timeOffset - selectedRange.seconds * 0.5, -Config.retentionPeriod)
                    loadSamples()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption2)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)

                Button {
                    timeOffset = 0
                    loadSamples()
                } label: {
                    Text("Now")
                        .font(.caption2)
                        .foregroundStyle(timeOffset == 0 ? .quaternary : .primary)
                }
                .buttonStyle(.plain)
                .disabled(timeOffset == 0)

                Button {
                    timeOffset = min(0, timeOffset + selectedRange.seconds * 0.5)
                    loadSamples()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(timeOffset >= 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Range Picker

    private var rangePicker: some View {
        Picker("", selection: $selectedRange) {
            ForEach(TimeRange.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Chart

    /// Line color: direct connection vs VPN.
    private var vpnColor: Color { .purple }
    private var directColor: Color { lineColor }

    /// Assign segment IDs to break the line at large time gaps.
    /// Gap threshold scales with the selected range to handle downsampled data correctly.
    private func segmentedSamples(_ samples: [LatencySample]) -> [(sample: LatencySample, segment: Int)] {
        guard !samples.isEmpty else { return [] }
        // Expected gap = total range / number of points. Break at 3x expected gap.
        let expectedGap = samples.count > 1
            ? selectedRange.seconds / Double(samples.count)
            : 10
        let gapThreshold = max(10, expectedGap * 3)

        var result: [(LatencySample, Int)] = []
        var segment = 0
        result.append((samples[0], segment))
        for i in 1..<samples.count {
            let gap = samples[i].timestamp.timeIntervalSince(samples[i-1].timestamp)
            if gap > gapThreshold { segment += 1 }
            result.append((samples[i], segment))
        }
        return result
    }

    private var chartSection: some View {
        let reachable = samples.filter { $0.latency != nil }
        let segmented = segmentedSamples(reachable)
        let unreachable = samples.filter { $0.latency == nil }

        return Chart {
            // Line broken at gaps, colored by VPN state
            ForEach(Array(segmented.enumerated()), id: \.offset) { _, item in
                LineMark(
                    x: .value("Time", item.sample.timestamp),
                    y: .value("Latency", item.sample.latency ?? 0),
                    series: .value("Segment", item.segment)
                )
                .foregroundStyle(item.sample.vpnActive ? vpnColor : directColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }

            // Unreachable markers
            ForEach(unreachable) { sample in
                PointMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Latency", 0)
                )
                .foregroundStyle(.red)
                .symbolSize(20)
            }

            // Hover rule + point
            if let hovered = hoveredSample, let lat = hovered.latency {
                RuleMark(x: .value("Time", hovered.timestamp))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))

                PointMark(
                    x: .value("Time", hovered.timestamp),
                    y: .value("Latency", lat)
                )
                .foregroundStyle(lineColor)
                .symbolSize(30)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: selectedRange.calendarComponent, count: selectedRange.strideCount)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [2, 2]))
                    .foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel(format: selectedRange.dateFormat)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [2, 2]))
                    .foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let date: Date = proxy.value(atX: location.x) else {
                                hoveredSample = nil
                                return
                            }
                            hoveredSample = samples
                                .filter { $0.latency != nil }
                                .min(by: {
                                    abs($0.timestamp.timeIntervalSince(date)) <
                                    abs($1.timestamp.timeIntervalSince(date))
                                })
                        case .ended:
                            hoveredSample = nil
                        }
                    }
            }
        }
        .chartBackground { proxy in
            if let hovered = hoveredSample, let lat = hovered.latency {
                GeometryReader { geometry in
                    if let anchor = proxy.position(forX: hovered.timestamp) {
                        let x = min(max(anchor, 45), geometry.size.width - 45)
                        VStack(spacing: 1) {
                            HStack(spacing: 3) {
                                if hovered.vpnActive {
                                    Text("VPN")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.purple)
                                }
                                Text(String(format: "%.1f ms", lat))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            Text(Formatters.timeOnly(hovered.timestamp))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .position(x: x, y: 12)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 160)
    }

    // MARK: - Stats

    /// Stats computed from RAW data (not downsampled) for accuracy.
    private var statsSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                StatBadge(label: "AVG", value: String(format: "%.0f", rawStats.avg))
                Spacer()
                StatBadge(label: "MIN", value: String(format: "%.0f", rawStats.min))
                Spacer()
                StatBadge(label: "MAX", value: String(format: "%.0f", rawStats.max))
                Spacer()
                StatBadge(label: "JITTER", value: String(format: "%.1f", rawStats.jitter))
                Spacer()
                StatBadge(label: "LOSS", value: String(format: "%.1f%%", rawStats.loss), isWarning: rawStats.loss > 0)
            }

            // Diagnostic tools
            HStack(spacing: 12) {
                Button {
                    navigate?(.traceroute(detail))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption2)
                        Text("Trace")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    navigate?(.mtr(detail))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.caption2)
                        Text("MTR")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    navigate?(.networkMap(detail))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "globe.desk")
                            .font(.caption2)
                        Text("Map")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var currentStatusColor: Color {
        guard let last = samples.last else { return .secondary }
        return last.isReachable ? .green : .red
    }

    private var lineColor: Color {
        switch target {
        case .internet: return .blue
        case .router: return .green
        case .dns: return .purple
        case .vpn: return .cyan
        }
    }



    private var yDomain: ClosedRange<Double> {
        let values = samples.compactMap(\.latency)
        guard let maxVal = values.max() else { return 0...50 }
        return 0...max(maxVal * 1.2, 5)
    }

    /// Max points to render in chart (avoids freezing on 200K+ samples for 7D range).
    private let maxChartPoints = 300

    private func loadSamples() {
        loadTask?.cancel()
        loadTask = Task {
            let endDate = Date().addingTimeInterval(timeOffset)
            let startDate = endDate.addingTimeInterval(-selectedRange.seconds)
            let raw = await SQLiteStorage.shared.fetch(target: target, from: startDate, to: endDate)
            guard !Task.isCancelled else { return }
            updateFromRaw(raw)
        }
    }

    @MainActor
    private func updateFromRaw(_ raw: [LatencySample]) {
        let stats = LatencyStats.compute(from: raw)
        rawStats = stats

        if raw.count > maxChartPoints {
            samples = LatencyStats.downsample(raw, to: maxChartPoints)
        } else {
            samples = raw
        }
    }
}
