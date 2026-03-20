import AVFoundation
import Accelerate

/// Detects the moment of club-ball impact from the audio track of a golf video.
/// Uses short-time energy analysis to find the characteristic transient spike.
struct ImpactDetector {

    /// Detect the impact moment in the video's audio track.
    /// Returns the CMTime of the impact, or nil if no clear impact is found.
    static func detectImpact(from asset: AVAsset) async throws -> CMTime? {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil // No audio track — caller should fall back to frame analysis
        }

        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        // Collect all audio samples
        var allSamples: [Float] = []
        var sampleRate: Double = 44100

        // Get the actual sample rate from the track
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        if let formatDesc = formatDescriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
            if let rate = asbd?.pointee.mSampleRate, rate > 0 {
                sampleRate = rate
            }
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            guard let ptr = dataPointer else { continue }
            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
            let buffer = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
            allSamples.append(contentsOf: buffer)
        }

        guard !allSamples.isEmpty else { return nil }

        // Short-time energy analysis
        let windowSize = Int(sampleRate * 0.01) // 10ms window
        let hopSize = windowSize / 2
        var energies: [(time: Double, energy: Float)] = []

        var i = 0
        while i + windowSize <= allSamples.count {
            var sumSquared: Float = 0
            vDSP_svesq(Array(allSamples[i..<i + windowSize]), 1, &sumSquared, vDSP_Length(windowSize))
            let energy = sumSquared / Float(windowSize)
            let time = Double(i) / sampleRate
            energies.append((time: time, energy: energy))
            i += hopSize
        }

        guard !energies.isEmpty else { return nil }

        // Find the peak energy spike
        // Use a rolling average to detect sudden spikes
        let rollingWindowSize = 20
        var bestTime: Double = 0
        var bestRatio: Float = 0

        for j in rollingWindowSize..<energies.count {
            // Calculate rolling average of previous windows
            var rollingSum: Float = 0
            for k in (j - rollingWindowSize)..<j {
                rollingSum += energies[k].energy
            }
            let rollingAvg = rollingSum / Float(rollingWindowSize)

            guard rollingAvg > 0 else { continue }
            let ratio = energies[j].energy / rollingAvg

            // Impact should be a sudden spike (3x+ above rolling average)
            if ratio > bestRatio && ratio > 3.0 {
                bestRatio = ratio
                bestTime = energies[j].time
            }
        }

        guard bestRatio > 3.0 else { return nil }

        return CMTime(seconds: bestTime, preferredTimescale: 600)
    }
}
