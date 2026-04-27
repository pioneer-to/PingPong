//
//  CustomTargetDetailView.swift
//  PingPongBar
//
//  Chart detail view for custom ping targets.
//  Fetches data from SQLite using the custom storage key ("custom.hostname").
//

import SwiftUI
import Charts

struct CustomTargetDetailView: View {
    let storageKey: String
    let displayName: String
    var goBack: () -> Void

    @Environment(PopoverState.self) private var popoverState

    @State private var selectedRange: TimeRange = .fifteenMin
    @State private var samples: [LatencySample] = []
    @State private var rawStats = LatencyStatsResult(avg: 0, min: 0, max: 0, loss: 0, jitter: 0)
    @State private var hoveredSample: LatencySample?

    @State private var timeOffset: TimeInterval = 0
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            PopoverNavigationHeader(onBack: goBack) {
                Text(displayName)
                    .font(.headline)
            } trailing: {
                PopoverTimeNavigationControls(
                    timeOffset: timeOffset,
                    onStepBack: {
                        timeOffset = max(timeOffset - selectedRange.seconds * 0.5, -Config.retentionPeriod)
                        loadSamples()
                    },
                    onReset: {
                        timeOffset = 0
                        loadSamples()
                    },
                    onStepForward: {
                        timeOffset = min(0, timeOffset + selectedRange.seconds * 0.5)
                        loadSamples()
                    }
                )
            }

            Divider()

            // Range picker
            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Chart
            Chart {
                ForEach(samples.filter { $0.latency != nil }) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Latency", sample.latency ?? 0)
                    )
                    .foregroundStyle(sample.vpnActive ? Color.purple : Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                ForEach(samples.filter { $0.latency == nil }) { sample in
                    PointMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Latency", 0)
                    )
                    .foregroundStyle(.red)
                    .symbolSize(20)
                }

                if let hovered = hoveredSample, let lat = hovered.latency {
                    RuleMark(x: .value("Time", hovered.timestamp))
                        .foregroundStyle(.secondary.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))

                    PointMark(
                        x: .value("Time", hovered.timestamp),
                        y: .value("Latency", lat)
                    )
                    .foregroundStyle(Color.orange)
                    .symbolSize(30)
                }
            }
            .chartYScale(domain: yDomain)
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
                            Text("\(Int(v))").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let xPosition = location.x - geometry[proxy.plotAreaFrame].origin.x
                                guard let date: Date = proxy.value(atX: xPosition) else {
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

            Divider()

            // Stats
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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .task {
            loadSamples()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Config.chartRefreshInterval))
                if timeOffset == 0 && popoverState.isVisible { loadSamples() }
            }
        }
        .onChange(of: selectedRange) { _, _ in
            timeOffset = 0
            loadSamples()
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = samples.compactMap(\.latency)
        guard let maxVal = values.max() else { return 0...50 }
        return 0...max(maxVal * 1.2, 5)
    }

    private func loadSamples() {
        loadTask?.cancel()
        loadTask = Task {
            let endDate = Date().addingTimeInterval(timeOffset)
            let startDate = endDate.addingTimeInterval(-selectedRange.seconds)
            let raw = await SQLiteStorage.shared.fetch(key: storageKey, from: startDate, to: endDate)
            guard !Task.isCancelled else { return }
            updateFromRaw(raw)
        }
    }

    @MainActor
    private func updateFromRaw(_ raw: [LatencySample]) {
        rawStats = LatencyStats.compute(from: raw)
        samples = raw.count > 300 ? LatencyStats.downsample(raw, to: 300) : raw
    }
}
