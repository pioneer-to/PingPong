//
//  SoundManager.swift
//  PongBar
//
//  Lightweight tone-based ping/pong sound playback.
//

import Foundation
import AVFoundation

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let pitchEffect = AVAudioUnitTimePitch()
    private let baseBuffer: AVAudioPCMBuffer?
    private var isEngineStarted = false

    private init() {
        engine.attach(playerNode)
        engine.attach(pitchEffect)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        engine.connect(playerNode, to: pitchEffect, format: format)
        engine.connect(pitchEffect, to: engine.mainMixerNode, format: format)

        baseBuffer = SoundManager.makePingBuffer(format: format)
    }

    /// Pitch in cents: 0 = original, +1200 = one octave up, -1200 = one octave down.
    func playPing(pitch: Float = 0) {
        guard let buffer = baseBuffer else { return }
        startEngineIfNeeded()
        pitchEffect.pitch = pitch
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func startEngineIfNeeded() {
        guard !isEngineStarted else { return }
        do {
            try engine.start()
            isEngineStarted = true
        } catch {
            isEngineStarted = false
        }
    }

    private static func makePingBuffer(format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let format else { return nil }
        let durationSeconds = 0.08
        let frameCount = AVAudioFrameCount(durationSeconds * format.sampleRate)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let channelData = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = frameCount
        let sampleRate = format.sampleRate
        let frequency = 900.0

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-38.0 * t)
            let sample = sin(2.0 * .pi * frequency * t) * envelope * 0.28
            channelData[i] = Float(sample)
        }

        return buffer
    }
}
