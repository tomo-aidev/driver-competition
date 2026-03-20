import AVFoundation
import Vision
import CoreImage
import CoreGraphics

/// Robust golf ball detection using multiple strategies.
/// Searches across wider area with adaptive thresholds.
struct BallFinder {

    struct Result {
        let position: CGPoint  // normalized 0-1
        let confidence: Float
        let method: String
    }

    /// Find the golf ball in a video before the swing.
    /// Tries multiple time samples and detection methods.
    static func find(in asset: AVAsset, beforeTime: Double? = nil) async -> Result? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        generator.maximumSize = CGSize(width: 1080, height: 1920) // cap resolution

        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 10, preferredTimescale: 600)
        let totalSeconds = CMTimeGetSeconds(duration)
        let maxSample = beforeTime ?? min(totalSeconds, 10.0)

        // Sample many times throughout the video
        let sampleTimes: [Double] = stride(from: 0.5, to: maxSample, by: 0.5).map { $0 }

        // Collect candidates across all frames
        var allCandidates: [(pos: CGPoint, confidence: Float, frame: Int)] = []

        for (frameIdx, time) in sampleTimes.enumerated() {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            var actualTime = CMTime.zero
            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                continue
            }

            // Method 1: Brightness contrast detection (works for white balls)
            if let candidates = detectByBrightnessContrast(in: image) {
                for c in candidates {
                    allCandidates.append((pos: c.0, confidence: c.1, frame: frameIdx))
                }
            }

            // Method 2: Circle detection via contours
            if let candidates = detectByCircularity(in: image) {
                for c in candidates {
                    allCandidates.append((pos: c.0, confidence: c.1, frame: frameIdx))
                }
            }
        }

        guard !allCandidates.isEmpty else {
            print("[BallFinder] No candidates found in \(sampleTimes.count) frames")
            return nil
        }

        // Cluster nearby candidates and find the most consistent position
        // A real ball appears at the same position across multiple frames
        let best = findMostConsistentPosition(candidates: allCandidates)

        print("[BallFinder] Best: (\(String(format: "%.3f", best.position.x)), \(String(format: "%.3f", best.position.y))) conf=\(String(format: "%.2f", best.confidence))")
        return best
    }

    // MARK: - Method 1: Brightness Contrast

    private static func detectByBrightnessContrast(in image: CGImage) -> [(CGPoint, Float)]? {
        let width = image.width
        let height = image.height

        // Draw image into a known pixel format (RGBA)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Search area: bottom 50% of frame, full width
        // (much wider than before to handle different camera angles)
        let searchStartY = height * 40 / 100
        let searchEndY = height * 95 / 100
        let searchStartX = width * 5 / 100
        let searchEndX = width * 95 / 100

        var candidates: [(CGPoint, Float)] = []
        let step = 4

        // First pass: find adaptive brightness threshold
        // Compute average brightness in search area
        var totalBrightness: Int = 0
        var sampleCount = 0
        for y in stride(from: searchStartY, to: searchEndY, by: 10) {
            for x in stride(from: searchStartX, to: searchEndX, by: 10) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Int(pixelData[offset])
                let g = Int(pixelData[offset + 1])
                let b = Int(pixelData[offset + 2])
                totalBrightness += (r + g + b) / 3
                sampleCount += 1
            }
        }
        let avgBrightness = sampleCount > 0 ? totalBrightness / sampleCount : 128

        // Ball must be significantly brighter than average
        // Adaptive threshold: at least 40 units above average, minimum 100
        let brightThreshold = max(100, avgBrightness + 40)

        for y in stride(from: searchStartY, to: searchEndY, by: step) {
            for x in stride(from: searchStartX, to: searchEndX, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 3 < pixelData.count else { continue }

                let r = Int(pixelData[offset])
                let g = Int(pixelData[offset + 1])
                let b = Int(pixelData[offset + 2])
                let brightness = (r + g + b) / 3

                // Must be bright enough
                guard brightness > brightThreshold else { continue }

                // Check if this is a small bright cluster on darker background
                let (clusterSize, avgSurround) = measureCluster(
                    pixelData: pixelData, cx: x, cy: y,
                    width: width, height: height,
                    bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel,
                    brightThreshold: brightThreshold
                )

                // Ball-sized cluster: 3-60 pixels at step=4
                guard clusterSize >= 2 && clusterSize <= 30 else { continue }

                // Must have contrast with surroundings
                let contrast = brightness - avgSurround
                guard contrast > 30 else { continue }

                let confidence = Float(contrast) / 200.0 * Float(min(clusterSize, 15)) / 15.0
                let normalizedPos = CGPoint(
                    x: CGFloat(x) / CGFloat(width),
                    y: CGFloat(y) / CGFloat(height)
                )
                candidates.append((normalizedPos, min(1.0, confidence)))
            }
        }

        return candidates.isEmpty ? nil : candidates
    }

    private static func measureCluster(
        pixelData: [UInt8], cx: Int, cy: Int,
        width: Int, height: Int,
        bytesPerRow: Int, bytesPerPixel: Int,
        brightThreshold: Int
    ) -> (size: Int, avgSurround: Int) {
        var clusterCount = 0
        var surroundTotal = 0
        var surroundCount = 0

        let innerRadius = 12
        let outerRadius = 25

        for dy in stride(from: -outerRadius, through: outerRadius, by: 4) {
            for dx in stride(from: -outerRadius, through: outerRadius, by: 4) {
                let px = cx + dx
                let py = cy + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }

                let offset = py * bytesPerRow + px * bytesPerPixel
                guard offset + 2 < pixelData.count else { continue }

                let brightness = (Int(pixelData[offset]) + Int(pixelData[offset + 1]) + Int(pixelData[offset + 2])) / 3
                let dist = abs(dx) + abs(dy)

                if dist <= innerRadius {
                    if brightness > brightThreshold {
                        clusterCount += 1
                    }
                } else {
                    surroundTotal += brightness
                    surroundCount += 1
                }
            }
        }

        let avgSurround = surroundCount > 0 ? surroundTotal / surroundCount : 128
        return (clusterCount, avgSurround)
    }

    // MARK: - Method 2: Circularity Detection

    private static func detectByCircularity(in image: CGImage) -> [(CGPoint, Float)]? {
        // Use Vision framework contour detection
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = false // ball is bright on dark grass

        try? handler.perform([request])

        guard let contours = request.results?.first else { return nil }

        var candidates: [(CGPoint, Float)] = []
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        for i in 0..<contours.contourCount {
            guard let contour = try? contours.contour(at: i) else { continue }
            let pointCount = contour.normalizedPoints.count
            guard pointCount >= 8 && pointCount <= 200 else { continue }

            // Compute bounding box
            let points = contour.normalizedPoints
            var minX: Float = 1, maxX: Float = 0, minY: Float = 1, maxY: Float = 0
            for pt in points {
                minX = min(minX, pt.x)
                maxX = max(maxX, pt.x)
                minY = min(minY, pt.y)
                maxY = max(maxY, pt.y)
            }

            let bw = maxX - minX
            let bh = maxY - minY
            guard bw > 0.002, bh > 0.002 else { continue }  // too small
            guard bw < 0.08, bh < 0.08 else { continue }     // too large for a ball

            // Circularity: aspect ratio close to 1
            let aspect = min(bw, bh) / max(bw, bh)
            guard aspect > 0.5 else { continue }

            // Must be in lower 60% of frame
            let centerY = (minY + maxY) / 2
            guard centerY < 0.4 else { continue }  // Vision coordinates: origin bottom-left

            let centerX = (minX + maxX) / 2
            let normalizedPos = CGPoint(
                x: CGFloat(centerX),
                y: CGFloat(1.0 - centerY)  // flip to top-left origin
            )

            let confidence = aspect * 0.8
            candidates.append((normalizedPos, confidence))
        }

        return candidates.isEmpty ? nil : candidates
    }

    // MARK: - Consistency Check

    private static func findMostConsistentPosition(
        candidates: [(pos: CGPoint, confidence: Float, frame: Int)]
    ) -> Result {
        // Group candidates by proximity (within 5% of frame)
        let threshold: CGFloat = 0.05

        var clusters: [[(pos: CGPoint, confidence: Float, frame: Int)]] = []

        for candidate in candidates {
            var foundCluster = false
            for i in 0..<clusters.count {
                let clusterCenter = clusters[i][0].pos
                let dist = hypot(candidate.pos.x - clusterCenter.x, candidate.pos.y - clusterCenter.y)
                if dist < threshold {
                    clusters[i].append(candidate)
                    foundCluster = true
                    break
                }
            }
            if !foundCluster {
                clusters.append([candidate])
            }
        }

        // Best cluster: most detections across different frames + highest confidence
        let best = clusters.max(by: { a, b in
            let framesA = Set(a.map(\.frame)).count
            let framesB = Set(b.map(\.frame)).count
            let confA = a.map(\.confidence).reduce(0, +) / Float(a.count)
            let confB = b.map(\.confidence).reduce(0, +) / Float(b.count)
            return (framesA * 10 + Int(confA * 100)) < (framesB * 10 + Int(confB * 100))
        })

        guard let bestCluster = best, !bestCluster.isEmpty else {
            // Fallback: highest single confidence
            let top = candidates.max(by: { $0.confidence < $1.confidence })!
            return Result(position: top.pos, confidence: top.confidence, method: "single")
        }

        // Average position of best cluster
        let avgX = bestCluster.map(\.pos.x).reduce(0, +) / CGFloat(bestCluster.count)
        let avgY = bestCluster.map(\.pos.y).reduce(0, +) / CGFloat(bestCluster.count)
        let avgConf = bestCluster.map(\.confidence).reduce(0, +) / Float(bestCluster.count)
        let frameCount = Set(bestCluster.map(\.frame)).count

        return Result(
            position: CGPoint(x: avgX, y: avgY),
            confidence: min(1.0, avgConf * Float(frameCount) / 3.0),
            method: "cluster(\(bestCluster.count)pts/\(frameCount)frames)"
        )
    }
}
