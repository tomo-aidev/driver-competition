import AVFoundation
import Combine
import Vision

/// Ball detection result
struct BallLocationResult {
    let position: CGPoint       // normalized 0-1
    let confidence: Float
    var method: String = ""
}

/// Orchestrates video analysis: ball detection → impact → swing → frame tracking.
/// Produces a timeline of ball positions. Playback sync is the View's job.
@MainActor
final class VideoAnalyzer: ObservableObject {

    /// Known ball position from recording target frame (normalized 0-1)
    var knownBallPosition: CGPoint?

    // MARK: - Analysis Results

    @Published var ballLocation: BallLocationResult?
    @Published var impactTime: Double?
    @Published var ballDetected = false
    @Published var impactDetected = false
    @Published var swingDetections: [ClubHeadDetection] = []
    @Published var swingAnalyzed = false

    /// Frame-by-frame ball positions: the KEY data for playback sync
    @Published var ballTimeline: [BallFinder.FrameBallPosition] = []
    @Published var ballTimelineReady = false

    /// Trajectory detection result (post-impact ball flight)
    @Published var trajectoryResult: TrajectoryDetector.TrajectoryResult?
    @Published var trajectoryDetected = false

    // MARK: - Analysis State

    @Published var statusMessage: String = ""
    @Published var isAnalyzing = false

    // Debug
    @Published var debugMethod: String = ""

    private var analysisTask: Task<Void, Never>?

    // MARK: - Analyze

    func analyze(videoURL: URL, completion: @escaping () -> Void) {
        reset()
        isAnalyzing = true

        analysisTask = Task {
            let asset = AVURLAsset(url: videoURL)

            // Stage 1: Collect audio impact candidates
            statusMessage = String(localized: "detecting_impact", defaultValue: "Detecting impact sound...")
            var audioCandidates: [(time: Double, energy: Float, ratio: Float)] = []
            do {
                audioCandidates = try await ImpactDetector.detectAllCandidates(from: asset)
                guard !Task.isCancelled else { return }
            } catch {
                print("[Analyzer] Audio analysis error: \(error)")
            }

            try? await Task.sleep(for: .seconds(0.2))
            guard !Task.isCancelled else { return }

            // Stage 2: Quick swing analysis to find downswing timing
            statusMessage = String(localized: "analyzing_swing", defaultValue: "Analyzing swing motion...")
            let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 30, preferredTimescale: 600)
            let totalSeconds = CMTimeGetSeconds(duration)

            // Find when the golfer swings: look for body pose wrist velocity peak
            var swingDownTime: Double? = nil
            do {
                // Analyze body pose across frames to find wrist drop
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
                generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
                generator.maximumSize = CGSize(width: 360, height: 640)  // low res for speed

                var wristYHistory: [(time: Double, y: CGFloat)] = []

                for t in stride(from: 0.5, to: min(totalSeconds, 15.0), by: 0.2) {
                    let cmTime = CMTime(seconds: t, preferredTimescale: 600)
                    var actualTime = CMTime.zero
                    guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else { continue }

                    // Quick body pose check
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    let poseRequest = VNDetectHumanBodyPoseRequest()
                    try? handler.perform([poseRequest])

                    if let body = poseRequest.results?.first {
                        let rw = try? body.recognizedPoint(.rightWrist)
                        let lw = try? body.recognizedPoint(.leftWrist)
                        if let rw = rw, rw.confidence > 0.2,
                           let lw = lw, lw.confidence > 0.2 {
                            let avgY = (rw.location.y + lw.location.y) / 2  // Vision: bottom-left origin
                            wristYHistory.append((time: t, y: avgY))
                        }
                    }
                }

                // Find the moment wrists drop fastest (backswing top → impact)
                // In Vision coords: Y decreases = wrist goes down = downswing
                var maxDrop: CGFloat = 0
                for i in 1..<wristYHistory.count {
                    let dy = wristYHistory[i-1].y - wristYHistory[i].y  // positive = dropping
                    if dy > maxDrop {
                        maxDrop = dy
                        swingDownTime = wristYHistory[i].time
                    }
                }

                if let sdt = swingDownTime {
                    print("[Analyzer] Swing down detected at \(String(format: "%.2f", sdt))s (wrist drop=\(String(format: "%.3f", maxDrop)))")
                }
            }

            try? await Task.sleep(for: .seconds(0.2))
            guard !Task.isCancelled else { return }

            // Stage 3: Combine audio + visual to find true impact
            if !audioCandidates.isEmpty {
                let selectedTime: Double

                if let swingDown = swingDownTime {
                    // Pick audio candidate closest to swing-down time (within ±0.5s)
                    let nearby = audioCandidates.filter { abs($0.time - swingDown) < 0.5 }
                    if let best = nearby.max(by: { $0.energy < $1.energy }) {
                        selectedTime = best.time
                        print("[Analyzer] Impact: audio(\(String(format: "%.3f", best.time))s) matched swing(\(String(format: "%.2f", swingDown))s)")
                    } else {
                        // No audio near swing → take highest energy candidate near swing
                        let closest = audioCandidates.min(by: { abs($0.time - swingDown) < abs($1.time - swingDown) })!
                        selectedTime = closest.time
                        print("[Analyzer] Impact: closest audio(\(String(format: "%.3f", closest.time))s) to swing(\(String(format: "%.2f", swingDown))s)")
                    }
                } else {
                    // No swing detected → take the highest energy audio candidate
                    let best = audioCandidates.max(by: { $0.energy < $1.energy })!
                    selectedTime = best.time
                    print("[Analyzer] Impact: highest energy audio at \(String(format: "%.3f", best.time))s (no swing data)")
                }

                impactTime = selectedTime
                impactDetected = true
                statusMessage = String(format: String(localized: "impact_detected_at", defaultValue: "Impact! %.2fs"), selectedTime)
            } else {
                statusMessage = String(localized: "impact_not_found_title", defaultValue: "Impact not detected")
            }

            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }

            // Stage 4: Ball detection
            statusMessage = String(localized: "detecting_ball", defaultValue: "Detecting golf ball...")

            if let known = knownBallPosition {
                // Use known position from recording target frame
                ballLocation = BallLocationResult(
                    position: known,
                    confidence: 1.0,
                    method: "target_frame"
                )
                ballDetected = true
                debugMethod = "target_frame"
                statusMessage = String(localized: "ball_found_title", defaultValue: "Golf ball detected!")
                print("[Analyzer] Using known ball position from target frame: (\(String(format: "%.3f", known.x)), \(String(format: "%.3f", known.y)))")
            } else {
                // AI detection fallback
                let ballResult = await BallFinder.find(in: asset, impactTime: impactTime)
                guard !Task.isCancelled else { return }
                if let ballResult {
                    ballLocation = BallLocationResult(
                        position: ballResult.position,
                        confidence: ballResult.confidence,
                        method: ballResult.method
                    )
                    ballDetected = true
                    debugMethod = ballResult.method
                    statusMessage = String(localized: "ball_found_title", defaultValue: "Golf ball detected!")
                } else {
                    statusMessage = String(localized: "ball_not_found_title", defaultValue: "Golf ball not found")
                }
            }

            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }

            // Stage 5: Full swing trajectory
            statusMessage = String(localized: "analyzing_swing", defaultValue: "Analyzing swing trajectory...")
            if let impactTime {
                let cmTime = CMTime(seconds: impactTime, preferredTimescale: 600)
                do {
                    let detections = try await SwingAnalyzer.analyzeSwing(
                        from: asset, impactTime: cmTime,
                        ballPosition: ballLocation?.position ?? CGPoint(x: 0.5, y: 0.8)
                    )
                    guard !Task.isCancelled else { return }
                    swingDetections = detections
                    swingAnalyzed = true
                } catch {
                    print("[Analyzer] Swing error: \(error)")
                }
            }

            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }

            // Stage 4: Build ball timeline (frame-by-frame)
            if ballDetected, let loc = ballLocation {
                statusMessage = String(localized: "tracking_ball", defaultValue: "Building ball timeline...")
                let timeline = await BallFinder.trackBallAcrossFrames(
                    in: asset,
                    initialBallPosition: loc.position,
                    impactTime: impactTime,
                    frameInterval: 0.1
                )
                guard !Task.isCancelled else { return }
                ballTimeline = timeline
                ballTimelineReady = true
                statusMessage = String(format: String(localized: "tracking_complete", defaultValue: "Ball tracked: %d frames"), timeline.count)
                print("[Analyzer] Timeline: \(timeline.count) entries")
            }

            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }

            // Stage 5: Trajectory detection (post-impact ball flight)
            if let impactTime, let loc = ballLocation {
                statusMessage = String(localized: "detecting_trajectory", defaultValue: "Detecting ball trajectory...")
                let trajectory = await TrajectoryDetector.detectTrajectory(
                    in: asset,
                    impactTime: impactTime,
                    ballPosition: loc.position
                )
                guard !Task.isCancelled else { return }
                if let trajectory {
                    trajectoryResult = trajectory
                    trajectoryDetected = true
                    statusMessage = String(format: "Trajectory: %d pts (%@)", trajectory.points.count, trajectory.method)
                    print("[Analyzer] Trajectory: \(trajectory.points.count) pts, method=\(trajectory.method), angle=\(String(format: "%.1f", trajectory.launchAngleDeg))°")
                }
            }

            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }

            statusMessage = String(localized: "analysis_complete", defaultValue: "Analysis complete")
            isAnalyzing = false
            completion()
        }
    }

    /// Look up ball position for a given playback time.
    /// Returns nil if ball shouldn't be shown (low confidence or no data).
    func ballPosition(at time: Double) -> (position: CGPoint, opacity: Double)? {
        guard !ballTimeline.isEmpty else {
            // Fallback: use static ball position if timeline not ready
            guard let loc = ballLocation, let impact = impactTime else { return nil }
            if time < impact {
                return (loc.position, 1.0)
            } else if time < impact + 0.5 {
                return (loc.position, max(0, 1.0 - (time - impact) / 0.5))
            }
            return nil
        }

        // Binary search for closest time entry
        var lo = 0, hi = ballTimeline.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if ballTimeline[mid].time < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Check neighbors for closest
        let idx = lo
        let entry = ballTimeline[idx]
        let timeDiff = abs(entry.time - time)

        // Too far from any entry → no data
        guard timeDiff < 0.2 else { return nil }

        // Low confidence → hide
        guard entry.confidence >= 0.3 else {
            return (entry.position, Double(entry.confidence))
        }

        return (entry.position, Double(min(1.0, entry.confidence / 0.9)))
    }

    func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        ballLocation = nil
        impactTime = nil
        ballDetected = false
        impactDetected = false
        statusMessage = ""
        swingDetections = []
        swingAnalyzed = false
        ballTimeline = []
        ballTimelineReady = false
        trajectoryResult = nil
        trajectoryDetected = false
        isAnalyzing = false
        debugMethod = ""
    }
}
