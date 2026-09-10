import Foundation
import os

/// Levels and delivery counters shared between the capture loops and the UI.
///
/// The capture loops write here under a lock — nanoseconds — and a 10 Hz
/// timer on the main actor copies the values into the observable properties
/// the level bars read. The loops themselves never touch the main actor per
/// buffer. They used to: the system loop published its level with
/// `await MainActor.run` 94 times a second, each publish invalidated SwiftUI
/// and queued a render, and each next hop waited behind that render. As the
/// live transcript grew the renders slowed, the loop fell behind real time,
/// and the audio backed up in the stream until the recording stopped and the
/// backlog was discarded — the far side of a 30-minute meeting cut off at
/// minute 21 (2026-09-10). The mic loop, at 10 hops a second, never noticed.
final class AudioLevelMeter: Sendable {

    struct Snapshot: Sendable, Equatable {
        var micLevel: Float = 0
        var systemLevel: Float = 0
        /// When system audio last carried signal. Read by the mic loop's
        /// silence check, which used to fetch it from the main actor.
        var lastSystemActivity: Date?
        var micConsumed: Int = 0
        var systemConsumed: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    /// Above this a buffer counts as carrying signal.
    static let activityFloor: Float = 0.0005

    func recordMic(level: Float) {
        state.withLock {
            $0.micLevel = level
            $0.micConsumed += 1
        }
    }

    func recordSystem(level: Float) {
        state.withLock {
            $0.systemLevel = level
            $0.systemConsumed += 1
            if level > Self.activityFloor { $0.lastSystemActivity = Date() }
        }
    }

    var snapshot: Snapshot { state.withLock { $0 } }

    func reset() {
        state.withLock { $0 = Snapshot() }
    }

    // MARK: - Backlog

    /// Buffers delivered by the hardware callback but not yet consumed. The
    /// number that would have said, on 2026-09-10, "the system loop is nine
    /// minutes behind".
    static func backlog(delivered: Int, consumed: Int) -> Int {
        max(0, delivered - consumed)
    }

    /// Seconds of audio a backlog represents.
    static func backlogSeconds(buffers: Int, framesPerBuffer: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(buffers * framesPerBuffer) / sampleRate
    }

    /// A backlog worth shouting about: more than this much audio waiting.
    static let backlogWarningSeconds: Double = 2
}
