//
//  PongBarApp.swift
//  PongBar
//

import SwiftUI
import AppKit

@MainActor
private enum AppContainer {
    static let monitor = NetworkMonitor()
}

/// Main entry point for the PongBar menu bar application.
/// Uses a custom NSStatusItem for reliable multi-line label rendering.
@main
struct PongBarApp: App {
    @NSApplicationDelegateAdaptor(StatusBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(AppContainer.monitor)
        }
    }
}

@MainActor
final class StatusBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var updateTimer: Timer?
    private let ballAnimator = MenuBarBallAnimator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imageHugsTitle = true
            if let cell = button.cell as? NSButtonCell {
                cell.wraps = true
                cell.usesSingleLineMode = false
                cell.lineBreakMode = .byWordWrapping
            }
        }

        let root = PopoverContentView()
            .environment(AppContainer.monitor)
            .frame(minWidth: 300, idealWidth: 360)
        popover.contentViewController = NSHostingController(rootView: root)
        popover.behavior = .transient

        updateStatusItem()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let mode = UserDefaults.standard.string(forKey: "menuBarDisplayMode") ?? "dot"
        let readings = AppContainer.monitor.throughput.currentReadings.values
        let downloadBytesPerSecond = readings.reduce(0.0) { $0 + $1.downloadBytesPerSec }
        let uploadBytesPerSecond = readings.reduce(0.0) { $0 + $1.uploadBytesPerSec }
        let totalBytesPerSecond = downloadBytesPerSecond + uploadBytesPerSecond
        let internetResult = AppContainer.monitor.currentResults[.internet]
        let internetDotIsRed = internetResult?.isReachable == false
        let internetLatencyTooHigh = (internetResult?.latency ?? 0) > Config.latencyFairThreshold

        ballAnimator.setOneWayDuration(Self.oneWayDuration(for: totalBytesPerSecond))
        ballAnimator.updateNetworkState(
            totalBytesPerSecond: totalBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            downloadBytesPerSecond: downloadBytesPerSecond,
            internetDotIsRed: internetDotIsRed,
            internetLatencyTooHigh: internetLatencyTooHigh
        )

        button.image = ballAnimator.currentFrameImage
        button.imagePosition = .imageLeft

        switch mode {
        case "dotLatency":
            let text = String(format: "%.0f ms", internetResult?.latency ?? 0)
            statusItem?.length = NSStatusItem.variableLength
            button.attributedTitle = Self.attributedSingleLine(text, color: nil)
        case "dotLoss":
            if let loss = AppContainer.monitor.metrics.packetLoss[.internet], loss > 0 {
                let text = String(format: "%.0f%%", loss)
                statusItem?.length = NSStatusItem.variableLength
                button.attributedTitle = Self.attributedSingleLine(text, color: .systemRed)
            } else {
                statusItem?.length = NSStatusItem.squareLength
                button.attributedTitle = NSAttributedString(string: "")
            }
        case "dotSpeed":
            statusItem?.length = NSStatusItem.variableLength
            let up = internetDotIsRed ? ("0", "B", 0) : Self.speedParts(uploadBytesPerSecond)
            let down = internetDotIsRed ? ("0", "B", 0) : Self.speedParts(downloadBytesPerSecond)
            button.attributedTitle = Self.attributedTwoLineSpeed(up: up, down: down)
        default:
            statusItem?.length = NSStatusItem.squareLength
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    private static func attributedSingleLine(_ text: String, color: NSColor?) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let color {
            attributes[.foregroundColor] = color
        }
        attributes[.baselineOffset] = -1.0
        return NSAttributedString(string: " \(text)", attributes: attributes)
    }

    private static func attributedTwoLine(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = -1
        paragraph.alignment = .left
        paragraph.defaultTabInterval = 0
        paragraph.tabStops = [
            NSTextTab(textAlignment: .left, location: 8),
            NSTextTab(textAlignment: .right, location: 30),
            NSTextTab(textAlignment: .left, location: 40)
        ]

        let font = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .baselineOffset: -1.0
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func attributedTwoLineSpeed(
        up: (String, String, Int),
        down: (String, String, Int)
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = speedBadgeImage(up: up, down: down)
        attachment.bounds = NSRect(x: 0, y: -1, width: 34, height: 18)
        return NSAttributedString(attachment: attachment)
    }

    private static func speedBadgeImage(
        up: (String, String, Int),
        down: (String, String, Int)
    ) -> NSImage {
        let size = NSSize(width: 34, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let arrowFont = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)
        let unitFont = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)

        let rightAlignedParagraph = NSMutableParagraphStyle()
        rightAlignedParagraph.alignment = .right

        let arrowAttributes: [NSAttributedString.Key: Any] = [
            .font: arrowFont,
            .foregroundColor: NSColor.labelColor
        ]
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: rightAlignedParagraph
        ]
        let unitAttributes: [NSAttributedString.Key: Any] = [
            .font: unitFont,
            .foregroundColor: NSColor.labelColor,
            .baselineOffset: -3.0
        ]

        let arrowX: CGFloat = 0
        let numberX: CGFloat = 7
        let numberWidth: CGFloat = 16
        let unitX: CGFloat = 24
        let topRowY: CGFloat = 9
        let bottomRowY: CGFloat = 1
        let arrowTopY: CGFloat = topRowY - 1
        let arrowBottomY: CGFloat = bottomRowY - 1
        let unitTopY: CGFloat = topRowY - 1
        let unitBottomY: CGFloat = bottomRowY - 1

        ("↑" as NSString).draw(at: CGPoint(x: arrowX, y: arrowTopY), withAttributes: arrowAttributes)
        ("↓" as NSString).draw(at: CGPoint(x: arrowX, y: arrowBottomY), withAttributes: arrowAttributes)

        let upNumber = String(format: "%3d", Int(up.0) ?? 0)
        let downNumber = String(format: "%3d", Int(down.0) ?? 0)

        (upNumber as NSString).draw(
            in: NSRect(x: numberX, y: topRowY, width: numberWidth, height: 8),
            withAttributes: numberAttributes
        )
        (downNumber as NSString).draw(
            in: NSRect(x: numberX, y: bottomRowY, width: numberWidth, height: 8),
            withAttributes: numberAttributes
        )

        (up.1 as NSString).draw(at: CGPoint(x: unitX, y: unitTopY), withAttributes: unitAttributes)
        (down.1 as NSString).draw(at: CGPoint(x: unitX, y: unitBottomY), withAttributes: unitAttributes)

        drawSegmentedLine(level: up.2, startX: numberX + 1, y: 17.0)
        drawSegmentedLine(level: down.2, startX: numberX + 1, y: 0.0)

        image.isTemplate = false
        return image
    }

    private static func drawSegmentedLine(level: Int, startX: CGFloat, y: CGFloat) {
        let clamped = max(0, min(level, 3))
        let segmentLength: CGFloat = 4.6
        let segmentGap: CGFloat = 0.9

        for segment in 0..<4 {
            let isActive = segment <= clamped
            let x = startX + CGFloat(segment) * (segmentLength + segmentGap)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x, y: y))
            path.line(to: CGPoint(x: x + segmentLength, y: y))
            path.lineWidth = isActive ? 1.3 : 0.7
            (isActive ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
            path.stroke()
        }
    }

    private static func speedParts(_ bytesPerSecond: Double) -> (String, String, Int) {
        let units = ["B", "K", "M", "G"]
        let factor = 1024.0
        var value = max(0, bytesPerSecond)
        var unitIndex = 0

        while value >= 999.5 && unitIndex < units.count - 1 {
            value /= factor
            unitIndex += 1
        }

        var rounded = Int(value.rounded())
        if rounded >= 1000 && unitIndex < units.count - 1 {
            value /= factor
            unitIndex += 1
            rounded = Int(value.rounded())
        }

        return ("\(min(rounded, 999))", units[unitIndex], unitIndex)
    }

    private static func oneWayDuration(for totalBytesPerSecond: Double) -> TimeInterval {
        let twentyKBps = 20.0 * 1024.0
        let fiveMbpsInBytesPerSecond = (5.0 * 1024.0 * 1024.0) / 8.0
        let hundredMbpsInBytesPerSecond = (100.0 * 1024.0 * 1024.0) / 8.0

        if totalBytesPerSecond <= 2_024 { return 1.0 }
        if totalBytesPerSecond <= twentyKBps { return 0.55 }
        if totalBytesPerSecond < fiveMbpsInBytesPerSecond { return 0.30 }
        if totalBytesPerSecond <= hundredMbpsInBytesPerSecond { return 0.14 }
        return 0.07
    }
}

@MainActor
@Observable
private final class MenuBarBallAnimator {
    var frameIndex: Int = 0
    var currentFrameImage: NSImage {
        isOutageMode ? redCenterFrameImage : frameImages[frameIndex]
    }

    private var targetOneWayDuration: TimeInterval = 1.0
    private var currentOneWayDuration: TimeInterval = 1.0

    // Physics state: normalized vertical range [0, 1]
    // 0 = bottom, 1 = top
    private var position: Double = 0.5
    private var velocity: Double = 0

    private var animationTask: Task<Void, Never>?
    private let frameCount: Int
    private let frameImages: [NSImage]
    private let redCenterFrameImage: NSImage

    private var hasZeroTrafficSignal: Bool = false
    private var hasRedInternetSignal: Bool = false
    private var prefersCeilingBounce: Bool = false
    private var zeroTrafficDuration: TimeInterval = 0
    private var isOutageMode: Bool = false
    private let zeroTrafficGraceSeconds: TimeInterval = 3.0

    init() {
        frameImages = Self.makeFrames()
        redCenterFrameImage = Self.makeCenterFrame(color: NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.12, alpha: 1.0))
        frameCount = frameImages.count
        start()
    }

    func setOneWayDuration(_ duration: TimeInterval) {
        targetOneWayDuration = max(0.08, duration)
    }

    func updateNetworkState(
        totalBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        downloadBytesPerSecond: Double,
        internetDotIsRed: Bool,
        internetLatencyTooHigh: Bool
    ) {
        hasZeroTrafficSignal = totalBytesPerSecond <= 0.0
        hasRedInternetSignal = internetDotIsRed || (internetDotIsRed && internetLatencyTooHigh)

        // Switch to ceiling-bounce mode only when upload is clearly dominant.
        let minimumDirectionalTraffic = 8_192.0
        let shouldPreferCeiling = uploadBytesPerSecond >= minimumDirectionalTraffic
            && uploadBytesPerSecond > (downloadBytesPerSecond * 2.0)
        let shouldPreferFloor = uploadBytesPerSecond < minimumDirectionalTraffic
            || uploadBytesPerSecond <= (downloadBytesPerSecond * 1.6)
        if shouldPreferCeiling {
            if !prefersCeilingBounce {
                prefersCeilingBounce = true
                velocity = -velocity
            }
        } else if shouldPreferFloor {
            if prefersCeilingBounce {
                prefersCeilingBounce = false
                velocity = -velocity
            }
        }

        if !hasZeroTrafficSignal {
            zeroTrafficDuration = 0
            if !hasRedInternetSignal {
                isOutageMode = false
            }
        }
    }

    private func start() {
        animationTask?.cancel()
        animationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let tick: TimeInterval = 0.02
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))

                if hasZeroTrafficSignal {
                    zeroTrafficDuration += tick
                } else {
                    zeroTrafficDuration = 0
                }

                let outageByZeroTraffic = zeroTrafficDuration >= zeroTrafficGraceSeconds
                isOutageMode = outageByZeroTraffic || hasRedInternetSignal
                if isOutageMode {
                    frameIndex = frameCount / 2
                    position = 0.5
                    velocity = 0
                    continue
                }

                // Smoothly adapt to new target speed while still reacting quickly.
                let smoothingTau: TimeInterval = 0.22
                let blend = min(1.0, tick / smoothingTau)
                currentOneWayDuration += (targetOneWayDuration - currentOneWayDuration) * blend

                stepPhysics(dt: tick)
                updateFrameIndexFromPosition()
            }
        }
    }

    private func stepPhysics(dt: TimeInterval) {
        let duration = max(0.08, currentOneWayDuration)

        // For a ballistic arc that traverses one normalized half-cycle in `duration`.
        let gravity = 2.0 / (duration * duration)
        let desiredLaunchVelocity = gravity * duration

        // Symmetric model:
        // - floor mode attracts downward and bounces at y=0
        // - ceiling mode attracts upward and bounces at y=1
        let acceleration = prefersCeilingBounce ? gravity : -gravity
        let bounceBoundary = prefersCeilingBounce ? 1.0 : 0.0
        let oppositeBoundary = prefersCeilingBounce ? 0.0 : 1.0
        let bounceAwaySign = prefersCeilingBounce ? -1.0 : 1.0

        velocity += acceleration * dt
        position += velocity * dt

        if (prefersCeilingBounce && position > bounceBoundary) || (!prefersCeilingBounce && position < bounceBoundary) {
            position = bounceBoundary
            let reflected = abs(velocity) * 0.82
            velocity = bounceAwaySign * ((reflected * 0.35) + (desiredLaunchVelocity * 0.65))
        }

        if (prefersCeilingBounce && position < oppositeBoundary) || (!prefersCeilingBounce && position > oppositeBoundary) {
            position = oppositeBoundary
            if (prefersCeilingBounce && velocity < 0) || (!prefersCeilingBounce && velocity > 0) {
                velocity = -bounceAwaySign * max(0.02, abs(velocity) * 0.20)
            }
        }
    }

    private func updateFrameIndexFromPosition() {
        let normalized = max(0.0, min(1.0, position))
        let idx = Int((normalized * Double(max(1, frameCount - 1))).rounded())
        frameIndex = max(0, min(frameCount - 1, idx))
    }

    private static func makeFrames() -> [NSImage] {
        let frameCount = 25
        let yMin: CGFloat = -4.4
        let yMax: CGFloat = 5.8
        let yOffsets: [CGFloat] = (0..<frameCount).map { idx in
            let t = CGFloat(idx) / CGFloat(max(1, frameCount - 1))
            return yMin + (yMax - yMin) * t
        }
        return yOffsets.map { makeFrame(yOffset: $0, color: .white) }
    }

    private static func makeCenterFrame(color: NSColor) -> NSImage {
        makeFrame(yOffset: 0, color: color)
    }

    private static func makeFrame(yOffset: CGFloat, color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 16)
        let dotDiameter: CGFloat = 3.0
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let centerX = size.width / 2
        let centerY = (size.height / 2) + yOffset
        let dotRect = NSRect(
            x: (centerX - dotDiameter / 2).rounded(),
            y: (centerY - dotDiameter / 2).rounded(),
            width: dotDiameter,
            height: dotDiameter
        )

        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        image.isTemplate = false
        return image
    }
}
