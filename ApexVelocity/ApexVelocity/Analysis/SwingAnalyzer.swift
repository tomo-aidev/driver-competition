import AVFoundation
import CoreGraphics
import Vision

/// Detected club head position and phase
struct ClubHeadDetection {
    let position: CGPoint  // normalized 0-1, origin top-left
    let frameTime: Double  // seconds
    let phase: SwingPhase
}

enum SwingPhase {
    case address
    case backswing
    case downswing
    case postImpact
}

/// Analyzes golf swing by tracking the club head tip via body pose + frame differencing.
///
/// Uses VNDetectHumanBodyPose to find wrist positions, then searches for the
/// club head (dark, fast-moving object extending from wrists away from body).
struct SwingAnalyzer {

    static func analyzeSwing(
        from asset: AVAsset,
        impactTime: CMTime,
        ballPosition: CGPoint
    ) async throws -> [ClubHeadDetection] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: 540, height: 960)

        let impactSeconds = CMTimeGetSeconds(impactTime)

        // Sample from 2s before impact to 0.3s after
        let startTime = max(0, impactSeconds - 2.0)
        let endTime = impactSeconds + 0.3
        let sampleInterval = 0.05  // 20fps sampling

        var detections: [ClubHeadDetection] = []
        var prevImage: CGImage?
        var prevWrist: CGPoint?

        var t = startTime
        while t < endTime {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var actualTime = CMTime.zero
            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                t += sampleInterval
                continue
            }

            let w = image.width
            let h = image.height

            // 1. Get wrist position from body pose
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let poseRequest = VNDetectHumanBodyPoseRequest()
            try? handler.perform([poseRequest])

            var wristPos: CGPoint?
            var hipPos: CGPoint?

            if let body = poseRequest.results?.first {
                let rw = try? body.recognizedPoint(.rightWrist)
                let lw = try? body.recognizedPoint(.leftWrist)

                if let rw = rw, rw.confidence > 0.2, let lw = lw, lw.confidence > 0.2 {
                    // Vision coords: bottom-left → convert to top-left
                    let avgX = (rw.location.x + lw.location.x) / 2
                    let avgY = 1.0 - (rw.location.y + lw.location.y) / 2
                    wristPos = CGPoint(x: avgX, y: avgY)
                }

                let rh = try? body.recognizedPoint(.rightHip)
                let lh = try? body.recognizedPoint(.leftHip)
                if let rh = rh, rh.confidence > 0.2, let lh = lh, lh.confidence > 0.2 {
                    let avgX = (rh.location.x + lh.location.x) / 2
                    let avgY = 1.0 - (rh.location.y + lh.location.y) / 2
                    hipPos = CGPoint(x: avgX, y: avgY)
                }
            }

            // 2. Find club head: search along wrist→away-from-hip direction
            if let wrist = wristPos, let hip = hipPos, let prev = prevImage {
                let clubHead = findClubHead(
                    currentImage: image, prevImage: prev,
                    wrist: wrist, hip: hip,
                    width: w, height: h
                )

                if let ch = clubHead {
                    detections.append(ClubHeadDetection(
                        position: ch,
                        frameTime: t,
                        phase: .address // classified later
                    ))
                }
            } else if let wrist = wristPos {
                // No hip or no prev frame → use wrist as rough proxy
                // Extend slightly from wrist
                let extendY = min(1.0, wrist.y + 0.05)
                detections.append(ClubHeadDetection(
                    position: CGPoint(x: wrist.x, y: extendY),
                    frameTime: t,
                    phase: .address
                ))
            }

            prevImage = image
            prevWrist = wristPos
            t += sampleInterval
        }

        // 3. Phase classification
        guard detections.count >= 3 else { return detections }

        // Find top of swing (minimum y = highest point on screen)
        let yValues = detections.map { $0.position.y }
        let topIdx = yValues.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0

        var classified: [ClubHeadDetection] = []
        for (i, det) in detections.enumerated() {
            let phase: SwingPhase
            if det.frameTime >= impactSeconds - 0.02 {
                phase = .postImpact
            } else if i <= 1 {
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

        print("[Swing] \(classified.count) detections: \(classified.filter { $0.phase == .backswing }.count) back, \(classified.filter { $0.phase == .downswing }.count) down")
        return classified
    }

    // MARK: - Club Head Detection

    /// Find the club head tip using frame differencing + wrist direction.
    /// The club extends from the wrists AWAY from the hips.
    private static func findClubHead(
        currentImage: CGImage, prevImage: CGImage,
        wrist: CGPoint, hip: CGPoint,
        width: Int, height: Int
    ) -> CGPoint? {
        // Direction from hip to wrist (club extends further in this direction)
        let dirX = wrist.x - hip.x
        let dirY = wrist.y - hip.y
        let dirLen = sqrt(dirX * dirX + dirY * dirY)
        guard dirLen > 0.01 else { return nil }
        let normDirX = dirX / dirLen
        let normDirY = dirY / dirLen

        // Get grayscale pixels for both frames
        guard let currGray = grayscalePixels(from: currentImage, width: width, height: height),
              let prevGray = grayscalePixels(from: prevImage, width: width, height: height) else {
            return nil
        }

        // Search along the wrist→extension direction for motion
        let wristPx = Int(wrist.x * CGFloat(width))
        let wristPy = Int(wrist.y * CGFloat(height))

        var bestX = wristPx
        var bestY = wristPy
        var bestScore: Double = 0

        // Search in a fan pattern from wrist position
        let searchLen = Int(Double(min(width, height)) * 0.25)

        for angleOffset in stride(from: -30.0, through: 30.0, by: 5.0) {
            let angleRad = angleOffset * .pi / 180.0
            let cosA = Foundation.cos(angleRad)
            let sinA = Foundation.sin(angleRad)

            // Rotate direction
            let searchDirX = Double(normDirX) * cosA - Double(normDirY) * sinA
            let searchDirY = Double(normDirX) * sinA + Double(normDirY) * cosA

            for step in stride(from: 20, to: searchLen, by: 3) {
                let px = wristPx + Int(searchDirX * Double(step))
                let py = wristPy + Int(searchDirY * Double(step))

                guard px >= 1, px < width - 1, py >= 1, py < height - 1 else { break }

                let idx = py * width + px

                // Motion (frame diff)
                let motion = abs(Int(currGray[idx]) - Int(prevGray[idx]))
                guard motion > 15 else { continue }

                // Darkness bonus (club shaft/head is dark)
                let darkness = max(0, 100 - Int(currGray[idx]))

                // Distance from wrist (further = more likely club head, not hands)
                let dist = Double(step)

                let score = Double(motion) * 2.0 + Double(darkness) * 0.5 + dist * 0.3

                if score > bestScore {
                    bestScore = score
                    bestX = px
                    bestY = py
                }
            }
        }

        guard bestScore > 30 else { return nil }

        return CGPoint(
            x: CGFloat(bestX) / CGFloat(width),
            y: CGFloat(bestY) / CGFloat(height)
        )
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
