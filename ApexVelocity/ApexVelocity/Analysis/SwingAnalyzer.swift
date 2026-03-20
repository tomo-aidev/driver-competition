import AVFoundation
import CoreGraphics

/// Detected club head position and phase
struct ClubHeadDetection {
    let position: CGPoint  // normalized 0-1
    let frameTime: Double  // seconds
    let phase: SwingPhase
}

enum SwingPhase {
    case address
    case backswing
    case downswing
    case postImpact
}

/// Analyzes golf swing by tracking the club head's motion arc.
/// Uses frame differencing to find dark, fast-moving pixels,
/// then extracts the swing arc tip (furthest from pivot with continuity).
struct SwingAnalyzer {

    static func analyzeSwing(
        from asset: AVAsset,
        impactTime: CMTime,
        ballPosition: CGPoint // normalized
    ) async throws -> [ClubHeadDetection] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { return [] }
        let fps = Double(try await videoTrack.load(.nominalFrameRate))
        let size = try await videoTrack.load(.naturalSize)
        let w = Int(size.width)
        let h = Int(size.height)

        let impactSeconds = CMTimeGetSeconds(impactTime)

        // Pivot point (golfer's body center, approximate)
        let pivotX = Int(Double(w) * 0.32)
        let pivotY = Int(Double(h) * 0.52)
        let ballX = Int(Double(ballPosition.x) * Double(w))
        let ballY = Int(Double(ballPosition.y) * Double(h))

        // Collect motion points: dark + moving pixels
        let startTime = max(0, impactSeconds - 1.8)
        let endTime = impactSeconds + 0.5
        let frameInterval = 0.1 // 10fps sampling for time bins

        var timeBins: [Double: [(x: Int, y: Int, motion: Float)]] = [:]
        var prevGray: [UInt8]?
        var prevTime = startTime

        // Sample every ~3 frames
        let sampleInterval = 3.0 / fps
        var t = startTime
        while t < endTime {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var actualTime = CMTime.zero
            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                t += sampleInterval
                continue
            }

            let gray = grayscalePixels(from: image, width: w, height: h)
            guard let currGray = gray else {
                t += sampleInterval
                continue
            }

            if let prev = prevGray {
                let timeBin = (t * 10).rounded() / 10  // quantize to 0.1s

                // Frame differencing
                for y in stride(from: 0, to: h, by: 3) {
                    for x in stride(from: 0, to: w, by: 3) {
                        let idx = y * w + x
                        let diff = abs(Int(currGray[idx]) - Int(prev[idx]))
                        let brightness = Int(currGray[idx])

                        // Dark (< 80) AND significant motion (> 25)
                        guard diff > 25 && brightness < 80 else { continue }

                        // Within swing arc (circle around pivot, excluding body core)
                        let dx = x - pivotX
                        let dy = y - pivotY
                        let distPivot = Int(sqrt(Double(dx * dx + dy * dy)))
                        guard distPivot > Int(Double(h) * 0.06) &&
                              distPivot < Int(Double(h) * 0.45) else { continue }

                        // Left 65% of frame, not watermark
                        guard x < Int(Double(w) * 0.65) && y < Int(Double(h) * 0.93) else { continue }

                        if timeBins[timeBin] == nil { timeBins[timeBin] = [] }
                        timeBins[timeBin]?.append((x: x, y: y, motion: Float(diff)))
                    }
                }
            }

            prevGray = currGray
            t += sampleInterval
        }

        // Extract arc: for each time bin, find the tip (furthest from pivot with continuity)
        let sortedTimes = timeBins.keys.sorted()
        var detections: [ClubHeadDetection] = []
        var prevPos = (x: ballX, y: ballY)

        for binTime in sortedTimes {
            guard let pts = timeBins[binTime], pts.count >= 3 else { continue }

            var bestX = 0, bestY = 0, bestScore: Float = 0
            var count = 0

            for pt in pts {
                let dx = Float(pt.x - pivotX)
                let dy = Float(pt.y - pivotY)
                let distPivot = sqrt(dx * dx + dy * dy)

                let dpx = Float(pt.x - prevPos.x)
                let dpy = Float(pt.y - prevPos.y)
                let distPrev = sqrt(dpx * dpx + dpy * dpy)

                // Score: far from pivot + high motion + near previous
                var score = distPivot * 0.5 + pt.motion * 2.0
                if distPrev < 200 {
                    score += 50
                } else {
                    score *= 0.1
                }

                if score > bestScore {
                    bestScore = score
                    bestX += pt.x
                    bestY += pt.y
                    count += 1
                    if count > 5 { break } // take top candidates
                }
            }

            guard bestScore > 30, count > 0 else { continue }
            let tipX = bestX / count
            let tipY = bestY / count

            let distPivot = sqrt(Float((tipX - pivotX) * (tipX - pivotX) + (tipY - pivotY) * (tipY - pivotY)))
            guard distPivot > 50 else { continue }

            detections.append(ClubHeadDetection(
                position: CGPoint(x: CGFloat(tipX) / CGFloat(w),
                                  y: CGFloat(tipY) / CGFloat(h)),
                frameTime: binTime,
                phase: .address
            ))
            prevPos = (x: tipX, y: tipY)
        }

        // Phase classification
        guard detections.count >= 3 else { return detections }

        // Find top of swing (minimum y)
        let yValues = detections.map { $0.position.y }
        var smoothY = [CGFloat]()
        let window = 3
        for i in 0..<yValues.count {
            let s = max(0, i - window / 2)
            let e = min(yValues.count, i + window / 2 + 1)
            let avg = yValues[s..<e].reduce(0, +) / CGFloat(e - s)
            smoothY.append(avg)
        }
        let topIdx = smoothY.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0

        var classified: [ClubHeadDetection] = []
        for (i, det) in detections.enumerated() {
            let phase: SwingPhase
            if det.frameTime >= impactSeconds - 0.03 {
                phase = .postImpact
            } else if i < 2 {
                phase = .address
            } else if i <= topIdx {
                phase = .backswing
            } else {
                phase = .downswing
            }
            classified.append(ClubHeadDetection(
                position: det.position,
                frameTime: det.frameTime,
                phase: phase
            ))
        }

        return classified
    }

    // MARK: - Grayscale conversion

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
}
