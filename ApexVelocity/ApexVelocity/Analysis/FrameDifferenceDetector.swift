import AVFoundation
import Accelerate
import CoreGraphics

/// Detects golf ball movement using frame differencing on post-impact frames.
struct FrameDifferenceDetector {

    struct Config {
        var framesToExtract: Int = 20
        var differenceThreshold: UInt8 = 30
        var minBlobSize: Int = 4
        var maxBlobSize: Int = 40
        var searchRegionTopRatio: CGFloat = 0.0
        var searchRegionBottomRatio: CGFloat = 0.8
    }

    /// Extract frames around the impact time and detect ball positions.
    static func detect(
        from asset: AVAsset,
        impactTime: CMTime,
        config: Config = Config()
    ) async throws -> [BallDetection] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 240)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 240)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { return [] }
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let fps = Double(nominalFrameRate > 0 ? nominalFrameRate : 30)
        let frameDuration = 1.0 / fps

        // Extract frames starting from impact
        var frames: [(image: CGImage, time: CMTime)] = []
        for i in 0...config.framesToExtract {
            let time = CMTimeAdd(impactTime, CMTime(seconds: Double(i) * frameDuration, preferredTimescale: 600))
            do {
                var actualTime = CMTime.zero
                let image = try generator.copyCGImage(at: time, actualTime: &actualTime)
                frames.append((image: image, time: actualTime))
            } catch {
                continue
            }
        }

        guard frames.count >= 3 else { return [] }

        let videoWidth = frames[0].image.width
        let videoHeight = frames[0].image.height
        let pixelCount = videoWidth * videoHeight

        var detections: [BallDetection] = []

        // Process consecutive frame pairs
        var prevGray: [UInt8]? = nil

        for i in 0..<frames.count {
            let currGray = grayscalePixels(from: frames[i].image, width: videoWidth, height: videoHeight)
            guard let curr = currGray else { continue }

            if let prev = prevGray {
                // Compute absolute difference
                var diff = [UInt8](repeating: 0, count: pixelCount)
                for p in 0..<pixelCount {
                    let a = Int(prev[p])
                    let b = Int(curr[p])
                    diff[p] = UInt8(min(255, abs(a - b)))
                }

                // Find ball candidate in difference image
                if let center = findBallCandidate(
                    in: diff,
                    width: videoWidth,
                    height: videoHeight,
                    config: config
                ) {
                    let normalizedCenter = CGPoint(
                        x: center.x / CGFloat(videoWidth),
                        y: center.y / CGFloat(videoHeight)
                    )

                    let detection = BallDetection(
                        normalizedCenter: normalizedCenter,
                        confidence: 0.8,
                        boundingBox: CGRect(
                            x: normalizedCenter.x - 0.01,
                            y: normalizedCenter.y - 0.01,
                            width: 0.02,
                            height: 0.02
                        ),
                        timestamp: CMTimeGetSeconds(frames[i].time)
                    )
                    detections.append(detection)
                }
            }

            prevGray = curr
        }

        return detections
    }

    // MARK: - Image Processing

    private static func grayscalePixels(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func findBallCandidate(
        in diff: [UInt8],
        width: Int,
        height: Int,
        config: Config
    ) -> CGPoint? {
        let startRow = Int(CGFloat(height) * config.searchRegionTopRatio)
        let endRow = Int(CGFloat(height) * config.searchRegionBottomRatio)

        var bestX: Int = 0
        var bestY: Int = 0
        var bestScore: Int = 0

        let step = 2
        for y in stride(from: startRow, to: endRow, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let val = Int(diff[y * width + x])
                if val > Int(config.differenceThreshold) {
                    // Measure local brightness cluster
                    let score = measureCluster(diff, x: x, y: y, width: width, height: height, threshold: config.differenceThreshold)
                    if score >= config.minBlobSize && score <= config.maxBlobSize && score > bestScore {
                        bestScore = score
                        bestX = x
                        bestY = y
                    }
                }
            }
        }

        guard bestScore >= config.minBlobSize else { return nil }
        return CGPoint(x: bestX, y: bestY)
    }

    private static func measureCluster(
        _ buffer: [UInt8],
        x: Int, y: Int,
        width: Int, height: Int,
        threshold: UInt8
    ) -> Int {
        var count = 0
        let radius = 15
        for dy in stride(from: -radius, through: radius, by: 2) {
            for dx in stride(from: -radius, through: radius, by: 2) {
                let px = x + dx
                let py = y + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                if buffer[py * width + px] > threshold {
                    count += 1
                }
            }
        }
        return count
    }
}
