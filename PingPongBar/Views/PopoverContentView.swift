//
//  PopoverContentView.swift
//  PingPongBar
//
//  Root view for the menu bar popover with manual page navigation
//  (avoids NavigationStack which can cause MenuBarExtra to dismiss on push).
//

import SwiftUI

/// Current page displayed in the popover.
enum PopoverPage: Equatable {
    case main
    case history
    case targetDetail(PingTarget, String)
    case localDeviceSpeedDetail(LocalNetworkDevice)
    case traceroute(String)
    case mtr(String)
    case networkMap(String)
    case customTargetDetail(String, String)  // (storageKey, displayName)
}

struct PopoverContentView: View {
    @State private var currentPage: PopoverPage = .main

    var body: some View {
        Group {
            switch currentPage {
            case .main:
                MainStatusView(navigate: navigate)
            case .history:
                IncidentHistoryView(goBack: goBack)
            case .targetDetail(let target, let detail):
                TargetDetailView(target: target, detail: detail, goBack: goBack, navigate: navigate)
            case .localDeviceSpeedDetail(let device):
                LocalDeviceSpeedDetailView(device: device, goBack: goBack)
            case .traceroute(let host):
                TracerouteView(host: host, goBack: goBack)
            case .mtr(let host):
                MTRView(host: host, goBack: goBack)
            case .networkMap(let host):
                NetworkMapView(host: host, goBack: goBack)
            case .customTargetDetail(let storageKey, let displayName):
                CustomTargetDetailView(storageKey: storageKey, displayName: displayName, goBack: goBack)
            }
        }
        .controlSize(.small)
        .animation(.easeInOut(duration: 0.15), value: currentPage)
    }

    private func navigate(to page: PopoverPage) {
        currentPage = page
    }

    private func goBack() {
        currentPage = .main
    }
}

struct PopoverNavigationHeader<Title: View, Trailing: View>: View {
    let onBack: (() -> Void)?
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trailing: () -> Trailing

    init(
        onBack: (() -> Void)? = nil,
        @ViewBuilder title: @escaping () -> Title
    ) where Trailing == EmptyView {
        self.onBack = onBack
        self.title = title
        self.trailing = { EmptyView() }
    }

    init(
        onBack: (() -> Void)? = nil,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.onBack = onBack
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.caption)
                        Text("Back")
                            .font(.body)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            trailing()
                .controlSize(.small)
        }
        .overlay {
            title()
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct PopoverTimeNavigationControls: View {
    let timeOffset: TimeInterval
    let onStepBack: () -> Void
    let onReset: () -> Void
    let onStepForward: () -> Void

    var body: some View {
        ControlGroup {
            Button(action: onStepBack) {
                Image(systemName: "chevron.left")
                    .font(.caption2)
            }

            Button("Now", action: onReset)
                .foregroundStyle(timeOffset == 0 ? .secondary : .primary)
                .disabled(timeOffset == 0)

            Button(action: onStepForward) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .disabled(timeOffset >= 0)
        }
        .help(timeOffset == 0 ? "Showing the latest measurements" : "Return to the latest measurements")
    }
}

struct PopoverOverlayCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: 700, maxHeight: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 6)
        .padding(12)
    }
}

#Preview("PopoverContentView") {
    let monitor = NetworkMonitor()
    // Keep previews static
    monitor.stop()

    // Seed minimal state so the main page renders
    monitor.currentResults[.internet] = PingResult(target: .internet, timestamp: .now, isReachable: true, latency: 22, detail: Config.internetHost)
    monitor.currentResults[.router] = PingResult(target: .router, timestamp: .now, isReachable: true, latency: 3, detail: "192.168.1.1")
    monitor.currentResults[.dns] = PingResult(target: .dns, timestamp: .now, isReachable: true, latency: 7, detail: "1.1.1.1")

    return PopoverContentView()
        .environment(monitor)
        .frame(width: 360)
}
