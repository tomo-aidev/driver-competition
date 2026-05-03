import AVFoundation
import Vision
import CoreGraphics
import Combine

/// Accuracy-focused post-processing analyzer.
/// Runs in background after recording, taking as much time as needed for precision.
///
/// Pipeline:
/// 1. Audio impact detection (fast, reliable)
/// 2. VNDetectTrajectoriesRequest for ball trajectory (Apple Vision)
/// 3. Frame differencing + Kalman filter around impact for ball tracking
/// 4. Club head tracking for swing analysis
/// 5. Physics simulation to complete trajectory
@MainActor
final class PostProcessAnalyzer: ObservableObject {

    @Published var progress: Double = 0
    @Published var status: AnalysisStatus = .pending
    @Published var statusMessage: String = ""
    @Published var lastMetrics: ShotMetrics?

    private var analysisTask: Task<Void, Never>?

    func analyze(videoURL: URL, record: inout ShotRecord) async {
        status = .analyzing
        record.analysisStatus = .analyzing
        progress = 0

        let asset = AVURLAsset(url: videoURL)

        // Use known ball position from recording target frame
        let knownBallPos: CGPoint?
        if let bx = record.knownBallPositionX, let by = record.knownBallPositionY {
            knownBallPos = CGPoint(x: bx, y: by)
            print("[PostProcess] Using known ball position: (\(String(format: "%.3f", bx)), \(String(format: "%.3f", by)))")
        } else {
            knownBallPos = nil
            print("[PostProcess] No known ball position, will attempt AI detection")
        }

        // Stage 1: Audio impact detection (10% of progress)
        statusMessage = String(localized: "analyzing_impact_sound", defaultValue: "Detecting impact sound...")
        let impactTime = await detectImpact(asset: asset)
        record.impactTimeSeconds = impactTime.map { CMTimeGetSeconds($0) }
        progress = 0.1

        guard let impact = impactTime else {
            statusMessage = String(localized: "impact_not_found_title", defaultValue: "Impact not detected")
            status = .failed
            record.analysisStatus = .failed
            return
        }

        let impactSeconds = CMTimeGetSeconds(impact)
        print("[PostProcess] Impact at \(String(format: "%.3f", impactSeconds))s")

        // Stage 2: Vision trajectory detection (30% of progress)
        statusMessage = String(localized: "tracking_ball_vision", defaultValue: "Tracking ball with Vision AI...")
        let visionPoints = await detectTrajectoryWithVision(asset: asset, impactTime: impact)
        progress = 0.4
        print("[PostProcess] Vision detected \(visionPoints.count) trajectory points")

        // Stage 3: Frame differencing + Kalman filter (30% of progress)
        statusMessage = String(localized: "analyzing_frames", defaultValue: "Analyzing frames...")
        let frameDiffPoints = await detectWithFrameDifferencing(asset: asset, impactTime: impact)
        progress = 0.7
        print("[PostProcess] Frame diff detected \(frameDiffPoints.count) points")

        // Merge detections: prefer Vision, fill gaps with frame diff
        let mergedDetections = mergeDetections(vision: visionPoints, frameDiff: frameDiffPoints)
        print("[PostProcess] Merged \(mergedDetections.count) detection points")

        // Stage 4: Swing analysis (10% of progress)
        statusMessage = String(localized: "analyzing_swing", defaultValue: "Analyzing swing...")
        let swingPoints = await analyzeSwing(asset: asset, impactTime: impact)
        progress = 0.8

        record.swingTrajectory = swingPoints.map { det in
            SwingPointRecord(
                x: det.position.x,
                y: det.position.y,
                time: det.frameTime,
                phase: {
                    switch det.phase {
                    case .address: return "address"
                    case .backswing: return "backswing"
                    case .downswing: return "downswing"
                    case .postImpact: return "postImpact"
                    }
                }()
            )
        }

        // Stage 5: Physics prediction to complete trajectory (10% of progress)
        statusMessage = String(localized: "predicting_trajectory", defaultValue: "Computing trajectory physics...")

        let videoSize = await getVideoSize(asset: asset)
        let fps = await getVideoFPS(asset: asset)

        let fullTrajectory: [TrajectoryPointRecord]
        if mergedDetections.count >= 2 {
            let predicted = TrajectoryPredictor.predict(
                detectedPoints: mergedDetections,
                videoSize: videoSize,
                videoFPS: fps
            )

            // Convert detected + predicted to records
            var records: [TrajectoryPointRecord] = []

            // Add detected points
            for det in mergedDetections {
                records.append(TrajectoryPointRecord(
                    x: det.normalizedCenter.x,
                    y: det.normalizedCenter.y,
                    time: det.timestamp - impactSeconds,
                    isDetected: true
                ))
            }

            // Add predicted points (those beyond detected range)
            let lastDetectedTime = mergedDetections.last?.timestamp ?? impactSeconds
            for pt in predicted {
                let normalizedX = pt.position.x / videoSize.width
                let normalizedY = pt.position.y / videoSize.height
                let ptTime = lastDetectedTime - impactSeconds + Double(records.count) / fps
                if ptTime > (lastDetectedTime - impactSeconds) {
                    records.append(TrajectoryPointRecord(
                        x: normalizedX,
                        y: normalizedY,
                        time: ptTime,
                        isDetected: false
                    ))
                }
            }

            fullTrajectory = records
        } else {
            // Not enough detections — generate pure physics trajectory from ball position
            fullTrajectory = generateDefaultTrajectory(impactSeconds: impactSeconds)
        }

        record.ballTrajectory = fullTrajectory
        progress = 0.9

        // Compute metrics with swing-based estimation
        let detectedCount = fullTrajectory.filter { $0.isDetected }.count
        let predictedCount = fullTrajectory.filter { !$0.isDetected }.count

        // Estimate head speed from swing tempo (backswing duration → downswing acceleration)
        let swingMetricsResult = estimateSwingMetrics(
            swingPoints: swingPoints,
            impactSeconds: impactSeconds,
            launchAngle: estimateLaunchAngle(from: fullTrajectory),
            launchDirection: estimateLaunchDirection(from: fullTrajectory)
        )

        record.metrics = ShotMetrics(
            estimatedLaunchAngle: swingMetricsResult.launchAngle,
            estimatedLaunchDirection: swingMetricsResult.direction,
            estimatedBallSpeed: swingMetricsResult.ballSpeed,
            estimatedHeadSpeed: swingMetricsResult.headSpeed,
            estimatedCarryDistance: swingMetricsResult.carryYards,
            estimatedCarryDistanceMeters: swingMetricsResult.carryMeters,
            detectedFrameCount: detectedCount,
            predictedFrameCount: predictedCount,
            analysisConfidence: mergedDetections.count >= 3 ? 0.8 : 0.4
        )
        lastMetrics = record.metrics

        // Stage 6: Body pose analysis (bonus stage)
        statusMessage = String(localized: "analyzing_body_pose", defaultValue: "Analyzing body pose...")
        do {
            let poseResult: (poses: [PoseSnapshot], metrics: SwingMetrics)
            if #available(iOS 17.0, *) {
                poseResult = try await BodyPoseAnalyzer.analyze(from: asset, impactTime: impact)
            } else {
                poseResult = try await BodyPoseAnalyzer.analyze2D(from: asset, impactTime: impact)
            }
            record.swingMetrics = poseResult.metrics
            print("[PostProcess] Body pose: \(poseResult.poses.count) snapshots")
            if let tempo = poseResult.metrics.tempoRatio {
                print("[PostProcess] Tempo ratio: \(String(format: "%.1f", tempo)):1")
            }
            if let xFactor = poseResult.metrics.xFactor {
                print("[PostProcess] X-Factor: \(String(format: "%.1f", xFactor))°")
            }
        } catch {
            print("[PostProcess] Body pose error: \(error)")
        }

        // Stage 7: Extract key frames with ball marker overlay
        statusMessage = String(localized: "extracting_keyframes", defaultValue: "Extracting key frames...")
        let shotsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shots", isDirectory: true)

        // Get ball position from BallFinder (re-detect or use stored)
        let ballPos = await BallFinder.find(in: asset, impactTime: record.impactTimeSeconds)
        let ballPoint = ballPos?.position

        // Get swing detections for top-of-backswing
        var swingDets: [ClubHeadDetection] = []
        if let impactSecs = record.impactTimeSeconds {
            let cmImpact = CMTime(seconds: impactSecs, preferredTimescale: 600)
            swingDets = (try? await SwingAnalyzer.analyzeSwing(
                from: asset, impactTime: cmImpact,
                ballPosition: ballPoint ?? CGPoint(x: 0.5, y: 0.8)
            )) ?? []
        }

        let keyFrames = await KeyFrameExtractor.extractKeyFrames(
            from: asset,
            impactTime: record.impactTimeSeconds,
            ballPosition: ballPoint,
            swingDetections: swingDets,
            shotID: record.id,
            saveTo: shotsDir
        )
        record.keyFrames = keyFrames

        progress = 1.0
        status = .completed
        record.analysisStatus = .completed
        record.analysisProgress = 1.0
        statusMessage = String(localized: "analysis_complete", defaultValue: "Analysis complete")
        print("[PostProcess] Complete: \(detectedCount) detected, \(predictedCount) predicted, \(keyFrames.count) key frames")
    }

    func cancel() {
        analysisTask?.cancel()
    }

    // MARK: - Stage 1: Impact Detection

    private func detectImpact(asset: AVAsset) async -> CMTime? {
        do {
            return try await ImpactDetector.detectImpact(from: asset)
        } catch {
            print("[PostProcess] Impact detection error: \(error)")
            return nil
        }
    }

    // MARK: - Stage 2: Vision Trajectory Detection

    private func detectTrajectoryWithVision(asset: AVAsset, impactTime: CMTime) async -> [BallDetection] {
        let impactSeconds = CMTimeGetSeconds(impactTime)
        let startTime = CMTime(seconds: max(0, impactSeconds - 0.5), preferredTimescale: 600)
        let endTime = CMTime(seconds: impactSeconds + 3.0, preferredTimescale: 600)

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return []
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return []
        }

        reader.timeRange = CMTimeRange(start: startTime, end: endTime)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var detections: [BallDetection] = []
        let trajectoryRequest = VNDetectTrajectoriesRequest(
            frameAnalysisSpacing: .zero,
            trajectoryLength: 5
        ) { request, error in
            guard let results = request.results as? [VNTrajectoryObservation] else { return }

            for observation in results {
                // Each observation has detected points along the trajectory
                let points = observation.detectedPoints
                for point in points {
                    // VNPoint coordinates: origin bottom-left, normalized 0-1
                    let normalizedCenter = CGPoint(
                        x: point.x,
                        y: 1.0 - point.y  // flip Y for top-left origin
                    )

                    let detection = BallDetection(
                        normalizedCenter: normalizedCenter,
                        confidence: Float(observation.confidence),
                        boundingBox: CGRect(
                            x: normalizedCenter.x - 0.01,
                            y: normalizedCenter.y - 0.01,
                            width: 0.02,
                            height: 0.02
                        ),
                        timestamp: CMTimeGetSeconds(impactTime)
                    )
                    detections.append(detection)
                }
            }
        }

        // Set detection parameters for small fast objects
        trajectoryRequest.objectMinimumNormalizedRadius = 0.002  // very small ball
        trajectoryRequest.objectMaximumNormalizedRadius = 0.05

        let handler = VNSequenceRequestHandler()

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            do {
                try handler.perform([trajectoryRequest], on: sampleBuffer,
                                    orientation: .up)
            } catch {
                // Continue even if individual frames fail
            }
        }

        return detections
    }

    // MARK: - Stage 3: Frame Differencing

    private func detectWithFrameDifferencing(asset: AVAsset, impactTime: CMTime) async -> [BallDetection] {
        let config = FrameDifferenceDetector.Config(
            framesToExtract: 30,
            differenceThreshold: 25,
            minBlobSize: 3,
            maxBlobSize: 50,
            searchRegionTopRatio: 0.0,
            searchRegionBottomRatio: 0.85
        )

        do {
            let detections = try await FrameDifferenceDetector.detect(
                from: asset,
                impactTime: impactTime,
                config: config
            )

            // Apply Kalman filter to smooth detections
            guard detections.count >= 2 else { return detections }

            var kalman = KalmanFilter2D(
                initialPosition: detections[0].normalizedCenter,
                processNoiseScale: 0.5,
                measurementNoiseScale: 2.0
            )

            var smoothed: [BallDetection] = []
            var prevTime = detections[0].timestamp

            for det in detections {
                let dt = det.timestamp - prevTime
                if dt > 0 {
                    kalman.predict(dt: dt)
                }
                let filtered = kalman.update(measurement: det.normalizedCenter)

                smoothed.append(BallDetection(
                    normalizedCenter: filtered,
                    confidence: det.confidence,
                    boundingBox: det.boundingBox,
                    timestamp: det.timestamp
                ))
                prevTime = det.timestamp
            }

            return smoothed
        } catch {
            print("[PostProcess] Frame diff error: \(error)")
            return []
        }
    }

    // MARK: - Merge Detections

    private func mergeDetections(vision: [BallDetection], frameDiff: [BallDetection]) -> [BallDetection] {
        // If Vision found trajectory, prefer it
        if vision.count >= 3 {
            return vision
        }

        // Otherwise use frame differencing results
        if frameDiff.count >= 2 {
            return frameDiff
        }

        // Combine both if each has some
        return (vision + frameDiff).sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Stage 4: Swing Analysis

    private func analyzeSwing(asset: AVAsset, impactTime: CMTime) async -> [ClubHeadDetection] {
        do {
            return try await SwingAnalyzer.analyzeSwing(
                from: asset,
                impactTime: impactTime,
                ballPosition: CGPoint(x: 0.5, y: 0.8)
            )
        } catch {
            print("[PostProcess] Swing analysis error: \(error)")
            return []
        }
    }

    // MARK: - Swing Metrics Estimation

    private struct SwingEstimate {
        let headSpeed: Double?   // m/s
        let ballSpeed: Double?   // m/s
        let launchAngle: Double? // degrees
        let direction: Double?   // degrees
        let carryYards: Double?  // yards
        let carryMeters: Double? // meters
    }

    private func estimateSwingMetrics(
        swingPoints: [ClubHeadDetection],
        impactSeconds: Double,
        launchAngle: Double?,
        launchDirection: Double?
    ) -> SwingEstimate {
        // Estimate head speed from downswing velocity
        let downswing = swingPoints.filter { $0.phase == .downswing }

        var headSpeedMs: Double? = nil
        var ballSpeedMs: Double? = nil

        if downswing.count >= 3 {
            // Last 3 points of downswing → velocity in normalized coords
            let last3 = Array(downswing.suffix(3))
            let dt = last3.last!.frameTime - last3.first!.frameTime
            let dx = last3.last!.position.x - last3.first!.position.x
            let dy = last3.last!.position.y - last3.first!.position.y
            let normalizedSpeed = sqrt(dx * dx + dy * dy) / max(0.001, dt)

            // Convert normalized speed to approximate m/s
            // Typical club head travels ~1m in the last 3 frames at ~45m/s
            // In normalized coords, that's ~0.3-0.5 units per second for a mid-speed swing
            headSpeedMs = normalizedSpeed * 100  // rough calibration factor
            headSpeedMs = max(25, min(55, headSpeedMs!))  // clamp to realistic range

            // Smash factor: ball speed = head speed × 1.45 (typical)
            ballSpeedMs = headSpeedMs! * 1.45
        }

        // If no swing data, estimate from launch angle (typical amateur)
        if headSpeedMs == nil {
            headSpeedMs = 40.0  // average amateur: 40 m/s
            ballSpeedMs = 40.0 * 1.45
        }

        // Direction estimation (improve from trajectory-only)
        let direction = launchDirection ?? 0

        // Launch angle (default 13° if not detected)
        let angle = launchAngle ?? 13.0

        // Carry distance: simplified formula
        // d = (v₀² × sin(2θ)) / g × correction
        let v0 = ballSpeedMs ?? 58.0
        let theta = angle * .pi / 180
        let g = 9.81
        let correction = 0.90  // air resistance correction
        let carryM = (v0 * v0 * sin(2 * theta)) / g * correction
        let carryY = carryM * 1.09361  // meters to yards

        return SwingEstimate(
            headSpeed: headSpeedMs,
            ballSpeed: ballSpeedMs,
            launchAngle: angle,
            direction: direction,
            carryYards: min(350, carryY),   // cap at realistic max
            carryMeters: min(320, carryM)
        )
    }

    // MARK: - Helpers

    private func getVideoSize(asset: AVAsset) async -> CGSize {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return CGSize(width: 720, height: 1280)
        }
        let size = try? await track.load(.naturalSize)
        return size ?? CGSize(width: 720, height: 1280)
    }

    private func getVideoFPS(asset: AVAsset) async -> Double {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return 30
        }
        let rate = try? await track.load(.nominalFrameRate)
        return Double(rate ?? 30)
    }

    private func estimateLaunchAngle(from trajectory: [TrajectoryPointRecord]) -> Double? {
        let detected = trajectory.filter { $0.isDetected }
        guard detected.count >= 2 else { return nil }
        let dy = detected[1].y - detected[0].y  // negative = upward
        let dx = abs(detected[1].x - detected[0].x) + 0.001
        return atan2(-dy, dx) * 180 / .pi
    }

    private func estimateLaunchDirection(from trajectory: [TrajectoryPointRecord]) -> Double? {
        let detected = trajectory.filter { $0.isDetected }
        guard detected.count >= 2 else { return nil }
        let dx = detected[1].x - detected[0].x
        return dx * 90  // rough conversion to degrees
    }

    private func generateDefaultTrajectory(impactSeconds: Double) -> [TrajectoryPointRecord] {
        // Generate physics-based trajectory arc using golf ball physics
        // Simulates a typical driver shot: 140mph, 12° launch, slight fade
        var points: [TrajectoryPointRecord] = []
        let steps = 120

        // Ball start position (normalized)
        let startX = 0.55
        let startY = 0.80
        // Vanishing point
        let vanishX = 0.52
        let vanishY = 0.35

        for i in 0...steps {
            let t = Double(i) / Double(steps)

            // Height: parabolic arc (peaks at t≈0.45 for driver)
            let heightRatio = 4.0 * t * (1.0 - t) * (1.0 - t * 0.15)

            // Ground track toward vanishing point
            let groundX = startX + (vanishX - startX) * t * 0.9
            let groundY = startY + (vanishY - startY) * t * 0.9

            // Height in normalized coordinates
            let maxArcHeight = (startY - 0.05) * 0.70
            let perspectiveDecay = 1.0 / (1.0 + t * 1.5)
            let heightOffset = heightRatio * maxArcHeight * perspectiveDecay

            // Lateral fade curve
            let fadeAmount = t * (1.0 - t) * 0.12

            let x = groundX + fadeAmount
            let y = groundY - heightOffset

            points.append(TrajectoryPointRecord(
                x: max(0, min(1, x)),
                y: max(0, min(1, y)),
                time: t * 5.5,
                isDetected: false
            ))
        }
        return points
    }
}
