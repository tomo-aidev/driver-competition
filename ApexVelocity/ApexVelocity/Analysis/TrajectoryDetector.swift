import AVFoundation
import Vision
import CoreGraphics

/// Detects golf ball trajectory after impact using Apple Vision + motion blur analysis.
///
/// Pipeline:
/// 1. VNDetectTrajectoriesRequest — Apple's built-in parabolic trajectory detection
/// 2. Motion blur streak detection — direction & speed from blur in difference frames
/// 3. Physics extrapolation — complete trajectory when ball leaves frame
struct TrajectoryDetector {

    /// A single point on the detected trajectory
    struct TrajectoryPoint {
        let time: Double           // seconds from video start
        let position: CGPoint      // normalized 0-1, origin top-left
        let isDetected: Bool       // true = real detection, false = predicted/extrapolated
        let confidence: Float
    }

    /// Full trajectory result
    struct TrajectoryResult {
        let points: [TrajectoryPoint]
        let launchAngleDeg: Double   // degrees from horizontal (positive = upward)
        let launchDirection: Double  // degrees from center (positive = right)
        let estimatedSpeedMph: Double
        let apexHeight: CGFloat     // normalized Y of highest point
        let method: String
    }

    // MARK: - Detect Trajectory

    /// Detect ball trajectory in post-impact video segment.
    /// FPS-aware: skips VNDetectTrajectoriesRequest for ≤60fps video (wastes CPU).
    /// Uses hybrid approach for 30fps: motion blur → 2-point angle estimation → physics.
    static func detectTrajectory(
        in asset: AVAsset,
        impactTime: Double,
        ballPosition: CGPoint,  // normalized, origin top-left
        fps: Double = 30.0
    ) async -> TrajectoryResult? {

        // --- FPS detection ---
        let actualFPS: Double
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            let nominalFR = try? await videoTrack.load(.nominalFrameRate)
            actualFPS = Double(nominalFR ?? 30)
        } else {
            actualFPS = fps
        }

        print("[Trajectory] Video FPS: \(String(format: "%.0f", actualFPS))")

        // --- HIGH FPS (>60): Use VNDetectTrajectoriesRequest ---
        if actualFPS > 60 {
            print("[Trajectory] High FPS (\(Int(actualFPS))) → using VNDetectTrajectoriesRequest")
            let visionResult = await detectWithVision(
                asset: asset, impactTime: impactTime, ballPosition: ballPosition
            )
            if let vision = visionResult, vision.points.count >= 3 {
                return vision
            }
            // Fall through to hybrid if Vision fails even at high FPS
        } else {
            print("[Trajectory] Low FPS (\(Int(actualFPS))) → skipping VNDetectTrajectoriesRequest")
        }

        // --- 30fps HYBRID: Motion blur + 2-point angle → Physics ---
        // Step 1: Try motion blur to get launch angle
        let blurResult = await detectWithMotionBlur(
            asset: asset, impactTime: impactTime, ballPosition: ballPosition
        )

        if let blur = blurResult, blur.launchAngleDeg > 5 && blur.launchAngleDeg < 60 {
            print("[Trajectory] Blur → angle=\(String(format: "%.1f", blur.launchAngleDeg))° → physics trajectory")
            // Use detected angle with physics simulation
            let points = generatePhysicsTrajectory(
                ballPosition: ballPosition,
                impactTime: impactTime,
                launchAngleDeg: blur.launchAngleDeg,
                directionDeg: blur.launchDirection,
                headSpeedMs: 40.0
            )
            return TrajectoryResult(
                points: points,
                launchAngleDeg: blur.launchAngleDeg,
                launchDirection: blur.launchDirection,
                estimatedSpeedMph: blur.estimatedSpeedMph,
                apexHeight: points.map(\.position.y).min() ?? 0.2,
                method: "blur→physics"
            )
        }

        // Step 2: 2-point angle estimation from post-impact frames
        let twoPointAngle = await estimateLaunchAngleFromFrames(
            asset: asset, impactTime: impactTime, ballPosition: ballPosition
        )

        if let angle = twoPointAngle, angle > 5 && angle < 60 {
            print("[Trajectory] 2-point → angle=\(String(format: "%.1f", angle))° → physics trajectory")
            let points = generatePhysicsTrajectory(
                ballPosition: ballPosition,
                impactTime: impactTime,
                launchAngleDeg: angle,
                directionDeg: 0,
                headSpeedMs: 40.0
            )
            return TrajectoryResult(
                points: points,
                launchAngleDeg: angle,
                launchDirection: 0,
                estimatedSpeedMph: 90,
                apexHeight: points.map(\.position.y).min() ?? 0.2,
                method: "2pt→physics"
            )
        }

        // Step 3: Pure physics fallback (default 13° launch)
        print("[Trajectory] Pure physics fallback (13°)")
        return estimateFromPhysics(ballPosition: ballPosition, impactTime: impactTime)
    }

    // MARK: - 2-Point Launch Angle Estimation (30fps)

    /// Estimate launch angle by comparing impact frame and +1/+2 frames.
    /// Searches for bright motion artifact near ball position in post-impact frames.
    private static func estimateLaunchAngleFromFrames(
        asset: AVAsset,
        impactTime: Double,
        ballPosition: CGPoint
    ) async -> Double? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
        generator.maximumSize = CGSize(width: 720, height: 1280)

        // Get impact frame and +1, +2 frames
        var actualTime = CMTime.zero
        guard let impactImg = try? generator.copyCGImage(
            at: CMTime(seconds: impactTime, preferredTimescale: 600), actualTime: &actualTime
        ) else { return nil }

        let offsets = [0.033, 0.066, 0.1]  // +1, +2, +3 frames at 30fps
        var bestAngle: Double? = nil
        var bestScore: Double = 0

        let w = impactImg.width, h = impactImg.height
        guard let impactPixels = renderToPixelData(image: impactImg, width: w, height: h) else { return nil }
        let bytesPerRow = w * 4

        let ballPx = Int(ballPosition.x * CGFloat(w))
        let ballPy = Int(ballPosition.y * CGFloat(h))

        for offset in offsets {
            guard let afterImg = try? generator.copyCGImage(
                at: CMTime(seconds: impactTime + offset, preferredTimescale: 600), actualTime: &actualTime
            ) else { continue }

            guard let afterPixels = renderToPixelData(image: afterImg, width: w, height: h) else { continue }

            // Search for bright difference above and around ball
            let searchRadius = Int(CGFloat(min(w, h)) * 0.12)
            var maxDiffX = ballPx, maxDiffY = ballPy
            var maxDiffScore: Double = 0

            for y in stride(from: max(0, ballPy - searchRadius * 2), to: ballPy, by: 2) {
                for x in stride(from: max(0, ballPx - searchRadius), to: min(w, ballPx + searchRadius), by: 2) {
                    let off = y * bytesPerRow + x * 4
                    guard off + 2 < impactPixels.count else { continue }

                    let dr = abs(Double(afterPixels[off]) - Double(impactPixels[off]))
                    let dg = abs(Double(afterPixels[off+1]) - Double(impactPixels[off+1]))
                    let db = abs(Double(afterPixels[off+2]) - Double(impactPixels[off+2]))
                    let diff = (dr + dg + db) / 3.0

                    if diff > maxDiffScore && diff > 20 {
                        maxDiffScore = diff
                        maxDiffX = x
                        maxDiffY = y
                    }
                }
            }

            guard maxDiffScore > 20 else { continue }

            // Calculate angle from ball to bright spot
            let dx = Double(maxDiffX - ballPx)
            let dy = Double(ballPy - maxDiffY)  // invert Y (screen up = positive angle)
            guard abs(dx) > 3 || abs(dy) > 3 else { continue }

            let angle = atan2(dy, abs(dx)) * 180.0 / .pi

            if maxDiffScore > bestScore {
                bestScore = maxDiffScore
                bestAngle = angle
                print("[Trajectory] 2-point: offset=\(String(format: "%.3f", offset))s diff=(\(maxDiffX-ballPx),\(ballPy-maxDiffY)) score=\(String(format: "%.0f", maxDiffScore)) angle=\(String(format: "%.1f", angle))°")
            }
        }

        return bestAngle
    }

    // MARK: - Apple Vision Trajectory Detection

    private static func detectWithVision(
        asset: AVAsset,
        impactTime: Double,
        ballPosition: CGPoint
    ) async -> TrajectoryResult? {

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            print("[Trajectory] AVAssetReader error: \(error)")
            return nil
        }

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        reader.add(output)

        // Start reading from just before impact
        let startTime = CMTime(seconds: max(0, impactTime - 0.5), preferredTimescale: 600)
        let endTime = CMTime(seconds: impactTime + 1.5, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, end: endTime)

        guard reader.startReading() else {
            print("[Trajectory] Reader failed to start: \(reader.error?.localizedDescription ?? "unknown")")
            return nil
        }

        // Configure VNDetectTrajectoriesRequest
        var detectedPoints: [(time: Double, point: CGPoint, confidence: Float)] = []

        let request = VNDetectTrajectoriesRequest(
            frameAnalysisSpacing: .zero,
            trajectoryLength: 7
        ) { request, error in
            guard let results = request.results as? [VNTrajectoryObservation] else { return }

            for observation in results {
                // Use detected points (real ball positions)
                for point in observation.detectedPoints {
                    // Vision: origin bottom-left → convert to top-left
                    let converted = CGPoint(
                        x: point.x,
                        y: 1.0 - point.y
                    )
                    detectedPoints.append((
                        time: 0, // will be set from frame timing
                        point: converted,
                        confidence: observation.confidence
                    ))
                }

                // Also use projected points for trajectory completion
                for point in observation.projectedPoints {
                    let converted = CGPoint(
                        x: point.x,
                        y: 1.0 - point.y
                    )
                    detectedPoints.append((
                        time: 0,
                        point: converted,
                        confidence: observation.confidence * 0.7 // lower confidence for projected
                    ))
                }
            }
        }

        // Set size filter for golf ball (~0.5-2% of frame)
        request.objectMinimumNormalizedRadius = 0.003
        request.objectMaximumNormalizedRadius = 0.025

        // Process frames
        let handler = VNSequenceRequestHandler()
        var frameCount = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSeconds = CMTimeGetSeconds(presentationTime)

            // Only process post-impact frames
            guard timeSeconds >= impactTime - 0.1 else { continue }

            do {
                try handler.perform([request], on: pixelBuffer, orientation: .up)
            } catch {
                // Vision errors are common, continue
            }

            frameCount += 1
            if frameCount > 60 { break } // Max 2 seconds at 30fps
        }

        reader.cancelReading()

        guard !detectedPoints.isEmpty else {
            print("[Trajectory] Vision: no trajectory detected in \(frameCount) frames")
            return nil
        }

        // Convert to TrajectoryPoints
        let trajectoryPoints = detectedPoints.enumerated().map { idx, dp in
            TrajectoryPoint(
                time: impactTime + Double(idx) * (1.0 / 30.0),
                position: dp.point,
                isDetected: dp.confidence > 0.5,
                confidence: dp.confidence
            )
        }

        // Calculate launch angle from first few points
        let angle = calculateLaunchAngle(from: trajectoryPoints, ballPosition: ballPosition)
        let direction = calculateLaunchDirection(from: trajectoryPoints, ballPosition: ballPosition)

        return TrajectoryResult(
            points: trajectoryPoints,
            launchAngleDeg: angle,
            launchDirection: direction,
            estimatedSpeedMph: 150, // estimate
            apexHeight: trajectoryPoints.map(\.position.y).min() ?? 0.3,
            method: "vision"
        )
    }

    // MARK: - Motion Blur Detection

    private static func detectWithMotionBlur(
        asset: AVAsset,
        impactTime: Double,
        ballPosition: CGPoint
    ) async -> TrajectoryResult? {

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
        generator.maximumSize = CGSize(width: 720, height: 1280)

        // Get frame at impact and frame after impact
        let impactCMTime = CMTime(seconds: impactTime, preferredTimescale: 600)
        let afterCMTime = CMTime(seconds: impactTime + 0.033, preferredTimescale: 600)
        let after2CMTime = CMTime(seconds: impactTime + 0.066, preferredTimescale: 600)

        var actualTime = CMTime.zero
        guard let impactImage = try? generator.copyCGImage(at: impactCMTime, actualTime: &actualTime),
              let afterImage = try? generator.copyCGImage(at: afterCMTime, actualTime: &actualTime) else {
            return nil
        }

        let after2Image = try? generator.copyCGImage(at: after2CMTime, actualTime: &actualTime)

        // Compute frame difference
        let w = impactImage.width, h = impactImage.height
        guard let impactPixels = renderToPixelData(image: impactImage, width: w, height: h),
              let afterPixels = renderToPixelData(image: afterImage, width: w, height: h) else {
            return nil
        }

        let bytesPerRow = w * 4

        // Ball position in pixels
        let ballPx = Int(ballPosition.x * CGFloat(w))
        let ballPy = Int(ballPosition.y * CGFloat(h))

        // Search for motion blur streak in area above and around ball
        let searchRadius = Int(CGFloat(min(w, h)) * 0.15)
        let searchMinX = max(0, ballPx - searchRadius)
        let searchMaxX = min(w - 1, ballPx + searchRadius)
        let searchMinY = max(0, ballPy - searchRadius * 2)  // more upward
        let searchMaxY = min(h - 1, ballPy + searchRadius / 2)

        // Find brightest streak in difference image
        var bestStreakAngle: Double = -70  // default: upward
        var bestStreakLength: Double = 0
        var bestStreakScore: Double = 0
        var streakPoints: [CGPoint] = []

        // Accumulate difference values
        var diffMap = [[Double]](repeating: [Double](repeating: 0, count: w), count: h)

        for y in searchMinY...searchMaxY {
            for x in searchMinX...searchMaxX {
                let offset = y * bytesPerRow + x * 4
                guard offset + 2 < impactPixels.count else { continue }

                let dr = abs(Double(afterPixels[offset]) - Double(impactPixels[offset]))
                let dg = abs(Double(afterPixels[offset+1]) - Double(impactPixels[offset+1]))
                let db = abs(Double(afterPixels[offset+2]) - Double(impactPixels[offset+2]))
                let diff = (dr + dg + db) / 3.0

                if diff > 15 { // significant change
                    diffMap[y][x] = diff
                }
            }
        }

        // Hough-like line detection in difference map
        // Test angles from -30° to -90° (upward-left to upward-right)
        for angleDeg in stride(from: -90.0, to: -10.0, by: 5.0) {
            let angleRad = angleDeg * .pi / 180.0
            let dx = cos(angleRad)
            let dy = sin(angleRad)

            var totalScore: Double = 0
            var length: Double = 0
            var points: [CGPoint] = []

            for step in stride(from: 5.0, to: Double(searchRadius), by: 2.0) {
                let px = Int(Double(ballPx) + dx * step)
                let py = Int(Double(ballPy) + dy * step)

                guard px >= 0, px < w, py >= 0, py < h else { break }

                let val = diffMap[py][px]
                if val > 10 {
                    totalScore += val
                    length = step
                    points.append(CGPoint(
                        x: CGFloat(px) / CGFloat(w),
                        y: CGFloat(py) / CGFloat(h)
                    ))
                }
            }

            if totalScore > bestStreakScore && length > 10 {
                bestStreakScore = totalScore
                bestStreakAngle = angleDeg
                bestStreakLength = length
                streakPoints = points
            }
        }

        guard bestStreakScore > 50 else {
            print("[Trajectory] No motion blur streak detected (score=\(String(format: "%.0f", bestStreakScore)))")
            return nil
        }

        print("[Trajectory] Blur streak: angle=\(String(format: "%.0f", bestStreakAngle))° len=\(String(format: "%.0f", bestStreakLength))px score=\(String(format: "%.0f", bestStreakScore))")

        // Estimate launch angle (screen angle to real angle)
        // Screen Y is inverted: -90° on screen = straight up = 90° launch
        let launchAngle = -bestStreakAngle

        // Estimate speed from blur length (rough: longer blur = faster)
        let estimatedSpeed = min(200, max(80, bestStreakLength * 1.5))

        // Build trajectory from blur detection + physics
        var trajectoryPoints: [TrajectoryPoint] = []

        // Add the real blur points
        for (i, pt) in streakPoints.enumerated() {
            trajectoryPoints.append(TrajectoryPoint(
                time: impactTime + Double(i) * 0.01,
                position: pt,
                isDetected: true,
                confidence: Float(max(0.3, 0.9 - Double(i) * 0.1))
            ))
        }

        // Use physics trajectory from ball position with detected angle
        let physicsPoints = generatePhysicsTrajectory(
            ballPosition: ballPosition,
            impactTime: impactTime,
            launchAngleDeg: launchAngle,
            directionDeg: 0,
            headSpeedMs: 40.0
        )

        // Combine: detected streak points + physics
        let combined = trajectoryPoints + physicsPoints.filter { $0.time > (trajectoryPoints.last?.time ?? impactTime) }

        return TrajectoryResult(
            points: combined,
            launchAngleDeg: launchAngle,
            launchDirection: 0,
            estimatedSpeedMph: estimatedSpeed,
            apexHeight: combined.map(\.position.y).min() ?? 0.2,
            method: "blur+physics"
        )
    }

    // MARK: - Physics Estimation (same logic as TrajectoryTestView)

    private static func estimateFromPhysics(
        ballPosition: CGPoint,
        impactTime: Double
    ) -> TrajectoryResult {
        // Mid-handicap amateur: 13° launch, 40 m/s head speed, 230 yards
        let launchAngleDeg = 13.0
        let directionDeg = 0.0  // straight
        let headSpeedMs = 40.0

        let points = generatePhysicsTrajectory(
            ballPosition: ballPosition,
            impactTime: impactTime,
            launchAngleDeg: launchAngleDeg,
            directionDeg: directionDeg,
            headSpeedMs: headSpeedMs
        )

        return TrajectoryResult(
            points: points,
            launchAngleDeg: launchAngleDeg,
            launchDirection: directionDeg,
            estimatedSpeedMph: headSpeedMs * 2.237,
            apexHeight: points.map(\.position.y).min() ?? 0.2,
            method: "physics"
        )
    }

    /// Generate trajectory using same physics as TrajectoryTestView.
    /// Produces a dramatic, game-like arc with proper timing.
    static func generatePhysicsTrajectory(
        ballPosition: CGPoint,
        impactTime: Double,
        launchAngleDeg: Double,
        directionDeg: Double,
        headSpeedMs: Double
    ) -> [TrajectoryPoint] {

        let dirRad = directionDeg * .pi / 180.0
        let angleRad = launchAngleDeg * .pi / 180.0

        // Same parameters as TrajectoryTestView
        let speedNorm = headSpeedMs / 40.0
        let targetApexHeight = 0.60 * sin(angleRad) / sin(13 * .pi / 180) * speedNorm
        let vacuumHalfTime = 1.4 * speedNorm
        let ascentTime = vacuumHalfTime * 1.3
        let descentTime = vacuumHalfTime * 1.5
        let flightDuration = ascentTime + descentTime
        let halfTime = ascentTime

        let gravity = 2.0 * targetApexHeight / (halfTime * halfTime)
        let vy0 = -gravity * halfTime
        let vx = 0.12 * sin(dirRad) * speedNorm

        let positionDt = 0.005
        var rawPositions: [(x: Double, y: Double)] = []
        var t = 0.0
        var hasReachedApex = false

        while t < flightDuration + 0.5 {
            let x = Double(ballPosition.x) + vx * t
            let y = Double(ballPosition.y) + vy0 * t + 0.5 * gravity * t * t

            if !hasReachedApex && (vy0 + gravity * t) > 0 { hasReachedApex = true }

            if hasReachedApex && y >= Double(ballPosition.y) - 0.005 && t > 0.5 {
                rawPositions.append((x: clamp01(x), y: Double(ballPosition.y)))
                break
            }
            if x < -0.15 || x > 1.15 { break }

            rawPositions.append((x: clamp01(x), y: clamp01(y)))
            t += positionDt
        }

        guard rawPositions.count > 10 else { return [] }

        // Build trajectory points with velocity-based timing
        var points: [TrajectoryPoint] = []
        let totalPositions = rawPositions.count
        var cumulativeTime = 0.0

        for i in 0..<totalPositions {
            let physicsT = Double(i) * positionDt
            let vyNow = vy0 + gravity * physicsT
            let speed = sqrt(vx * vx + vyNow * vyNow)
            let initialSpeed = sqrt(vx * vx + vy0 * vy0)
            let dragFactor = 0.7 + 0.3 * exp(-physicsT * 0.8)
            let adjustedSpeed = max(0.15, speed * dragFactor)

            let animDt: Double
            if i == 0 {
                animDt = 0
            } else {
                let speedRatio = min(3.0, initialSpeed / adjustedSpeed)
                let baseDt = flightDuration / Double(totalPositions)
                animDt = baseDt * speedRatio
            }
            cumulativeTime += animDt

            points.append(TrajectoryPoint(
                time: impactTime + cumulativeTime,
                position: CGPoint(x: rawPositions[i].x, y: rawPositions[i].y),
                isDetected: cumulativeTime < 0.2,
                confidence: Float(max(0.2, 1.0 - cumulativeTime / (flightDuration + 0.5)))
            ))
        }

        // Normalize timing to flight duration
        if let lastTime = points.last?.time, lastTime > impactTime {
            let totalAnimTime = lastTime - impactTime
            if totalAnimTime > 0 {
                let scale = flightDuration / totalAnimTime
                points = points.map {
                    TrajectoryPoint(
                        time: impactTime + ($0.time - impactTime) * scale,
                        position: $0.position,
                        isDetected: $0.isDetected,
                        confidence: $0.confidence
                    )
                }
            }
        }

        return points
    }

    private static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

    // MARK: - Angle Calculation

    private static func calculateLaunchAngle(from points: [TrajectoryPoint], ballPosition: CGPoint) -> Double {
        guard points.count >= 2 else { return 15 }
        let first = points[0].position
        let second = points[min(2, points.count - 1)].position
        let dy = second.y - first.y  // negative = upward
        let dx = hypot(second.x - first.x, 0)
        guard dx > 0.001 else { return 15 }
        return abs(atan2(Double(-dy), Double(dx)) * 180.0 / Double.pi)
    }

    private static func calculateLaunchDirection(from points: [TrajectoryPoint], ballPosition: CGPoint) -> Double {
        guard points.count >= 2 else { return 0 }
        let dx = points[1].position.x - ballPosition.x
        return dx > 0 ? 5 : -5  // rough left/right
    }

    // MARK: - Helpers

    private static func renderToPixelData(image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixelData,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelData
    }
}
