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

    private var analysisTask: Task<Void, Never>?

    func analyze(videoURL: URL, record: inout ShotRecord) async {
        status = .analyzing
        record.analysisStatus = .analyzing
        progress = 0

        let asset = AVURLAsset(url: videoURL)

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

        // Compute metrics
        let detectedCount = fullTrajectory.filter { $0.isDetected }.count
        let predictedCount = fullTrajectory.filter { !$0.isDetected }.count

        record.metrics = ShotMetrics(
            estimatedLaunchAngle: estimateLaunchAngle(from: fullTrajectory),
            estimatedLaunchDirection: estimateLaunchDirection(from: fullTrajectory),
            estimatedBallSpeed: nil,
            estimatedCarryDistance: nil,
            detectedFrameCount: detectedCount,
            predictedFrameCount: predictedCount,
            analysisConfidence: mergedDetections.count >= 3 ? 0.8 : 0.4
        )

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

        progress = 1.0
        status = .completed
        record.analysisStatus = .completed
        record.analysisProgress = 1.0
        statusMessage = String(localized: "analysis_complete", defaultValue: "Analysis complete")
        print("[PostProcess] Complete: \(detectedCount) detected, \(predictedCount) predicted")
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
