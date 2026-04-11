//
//  StatBadge.swift
//  PongBar
//
//  Reusable small stat badge for chart footer sections.
//

import SwiftUI

struct StatBadge: View {
    let label: String
    let value: String
    var isWarning: Bool = false

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isWarning ? .red : .primary)
        }
    }
}
