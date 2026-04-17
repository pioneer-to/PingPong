//
//  LocalDeviceSpeedDetailView.swift
//  PongBar
//
//  Chart detail view for local network device link speeds stored in localdevices.sqlite.
//

import SwiftUI
import Charts

struct LocalDeviceSpeedDetailView: View {
    let device: LocalNetworkDevice
    var goBack: () -> Void

    @Environment(PopoverState.self) private var popoverState

    @State private var selectedRange: TimeRange = .fifteenMin
    @State private var samples: [LocalDeviceSpeedSample] = []
    @State private var hoveredSample: LocalDeviceSpeedSample?
    @State private var timeOffset: TimeInterval = 0
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            chartSection

            Divider()

            statsSection
        }
        .task {
            loadSamples()
            while !Task.isCancelled {
                let interval = selectedRange.seconds <= 3600 ? Config.chartRefreshInterval : 30.0
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

    private var headerSection: some View {
        PopoverNavigationHeader(onBack: goBack) {
            HStack(spacing: 8) {
                Image(systemName: device.symbolName)
                    .foregroundStyle(.primary)
                Text(device.displayName)
                    .font(.headline)
            }
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
    }

    private var chartSection: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Speed", sample.speedMbps)
                )
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }

            if let hoveredSample {
                RuleMark(x: .value("Time", hoveredSample.timestamp))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))

                PointMark(
                    x: .value("Time", hoveredSample.timestamp),
                    y: .value("Speed", hoveredSample.speedMbps)
                )
                .foregroundStyle(.green)
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
                        Text("\(Int(v)) Mbit/s")
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
                            hoveredSample = samples.min(by: {
                                abs($0.timestamp.timeIntervalSince(date)) <
                                abs($1.timestamp.timeIntervalSince(date))
                            })
                        case .ended:
                            hoveredSample = nil
                        }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 160)
    }

    private var statsSection: some View {
        let values = samples.map(\.speedMbps)
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let jitter = LatencyStats.jitter(from: values)

        return HStack(spacing: 0) {
            StatBadge(label: "AVG", value: String(format: "%.0f", avg))
            Spacer()
            StatBadge(label: "MIN", value: String(format: "%.0f", minValue))
            Spacer()
            StatBadge(label: "MAX", value: String(format: "%.0f", maxValue))
            Spacer()
            StatBadge(label: "JITTER", value: String(format: "%.1f", jitter))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var yDomain: ClosedRange<Double> {
        let values = samples.map(\.speedMbps)
        guard let maxVal = values.max() else { return 0...1000 }
        return 0...max(maxVal * 1.2, 100)
    }

    private func loadSamples() {
        loadTask?.cancel()
        loadTask = Task {
            let endDate = Date().addingTimeInterval(timeOffset)
            let startDate = endDate.addingTimeInterval(-selectedRange.seconds)
            let raw = await LocalDeviceSpeedStorage.shared.fetch(
                macAddress: device.macAddress,
                from: startDate,
                to: endDate
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                samples = raw.count > 300 ? downsample(raw, to: 300) : raw
            }
        }
    }

    private func downsample(_ values: [LocalDeviceSpeedSample], to maxCount: Int) -> [LocalDeviceSpeedSample] {
        guard values.count > maxCount, maxCount > 1 else { return values }
        let step = Double(values.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { index in
            let sourceIndex = Int((Double(index) * step).rounded())
            return values[min(sourceIndex, values.count - 1)]
        }
    }
}
