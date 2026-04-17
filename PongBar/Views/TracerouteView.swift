//
//  TracerouteView.swift
//  PongBar
//
//  On-demand traceroute view shown inline in the popover.
//

import SwiftUI

struct TracerouteView: View {
    let host: String
    var goBack: () -> Void

    @State private var hops: [TracerouteHop] = []
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 0) {
            PopoverNavigationHeader(onBack: goBack) {
                Text("Traceroute")
                    .font(.headline)
            } trailing: {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        runTrace()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Text(host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

            Divider()

            if hops.isEmpty && !isRunning {
                VStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Tap refresh to run traceroute")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(hops) { hop in
                            HStack(spacing: 8) {
                                Text("\(hop.hopNumber)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, alignment: .trailing)

                                Circle()
                                    .fill(hop.isTimeout ? Color.red : Color.green)
                                    .frame(width: 5, height: 5)

                                Text(hop.host)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(hop.isTimeout ? .secondary : .primary)
                                    .lineLimit(1)

                                Spacer()

                                Text(hop.latency)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(hop.isTimeout ? .red : .secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
        }
        .onAppear {
            runTrace()
        }
        .onDisappear {
            traceTask?.cancel()
        }
    }

    @State private var traceTask: Task<Void, Never>?

    private func runTrace() {
        traceTask?.cancel()
        isRunning = true
        hops = []
        traceTask = Task {
            let result = await TracerouteService.trace(to: host)
            guard !Task.isCancelled else { return }
            hops = result
            isRunning = false
        }
    }
}
