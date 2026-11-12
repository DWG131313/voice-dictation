import Foundation

/// A recording: mono 16 kHz samples in -1...1.
public struct AudioClip: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }

    /// Largest absolute sample value.
    public var peak: Float { samples.reduce(0) { max($0, abs($1)) } }
}
