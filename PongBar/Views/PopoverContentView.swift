//
//  PopoverContentView.swift
//  PongBar
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
        .animation(.easeInOut(duration: 0.15), value: currentPage)
    }

    private func navigate(to page: PopoverPage) {
        currentPage = page
    }

    private func goBack() {
        currentPage = .main
    }
}
