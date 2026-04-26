//
//  SectionTimerLineView.swift
//  PingPongBar
//
//  Thin countdown line used to show time remaining until a section refreshes.
//

import SwiftUI

struct SectionTimerLineView: View {
    let lastUpdatedAt: Date?
    let interval: TimeInterval

    private let lineColor = Color(red: 0.05, green: 0.16, blue: 0.34)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { timeline in
            GeometryReader { proxy in
                let progress = progress(at: timeline.date)
                Rectangle()
                    .fill(lineColor.opacity(lastUpdatedAt == nil ? 0.25 : 0.9))
                    .frame(width: max(0, proxy.size.width * progress), height: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 1)
    }

    private func progress(at date: Date) -> Double {
        guard let lastUpdatedAt, interval > 0 else { return 1 }
        let elapsed = date.timeIntervalSince(lastUpdatedAt)
        return max(0, min(1, 1 - (elapsed / interval)))
    }
}

