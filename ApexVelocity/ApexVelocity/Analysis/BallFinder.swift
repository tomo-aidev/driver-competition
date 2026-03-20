import AVFoundation
import Vision
import CoreImage
import CoreGraphics

/// Robust golf ball detection using Body Pose → Search Area → Color/Shape detection.
/// Tested on 3 different golf videos (white ball dark env, white ball bright env, orange ball).
struct BallFinder {

    struct Result {
        let position: CGPoint  // normalized 0-1
        let confidence: Float
        let method: String
    }

    /// Find the golf ball in a video.
    static func find(in asset: AVAsset, beforeTime: Double? = nil) async -> Result? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        generator.maximumSize = CGSize(width: 1080, height: 1920)

        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 10, preferredTimescale: 600)
        let totalSeconds = CMTimeGetSeconds(duration)
        let maxSample = beforeTime ?? min(totalSeconds, 10.0)

        // Sample multiple frames
        let sampleTimes: [Double] = stride(from: 0.5, to: maxSample, by: 1.0).map { $0 }

        var allCandidates: [(pos: CGPoint, confidence: Float, frame: Int)] = []

        for (frameIdx, time) in sampleTimes.enumerated() {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            var actualTime = CMTime.zero
            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                continue
            }

            // Step 1: Get search area from body pose
            let searchArea = await estimateSearchArea(image: image)

            // Step 2: Find ball candidates in search area
            let candidates = findBallCandidates(in: image, searchArea: searchArea)

            for c in candidates {
                allCandidates.append((pos: c.pos, confidence: c.conf, frame: frameIdx))
            }
        }

        guard !allCandidates.isEmpty else {
            print("[BallFinder] No candidates found")
            return nil
        }

        // Find most consistent position across frames
        return findBestCandidate(allCandidates)
    }

    // MARK: - Body Pose Search Area

    private static func estimateSearchArea(image: CGImage) async -> CGRect {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectHumanBodyPoseRequest()

        try? handler.perform([request])

        guard let body = request.results?.first else {
            // Fallback: bottom 40%, center 60%
            return CGRect(x: 0.20, y: 0.55, width: 0.60, height: 0.40)
        }

        // Get key joint positions
        let rightWrist = try? body.recognizedPoint(.rightWrist)
        let leftWrist = try? body.recognizedPoint(.leftWrist)
        let rightAnkle = try? body.recognizedPoint(.rightAnkle)
        let leftAnkle = try? body.recognizedPoint(.leftAnkle)
        let rightHip = try? body.recognizedPoint(.rightHip)
        let leftHip = try? body.recognizedPoint(.leftHip)

        guard let rw = rightWrist, rw.confidence > 0.2,
              let lw = leftWrist, lw.confidence > 0.2,
              let ra = rightAnkle, ra.confidence > 0.2 else {
            return CGRect(x: 0.20, y: 0.55, width: 0.60, height: 0.40)
        }

        // Vision coordinates: origin bottom-left, normalize 0-1
        let wristX = (rw.location.x + lw.location.x) / 2
        let wristY = (rw.location.y + lw.location.y) / 2
        let ankleY = ra.location.y
        let hipX = ((rightHip?.location.x ?? wristX) + (leftHip?.location.x ?? wristX)) / 2
        let hipY = ((rightHip?.location.y ?? wristY) + (leftHip?.location.y ?? wristY)) / 2

        // Ball is at the END of the club, extending from wrists away from body
        let dirX = wristX - hipX
        let dirY = wristY - hipY

        // Extend in that direction (club extends ~15% of frame beyond wrists)
        let ballEstX = wristX + dirX * 1.5 + 0.15
        let ballEstY = ankleY + 0.02  // ground level (Vision Y: bottom = 0)

        // Convert to top-left origin for CGRect
        let margin: CGFloat = 0.15
        let searchRect = CGRect(
            x: max(0, ballEstX - margin),
            y: max(0, 1.0 - ballEstY - margin),  // flip Y
            width: margin * 2,
            height: margin * 2
        )

        print("[BallFinder] Pose → search: x=\(String(format: "%.2f", searchRect.midX)) y=\(String(format: "%.2f", searchRect.midY))")
        return searchRect
    }

    // MARK: - Ball Candidate Detection

    private struct Candidate {
        let pos: CGPoint  // normalized
        let conf: Float
    }

    private static func findBallCandidates(in image: CGImage, searchArea: CGRect) -> [Candidate] {
        let width = image.width
        let height = image.height

        // Render to RGBA
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Search area in pixels
        let sx1 = max(0, Int(searchArea.minX * CGFloat(width)))
        let sy1 = max(0, Int(searchArea.minY * CGFloat(height)))
        let sx2 = min(width, Int(searchArea.maxX * CGFloat(width)))
        let sy2 = min(height, Int(searchArea.maxY * CGFloat(height)))

        guard sx2 > sx1 && sy2 > sy1 else { return [] }

        // Compute average brightness in search area (for adaptive threshold)
        var totalBrightness = 0
        var sampleCount = 0
        let step = 6
        for y in stride(from: sy1, to: sy2, by: step) {
            for x in stride(from: sx1, to: sx2, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Int(pixelData[offset])
                let g = Int(pixelData[offset + 1])
                let b = Int(pixelData[offset + 2])
                totalBrightness += (r + g + b) / 3
                sampleCount += 1
            }
        }
        let avgBrightness = sampleCount > 0 ? totalBrightness / sampleCount : 80

        // Adaptive bright threshold: avg + 20 (for dark scenes) or at least 100
        let brightThreshold = max(70, avgBrightness + 20)

        var candidates: [Candidate] = []

        for y in stride(from: sy1, to: sy2, by: 3) {
            for x in stride(from: sx1, to: sx2, by: 3) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 3 < pixelData.count else { continue }

                let r = Int(pixelData[offset])
                let g = Int(pixelData[offset + 1])
                let b = Int(pixelData[offset + 2])
                let brightness = (r + g + b) / 3

                // HSV-like checks
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let saturation = maxC - minC

                // White ball: bright, low saturation
                let isWhite = brightness > brightThreshold && saturation < 80

                // Orange/yellow ball: high R, medium G, low B
                let isOrange = r > 130 && g > 80 && b < max(100, g) && saturation > 40

                // Pink ball
                let isPink = r > 140 && b > 100 && g < r && saturation > 30

                guard isWhite || isOrange || isPink else { continue }

                // Measure cluster size and surroundings
                var clusterCount = 0
                var surroundBrightness = 0
                var surroundCount = 0

                for dy in stride(from: -18, through: 18, by: 4) {
                    for dx in stride(from: -18, through: 18, by: 4) {
                        let px = x + dx, py = y + dy
                        guard px >= 0, px < width, py >= 0, py < height else { continue }
                        let pOffset = py * bytesPerRow + px * bytesPerPixel
                        guard pOffset + 2 < pixelData.count else { continue }
                        let pBright = (Int(pixelData[pOffset]) + Int(pixelData[pOffset+1]) + Int(pixelData[pOffset+2])) / 3
                        let dist = abs(dx) + abs(dy)

                        if dist <= 10 {
                            if pBright > brightThreshold - 20 { clusterCount += 1 }
                        } else {
                            surroundBrightness += pBright
                            surroundCount += 1
                        }
                    }
                }

                guard clusterCount >= 2 && clusterCount <= 25 else { continue }
                let avgSurround = surroundCount > 0 ? surroundBrightness / surroundCount : brightness
                let contrast = brightness - avgSurround
                guard contrast > 10 else { continue }

                // Score
                let score = Float(contrast) / 100.0 + Float(clusterCount) / 20.0

                candidates.append(Candidate(
                    pos: CGPoint(x: CGFloat(x) / CGFloat(width), y: CGFloat(y) / CGFloat(height)),
                    conf: min(1.0, score)
                ))
            }
        }

        // Sort by confidence, take top 10
        return Array(candidates.sorted { $0.conf > $1.conf }.prefix(10))
    }

    // MARK: - Best Candidate Selection

    private static func findBestCandidate(_ candidates: [(pos: CGPoint, confidence: Float, frame: Int)]) -> Result {
        // Cluster nearby candidates
        let threshold: CGFloat = 0.05
        var clusters: [[(pos: CGPoint, confidence: Float, frame: Int)]] = []

        for c in candidates {
            var added = false
            for i in 0..<clusters.count {
                let center = clusters[i][0].pos
                if hypot(c.pos.x - center.x, c.pos.y - center.y) < threshold {
                    clusters[i].append(c)
                    added = true
                    break
                }
            }
            if !added {
                clusters.append([c])
            }
        }

        // Best = most frames + highest confidence
        let best = clusters.max(by: { a, b in
            let fA = Set(a.map(\.frame)).count
            let fB = Set(b.map(\.frame)).count
            let cA = a.map(\.confidence).reduce(0, +)
            let cB = b.map(\.confidence).reduce(0, +)
            return (fA * 100 + Int(cA * 100)) < (fB * 100 + Int(cB * 100))
        })

        guard let bestCluster = best, !bestCluster.isEmpty else {
            let top = candidates.max(by: { $0.confidence < $1.confidence })!
            return Result(position: top.pos, confidence: top.confidence, method: "single")
        }

        let avgX = bestCluster.map(\.pos.x).reduce(0, +) / CGFloat(bestCluster.count)
        let avgY = bestCluster.map(\.pos.y).reduce(0, +) / CGFloat(bestCluster.count)
        let avgConf = bestCluster.map(\.confidence).reduce(0, +) / Float(bestCluster.count)
        let frames = Set(bestCluster.map(\.frame)).count

        return Result(
            position: CGPoint(x: avgX, y: avgY),
            confidence: min(1.0, avgConf * Float(frames) / 3.0),
            method: "pose+color(\(bestCluster.count)pts/\(frames)f)"
        )
    }
}
