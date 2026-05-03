import AVFoundation
import Accelerate

/// Detects the moment of club-ball impact from the audio track of a golf video.
///
/// Key insight: Impact is the FIRST sudden energy spike, not the largest.
/// A golf video may contain multiple loud sounds (talking, second swing, etc.)
/// but the impact we want is the FIRST sharp transient.
struct ImpactDetector {

    /// Detect ALL impact candidates from audio.
    /// Returns sorted by time, caller should pick the best one using visual cues.
    static func detectAllCandidates(from asset: AVAsset) async throws -> [(time: Double, energy: Float, ratio: Float)] {
        guard let result = try await analyzeAudio(from: asset) else { return [] }
        return result
    }

    /// Detect the impact moment in the video's audio track.
    /// Returns the CMTime of the impact, or nil if no clear impact is found.
    static func detectImpact(from asset: AVAsset) async throws -> CMTime? {
        guard let candidates = try await analyzeAudio(from: asset),
              let best = candidates.first else { return nil }
        return CMTime(seconds: best.time, preferredTimescale: 600)
    }

    /// Core audio analysis - returns all spike candidates sorted by time.
    private static func analyzeAudio(from asset: AVAsset) async throws -> [(time: Double, energy: Float, ratio: Float)]? {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
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
        var channelCount: Int = 1

        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        if let formatDesc = formatDescriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
            if let desc = asbd?.pointee {
                if desc.mSampleRate > 0 { sampleRate = desc.mSampleRate }
                if desc.mChannelsPerFrame > 0 { channelCount = Int(desc.mChannelsPerFrame) }
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

        // Convert stereo to mono by averaging channels
        var monoSamples: [Float]
        if channelCount >= 2 {
            let monoCount = allSamples.count / channelCount
            monoSamples = [Float](repeating: 0, count: monoCount)
            for i in 0..<monoCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += allSamples[i * channelCount + ch]
                }
                monoSamples[i] = sum / Float(channelCount)
            }
        } else {
            monoSamples = allSamples
        }

        // Short-time energy analysis
        let windowSize = Int(sampleRate * 0.005) // 5ms window (sharper detection)
        let hopSize = windowSize / 2
        var energies: [(time: Double, energy: Float)] = []

        var i = 0
        while i + windowSize <= monoSamples.count {
            var sumSquared: Float = 0
            vDSP_svesq(Array(monoSamples[i..<i + windowSize]), 1, &sumSquared, vDSP_Length(windowSize))
            let energy = sumSquared / Float(windowSize)
            let time = Double(i) / sampleRate
            energies.append((time: time, energy: energy))
            i += hopSize
        }

        guard !energies.isEmpty else { return nil }

        // Calculate global baseline (median energy)
        let sortedEnergies = energies.map(\.energy).sorted()
        let medianEnergy = sortedEnergies[sortedEnergies.count / 2]
        let threshold = max(medianEnergy * 8.0, 0.001) // 8x above median

        // Find the FIRST spike that exceeds threshold
        // Use rolling average to detect sudden change
        let rollingWindowSize = 30  // ~75ms lookback
        let skipStart = 0.3  // skip first 0.3s (handling noise)

        var candidates: [(time: Double, ratio: Float, energy: Float)] = []

        for j in rollingWindowSize..<energies.count {
            let time = energies[j].time
            if time < skipStart { continue }

            // Rolling average of previous windows
            var rollingSum: Float = 0
            for k in (j - rollingWindowSize)..<j {
                rollingSum += energies[k].energy
            }
            let rollingAvg = rollingSum / Float(rollingWindowSize)

            guard rollingAvg > 0 else { continue }
            let ratio = energies[j].energy / rollingAvg

            // Impact: sudden spike 3x+ above local average AND above global threshold
            if ratio > 3.0 && energies[j].energy > threshold {
                candidates.append((time: time, ratio: ratio, energy: energies[j].energy))
            }
        }

        guard !candidates.isEmpty else {
            print("[Impact] No impact detected (no spikes above threshold)")
            return nil
        }

        // Take the FIRST candidate (not the largest!)
        // Group nearby candidates (within 100ms) and pick the earliest in each group
        var groups: [[(time: Double, ratio: Float, energy: Float)]] = []
        for candidate in candidates.sorted(by: { $0.time < $1.time }) {
            if let lastGroup = groups.last, let lastCandidate = lastGroup.last,
               candidate.time - lastCandidate.time < 0.1 {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        // Return ALL group peaks sorted by time
        var groupPeaks: [(time: Double, energy: Float, ratio: Float)] = []
        for group in groups {
            let peak = group.max(by: { $0.energy < $1.energy })!
            groupPeaks.append((time: peak.time, energy: peak.energy, ratio: peak.ratio))
        }
        groupPeaks.sort { $0.time < $1.time }

        print("[Impact] Found \(groupPeaks.count) candidates:")
        for (i, peak) in groupPeaks.prefix(8).enumerated() {
            print("[Impact]   #\(i): \(String(format: "%.3f", peak.time))s energy=\(String(format: "%.4f", peak.energy)) ratio=\(String(format: "%.1f", peak.ratio))")
        }

        return groupPeaks
    }
}
