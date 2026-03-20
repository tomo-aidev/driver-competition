import AVFoundation
import CoreGraphics

/// Detected club head position and phase
struct ClubHeadDetection {
    let position: CGPoint  // normalized 0-1
    let frameTime: Double  // seconds
    let phase: SwingPhase
}

enum SwingPhase {
    case address    // club near ball, before swing
    case backswing  // club moving up (blue)
    case downswing  // club moving down toward ball (green)
    case postImpact // after ball is hit
}

/// Analyzes golf swing by tracking the club head through frames.
/// Detects backswing (up) and downswing (down) phases.
struct SwingAnalyzer {

    /// Analyze swing trajectory from video frames around the impact time.
    /// Returns club head positions with swing phase classification.
    static func analyzeSwing(
        from asset: AVAsset,
        impactTime: CMTime,
        ballPosition: CGPoint // normalized
    ) async throws -> [ClubHeadDetection] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)

        let impactSeconds = CMTimeGetSeconds(impactTime)

        // Extract frames: 3 seconds before impact to 1 second after
        let startTime = max(0, impactSeconds - 3.0)
        let endTime = impactSeconds + 1.0
        let frameInterval = 0.1 // 10fps sampling

        var detections: [ClubHeadDetection] = []
        var prevHeadPos: CGPoint?
        var reachedTop = false

        var time = startTime
        while time <= endTime {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            var actualTime = CMTime.zero

            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                time += frameInterval
                continue
            }

            let currentSeconds = CMTimeGetSeconds(actualTime)

            // Detect club head (dark object near/around ball area or moving above)
            if let headPos = detectClubHead(in: image, ballPosition: ballPosition, previousHead: prevHeadPos) {

                // Determine swing phase
                let phase: SwingPhase
                if currentSeconds >= impactSeconds {
                    phase = .postImpact
                } else if let prev = prevHeadPos {
                    // Head moving up = backswing, moving down = downswing
                    if headPos.y < prev.y {
                        // Moving up on screen = backswing
                        reachedTop = true
                        phase = .backswing
                    } else if reachedTop {
                        phase = .downswing
                    } else {
                        // Still going up or at address
                        let distFromBall = hypot(headPos.x - ballPosition.x, headPos.y - ballPosition.y)
                        phase = distFromBall < 0.1 ? .address : .backswing
                    }
                } else {
                    phase = .address
                }

                detections.append(ClubHeadDetection(
                    position: headPos,
                    frameTime: currentSeconds,
                    phase: phase
                ))
                prevHeadPos = headPos
            }

            time += frameInterval
        }

        // Post-process: fix phase classification
        // Find the highest point (smallest y) = transition from backswing to downswing
        if let topIdx = detections.enumerated().min(by: { $0.element.position.y < $1.element.position.y })?.offset {
            var corrected: [ClubHeadDetection] = []
            for (i, det) in detections.enumerated() {
                let phase: SwingPhase
                if det.frameTime >= impactSeconds {
                    phase = .postImpact
                } else if i <= topIdx {
                    phase = i < 2 ? .address : .backswing
                } else {
                    phase = .downswing
                }
                corrected.append(ClubHeadDetection(
                    position: det.position,
                    frameTime: det.frameTime,
                    phase: phase
                ))
            }
            return corrected
        }

        return detections
    }

    // MARK: - Club Head Detection

    /// Detect the club head (dark, compact object) in a frame.
    /// Club head is typically the darkest compact object near the ball or in the swing arc.
    private static func detectClubHead(
        in image: CGImage,
        ballPosition: CGPoint,
        previousHead: CGPoint?
    ) -> CGPoint? {
        let width = image.width
        let height = image.height

        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        let dataLength = CFDataGetLength(data)

        // Search area: around the ball position, expanding for backswing
        // Club head moves from ball level up to above the golfer's head
        let ballX = Int(ballPosition.x * CGFloat(width))
        let ballY = Int(ballPosition.y * CGFloat(height))

        let searchLeft: Int
        let searchRight: Int
        let searchTop: Int
        let searchBottom: Int

        if let prev = previousHead {
            // Search around previous position (club head doesn't jump far between frames)
            let px = Int(prev.x * CGFloat(width))
            let py = Int(prev.y * CGFloat(height))
            let searchRadius = width / 4
            searchLeft = max(0, px - searchRadius)
            searchRight = min(width, px + searchRadius)
            searchTop = max(0, py - searchRadius)
            searchBottom = min(height, py + searchRadius)
        } else {
            // Initial: search around ball position (club head is near ball at address)
            let searchRadius = width / 5
            searchLeft = max(0, ballX - searchRadius)
            searchRight = min(width, ballX + searchRadius)
            searchTop = max(0, ballY - height / 2)
            searchBottom = min(height, ballY + searchRadius / 2)
        }

        // Find darkest compact cluster (club head is dark/black)
        var bestX = 0
        var bestY = 0
        var bestDarkness = 255
        let step = 4

        for y in stride(from: searchTop, to: searchBottom, by: step) {
            for x in stride(from: searchLeft, to: searchRight, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < dataLength else { continue }

                let r = Int(ptr[offset])
                let g = Int(ptr[offset + 1])
                let b = Int(ptr[offset + 2])
                let brightness = (r + g + b) / 3

                // Club head: very dark (<60) compact object
                guard brightness < 60 else { continue }

                // Measure dark cluster
                let cluster = measureDarkCluster(
                    ptr: ptr, cx: x, cy: y,
                    width: width, height: height,
                    bytesPerRow: bytesPerRow,
                    bytesPerPixel: bytesPerPixel,
                    dataLength: dataLength
                )

                // Club head size: roughly 10-50px cluster
                guard cluster >= 5 && cluster <= 40 else { continue }

                // Check surrounding is lighter (contrast)
                let surround = measureSurroundBrightness(
                    ptr: ptr, cx: x, cy: y,
                    width: width, height: height,
                    bytesPerRow: bytesPerRow,
                    bytesPerPixel: bytesPerPixel,
                    dataLength: dataLength
                )

                if surround > brightness + 30 && brightness < bestDarkness {
                    bestDarkness = brightness
                    bestX = x
                    bestY = y
                }
            }
        }

        guard bestDarkness < 60 else { return nil }

        return CGPoint(
            x: CGFloat(bestX) / CGFloat(width),
            y: CGFloat(bestY) / CGFloat(height)
        )
    }

    private static func measureDarkCluster(
        ptr: UnsafePointer<UInt8>, cx: Int, cy: Int,
        width: Int, height: Int,
        bytesPerRow: Int, bytesPerPixel: Int,
        dataLength: Int
    ) -> Int {
        var count = 0
        let radius = 15
        for dy in stride(from: -radius, through: radius, by: 3) {
            for dx in stride(from: -radius, through: radius, by: 3) {
                let px = cx + dx, py = cy + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let offset = py * bytesPerRow + px * bytesPerPixel
                guard offset + 2 < dataLength else { continue }
                let brightness = (Int(ptr[offset]) + Int(ptr[offset+1]) + Int(ptr[offset+2])) / 3
                if brightness < 60 { count += 1 }
            }
        }
        return count
    }

    private static func measureSurroundBrightness(
        ptr: UnsafePointer<UInt8>, cx: Int, cy: Int,
        width: Int, height: Int,
        bytesPerRow: Int, bytesPerPixel: Int,
        dataLength: Int
    ) -> Int {
        var total = 0, count = 0
        let radius = 25
        for dy in stride(from: -radius, through: radius, by: 5) {
            for dx in stride(from: -radius, through: radius, by: 5) {
                guard abs(dx) + abs(dy) >= radius / 2 else { continue }
                let px = cx + dx, py = cy + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let offset = py * bytesPerRow + px * bytesPerPixel
                guard offset + 2 < dataLength else { continue }
                total += (Int(ptr[offset]) + Int(ptr[offset+1]) + Int(ptr[offset+2])) / 3
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }
}
