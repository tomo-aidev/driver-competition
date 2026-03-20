import AVFoundation
import Combine

/// Ball detection result
struct BallLocationResult {
    let position: CGPoint       // normalized 0-1
    let confidence: Float
}

/// Orchestrates video analysis while video plays
@MainActor
final class VideoAnalyzer: ObservableObject {

    @Published var ballLocation: BallLocationResult?
    @Published var impactTime: Double?
    @Published var ballDetected = false
    @Published var impactDetected = false
    @Published var showImpactFlash = false
    @Published var statusMessage: String = ""
    @Published var swingDetections: [ClubHeadDetection] = []
    @Published var swingAnalyzed = false

    private var analysisTask: Task<Void, Never>?
    private var impactSyncTask: Task<Void, Never>?
    weak var player: AVPlayer?

    /// Run analysis: detect ball first, then find impact and sync with playback
    func analyze(videoURL: URL, player: AVPlayer) {
        reset()
        self.player = player

        analysisTask = Task {
            let asset = AVURLAsset(url: videoURL)

            // Stage 1: Find the golf ball
            statusMessage = String(localized: "detecting_ball", defaultValue: "Detecting golf ball...")
            do {
                let result = try await findGolfBall(asset: asset)
                if let result {
                    ballLocation = result
                    ballDetected = true
                    statusMessage = String(localized: "ball_found_title", defaultValue: "Golf ball detected!")
                    print("[Analyzer] Ball at (\(String(format: "%.2f", result.position.x)), \(String(format: "%.2f", result.position.y)))")
                } else {
                    statusMessage = String(localized: "ball_not_found_title", defaultValue: "Golf ball not found")
                    return
                }
            } catch {
                statusMessage = String(localized: "ball_not_found_title", defaultValue: "Golf ball not found")
                return
            }

            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }

            // Stage 2: Detect impact sound (background)
            statusMessage = String(localized: "detecting_impact", defaultValue: "Detecting impact sound...")
            do {
                let time = try await ImpactDetector.detectImpact(from: asset)
                if let time {
                    let seconds = CMTimeGetSeconds(time)
                    impactTime = seconds
                    impactDetected = true
                    print("[Analyzer] Impact at \(String(format: "%.2f", seconds))s")

                    // Wait for video playback to reach impact time, then show flash
                    statusMessage = String(localized: "waiting_impact", defaultValue: "Waiting for impact moment...")
                    await waitForPlaybackTime(seconds: seconds, player: player)

                    showImpactFlash = true
                    statusMessage = String(format: String(localized: "impact_detected_at", defaultValue: "Impact! %.2fs"), seconds)

                    try? await Task.sleep(for: .seconds(3))
                    showImpactFlash = false

                    // Stage 3: Analyze swing trajectory
                    guard !Task.isCancelled else { return }
                    statusMessage = String(localized: "analyzing_swing", defaultValue: "Analyzing swing...")

                    do {
                        let detections = try await SwingAnalyzer.analyzeSwing(
                            from: asset,
                            impactTime: time,
                            ballPosition: ballLocation?.position ?? CGPoint(x: 0.5, y: 0.8)
                        )
                        swingDetections = detections
                        swingAnalyzed = true
                        let backCount = detections.filter { $0.phase == .backswing }.count
                        let downCount = detections.filter { $0.phase == .downswing }.count
                        statusMessage = String(localized: "swing_analyzed", defaultValue: "Swing analyzed")
                        print("[Analyzer] Swing: \(backCount) backswing, \(downCount) downswing frames")
                    } catch {
                        print("[Analyzer] Swing analysis error: \(error)")
                    }
                } else {
                    statusMessage = String(localized: "impact_not_found_title", defaultValue: "Impact not detected")
                }
            } catch {
                statusMessage = String(localized: "impact_not_found_title", defaultValue: "Impact not detected")
            }
        }
    }

    func reset() {
        analysisTask?.cancel()
        impactSyncTask?.cancel()
        analysisTask = nil
        impactSyncTask = nil
        player = nil
        ballLocation = nil
        impactTime = nil
        ballDetected = false
        impactDetected = false
        showImpactFlash = false
        statusMessage = ""
        swingDetections = []
        swingAnalyzed = false
    }

    // MARK: - Wait for Playback to Reach Time

    private func waitForPlaybackTime(seconds: Double, player: AVPlayer) async {
        // Poll playback time until it reaches the impact moment
        while !Task.isCancelled {
            let currentTime = CMTimeGetSeconds(player.currentTime())
            if currentTime >= seconds - 0.1 {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Ball Detection

    private func findGolfBall(asset: AVAsset) async throws -> BallLocationResult? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Sample early frames (ball is stationary before swing)
        let sampleTimes: [Double] = [0.3, 0.5, 1.0, 1.5, 2.0]

        for time in sampleTimes {
            try Task.checkCancellation()

            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            var actualTime = CMTime.zero
            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                continue
            }

            if let pos = detectBallInBottomCenter(in: image) {
                return BallLocationResult(position: pos, confidence: 0.8)
            }
        }
        return nil
    }

    /// Detect golf ball specifically in the bottom-center area of the frame.
    /// The ball is small, white/bright, on green/brown grass, near the driver head.
    private func detectBallInBottomCenter(in image: CGImage) -> CGPoint? {
        let width = image.width
        let height = image.height

        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        let dataLength = CFDataGetLength(data)

        // STRICT search area: bottom 25% of frame, center 40% of width
        // This is where the golf ball sits on the tee
        let searchStartY = height * 70 / 100
        let searchEndY = height * 92 / 100  // avoid watermark at very bottom
        let searchStartX = width * 30 / 100
        let searchEndX = width * 70 / 100

        // Collect ALL white-ish candidates in the search area
        struct Candidate {
            var x: Int
            var y: Int
            var brightness: Int
            var clusterSize: Int
            var surroundDarkness: Int // lower = darker surrounding = better contrast
        }

        var candidates: [Candidate] = []
        let step = 3

        for y in stride(from: searchStartY, to: searchEndY, by: step) {
            for x in stride(from: searchStartX, to: searchEndX, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < dataLength else { continue }

                let r = Int(ptr[offset])
                let g = Int(ptr[offset + 1])
                let b = Int(ptr[offset + 2])
                let brightness = (r + g + b) / 3
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let saturation = maxC - minC

                // Golf ball: bright (>160), can be white, yellow, pink, orange
                // White: high brightness, low saturation
                // Color balls: high brightness, moderate saturation but specific hues
                let isWhiteBall = brightness > 170 && saturation < 50
                let isYellowBall = r > 180 && g > 170 && b < 140 && brightness > 160
                let isPinkBall = r > 180 && g < 140 && b > 130 && brightness > 150
                let isOrangeBall = r > 190 && g > 130 && g < 180 && b < 100 && brightness > 150

                guard isWhiteBall || isYellowBall || isPinkBall || isOrangeBall else { continue }

                // Measure cluster size and circularity
                let (cluster, circularity) = measureClusterAndCircularity(
                    ptr: ptr, cx: x, cy: y,
                    width: width, height: height,
                    bytesPerRow: bytesPerRow,
                    bytesPerPixel: bytesPerPixel,
                    dataLength: dataLength,
                    brightness: brightness, saturation: saturation
                )

                // Golf ball: small spherical cluster (2-25px), reasonably circular (>0.5)
                guard cluster >= 2 && cluster <= 25 && circularity > 0.4 else { continue }

                // Measure surrounding darkness (ball should contrast with grass)
                let surround = measureSurround(ptr: ptr, cx: x, cy: y,
                                                width: width, height: height,
                                                bytesPerRow: bytesPerRow,
                                                bytesPerPixel: bytesPerPixel,
                                                dataLength: dataLength,
                                                radius: 25)

                // Surrounding should be darker than the ball (grass)
                guard surround < 150 else { continue }

                candidates.append(Candidate(
                    x: x, y: y,
                    brightness: brightness,
                    clusterSize: cluster,
                    surroundDarkness: surround
                ))
            }
        }

        guard !candidates.isEmpty else { return nil }

        // Score candidates: prefer high brightness, good cluster size, dark surroundings
        let best = candidates.max(by: { a, b in
            let scoreA = a.brightness - a.surroundDarkness + a.clusterSize * 5
            let scoreB = b.brightness - b.surroundDarkness + b.clusterSize * 5
            return scoreA < scoreB
        })

        guard let best else { return nil }

        return CGPoint(
            x: CGFloat(best.x) / CGFloat(width),
            y: CGFloat(best.y) / CGFloat(height)
        )
    }

    /// Measures cluster size AND circularity (1.0 = perfect circle, 0.0 = line)
    private func measureClusterAndCircularity(
        ptr: UnsafePointer<UInt8>, cx: Int, cy: Int,
        width: Int, height: Int,
        bytesPerRow: Int, bytesPerPixel: Int,
        dataLength: Int,
        brightness: Int, saturation: Int
    ) -> (size: Int, circularity: CGFloat) {
        var count = 0
        var minX = cx, maxX = cx, minY = cy, maxY = cy
        let radius = 15

        for dy in stride(from: -radius, through: radius, by: 2) {
            for dx in stride(from: -radius, through: radius, by: 2) {
                let px = cx + dx, py = cy + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let offset = py * bytesPerRow + px * bytesPerPixel
                guard offset + 2 < dataLength else { continue }
                let r = Int(ptr[offset]), g = Int(ptr[offset+1]), b = Int(ptr[offset+2])
                let br = (r + g + b) / 3
                // Match similar brightness/color as center pixel
                if br > 160 {
                    count += 1
                    minX = min(minX, px)
                    maxX = max(maxX, px)
                    minY = min(minY, py)
                    maxY = max(maxY, py)
                }
            }
        }

        guard count >= 2 else { return (count, 0) }

        // Circularity: ratio of shorter to longer axis of bounding box
        let bboxW = CGFloat(maxX - minX + 1)
        let bboxH = CGFloat(maxY - minY + 1)
        let shorter = min(bboxW, bboxH)
        let longer = max(bboxW, bboxH)
        let circularity = longer > 0 ? shorter / longer : 0

        return (count, circularity)
    }

    private func measureSurround(ptr: UnsafePointer<UInt8>, cx: Int, cy: Int,
                                   width: Int, height: Int,
                                   bytesPerRow: Int, bytesPerPixel: Int,
                                   dataLength: Int, radius: Int) -> Int {
        var total = 0, count = 0
        for dy in stride(from: -radius, through: radius, by: 3) {
            for dx in stride(from: -radius, through: radius, by: 3) {
                let dist = abs(dx) + abs(dy)
                guard dist >= radius / 2 else { continue } // skip inner area (ball itself)
                let px = cx + dx, py = cy + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let offset = py * bytesPerRow + px * bytesPerPixel
                guard offset + 2 < dataLength else { continue }
                total += (Int(ptr[offset]) + Int(ptr[offset+1]) + Int(ptr[offset+2])) / 3
                count += 1
            }
        }
        return count > 0 ? total / count : 255
    }
}
