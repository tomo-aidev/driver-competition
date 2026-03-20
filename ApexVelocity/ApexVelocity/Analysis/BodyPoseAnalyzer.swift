import AVFoundation
import Vision
import simd

/// Golf swing metrics derived from 3D body pose analysis.
struct SwingMetrics: Codable {
    // Posture
    var spineAngleAtAddress: Double?     // degrees from vertical
    var spineAngleAtImpact: Double?
    var kneeBendAtAddress: Double?       // degrees

    // Rotation
    var shoulderRotationAtTop: Double?   // degrees (relative to hips)
    var hipRotationAtTop: Double?        // degrees (relative to target line)
    var xFactor: Double?                 // shoulder - hip rotation at top

    // Tempo
    var backswingDuration: Double?       // seconds
    var downswingDuration: Double?       // seconds
    var tempoRatio: Double?             // backswing / downswing (ideal ~3:1)

    // Weight shift
    var weightForwardAtImpact: Double?   // 0-1 (1 = fully forward)

    // Head stability
    var headMovementTotal: Double?       // normalized distance (lower = more stable)
}

/// Pose snapshot at a specific time
struct PoseSnapshot {
    let time: Double
    let joints: [VNHumanBodyPose3DObservation.JointName: simd_float4x4]

    func position(of joint: VNHumanBodyPose3DObservation.JointName) -> SIMD3<Float>? {
        guard let transform = joints[joint] else { return nil }
        return SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }
}

/// Analyzes golf swing mechanics using Apple Vision's 3D body pose detection.
/// Requires iOS 17+.
struct BodyPoseAnalyzer {

    /// Analyze swing from video, returning pose snapshots and computed metrics.
    @available(iOS 17.0, *)
    static func analyze(
        from asset: AVAsset,
        impactTime: CMTime
    ) async throws -> (poses: [PoseSnapshot], metrics: SwingMetrics) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        let impactSeconds = CMTimeGetSeconds(impactTime)
        let startTime = max(0, impactSeconds - 2.5)
        let endTime = impactSeconds + 1.0
        let sampleInterval = 0.1 // 10fps

        var poses: [PoseSnapshot] = []

        // Sample frames and detect body pose
        var t = startTime
        while t <= endTime {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var actualTime = CMTime.zero
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                t += sampleInterval
                continue
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNDetectHumanBodyPose3DRequest()

            try? handler.perform([request])

            if let observation = request.results?.first {
                var joints: [VNHumanBodyPose3DObservation.JointName: simd_float4x4] = [:]

                let jointNames: [VNHumanBodyPose3DObservation.JointName] = [
                    .root,            // hip center
                    .leftHip, .rightHip,
                    .leftKnee, .rightKnee,
                    .leftAnkle, .rightAnkle,
                    .spine,           // mid-spine
                    .leftShoulder, .rightShoulder,
                    .leftElbow, .rightElbow,
                    .leftWrist, .rightWrist,
                    .centerHead,
                    .centerShoulder,
                ]

                for name in jointNames {
                    if let transform = try? observation.pointInImage(name) {
                        // Use the recognized point's location
                    }
                    // Get 3D position
                    if let node = try? observation.recognizedPoint(name) {
                        joints[name] = node.localPosition
                    }
                }

                poses.append(PoseSnapshot(time: CMTimeGetSeconds(actualTime), joints: joints))
            }

            t += sampleInterval
        }

        // Compute swing metrics
        let metrics = computeMetrics(poses: poses, impactTime: impactSeconds)

        return (poses: poses, metrics: metrics)
    }

    /// Fallback for iOS 14-16: 2D body pose
    static func analyze2D(
        from asset: AVAsset,
        impactTime: CMTime
    ) async throws -> (poses: [PoseSnapshot], metrics: SwingMetrics) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        let impactSeconds = CMTimeGetSeconds(impactTime)
        let startTime = max(0, impactSeconds - 2.5)
        let endTime = impactSeconds + 1.0
        let sampleInterval = 0.1

        var poses: [PoseSnapshot] = []

        var t = startTime
        while t <= endTime {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var actualTime = CMTime.zero
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else {
                t += sampleInterval
                continue
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNDetectHumanBodyPoseRequest()

            try? handler.perform([request])

            if let observation = request.results?.first {
                var joints: [VNHumanBodyPose3DObservation.JointName: simd_float4x4] = [:]

                // Map 2D points to pseudo-3D transforms (z=0)
                let mapping: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPose3DObservation.JointName)] = [
                    (.root, .root),
                    (.leftHip, .leftHip),
                    (.rightHip, .rightHip),
                    (.leftKnee, .leftKnee),
                    (.rightKnee, .rightKnee),
                    (.leftAnkle, .leftAnkle),
                    (.rightAnkle, .rightAnkle),
                    (.leftShoulder, .leftShoulder),
                    (.rightShoulder, .rightShoulder),
                    (.leftElbow, .leftElbow),
                    (.rightElbow, .rightElbow),
                    (.leftWrist, .leftWrist),
                    (.rightWrist, .rightWrist),
                    (.nose, .centerHead),
                ]

                for (name2D, name3D) in mapping {
                    if let point = try? observation.recognizedPoint(name2D),
                       point.confidence > 0.3 {
                        var transform = simd_float4x4(1)
                        transform.columns.3 = SIMD4(Float(point.location.x),
                                                     Float(1.0 - point.location.y), // flip Y
                                                     0, 1)
                        joints[name3D] = transform
                    }
                }

                if !joints.isEmpty {
                    poses.append(PoseSnapshot(time: CMTimeGetSeconds(actualTime), joints: joints))
                }
            }

            t += sampleInterval
        }

        let metrics = computeMetrics(poses: poses, impactTime: impactSeconds)
        return (poses: poses, metrics: metrics)
    }

    // MARK: - Metrics Computation

    private static func computeMetrics(poses: [PoseSnapshot], impactTime: Double) -> SwingMetrics {
        var metrics = SwingMetrics()
        guard poses.count >= 5 else { return metrics }

        // Find key moments
        let addressPose = poses.first
        let impactPose = poses.min(by: { abs($0.time - impactTime) < abs($1.time - impactTime) })

        // Find top of backswing: frame where left wrist is highest (lowest Y in screen coords)
        let topPose = poses.min(by: { pose1, pose2 in
            let y1 = pose1.position(of: .leftWrist)?.y ?? 0
            let y2 = pose2.position(of: .leftWrist)?.y ?? 0
            return y1 > y2  // higher Y = higher position in 3D
        })

        // 1. Spine angle at address
        if let address = addressPose {
            metrics.spineAngleAtAddress = computeSpineAngle(pose: address)
        }

        // 2. Spine angle at impact
        if let impact = impactPose {
            metrics.spineAngleAtImpact = computeSpineAngle(pose: impact)
        }

        // 3. Knee bend at address
        if let address = addressPose {
            metrics.kneeBendAtAddress = computeKneeBend(pose: address)
        }

        // 4. Shoulder rotation at top
        if let top = topPose {
            metrics.shoulderRotationAtTop = computeShoulderRotation(pose: top)
        }

        // 5. Hip rotation at top
        if let top = topPose {
            metrics.hipRotationAtTop = computeHipRotation(pose: top)
        }

        // 6. X-Factor
        if let sr = metrics.shoulderRotationAtTop, let hr = metrics.hipRotationAtTop {
            metrics.xFactor = abs(sr - hr)
        }

        // 7. Tempo
        if let address = addressPose, let top = topPose, let impact = impactPose {
            let backswingDur = top.time - address.time
            let downswingDur = impact.time - top.time
            if backswingDur > 0 && downswingDur > 0 {
                metrics.backswingDuration = backswingDur
                metrics.downswingDuration = downswingDur
                metrics.tempoRatio = backswingDur / downswingDur
            }
        }

        // 8. Weight shift (hip position relative to feet)
        if let impact = impactPose {
            metrics.weightForwardAtImpact = computeWeightShift(pose: impact)
        }

        // 9. Head stability
        metrics.headMovementTotal = computeHeadStability(poses: poses)

        return metrics
    }

    private static func computeSpineAngle(pose: PoseSnapshot) -> Double? {
        guard let root = pose.position(of: .root),
              let shoulder = pose.position(of: .centerShoulder) ?? pose.position(of: .leftShoulder) else {
            return nil
        }
        let dx = Double(shoulder.x - root.x)
        let dy = Double(shoulder.y - root.y)
        // Angle from vertical (Y axis)
        return abs(atan2(dx, dy) * 180 / .pi)
    }

    private static func computeKneeBend(pose: PoseSnapshot) -> Double? {
        guard let hip = pose.position(of: .rightHip),
              let knee = pose.position(of: .rightKnee),
              let ankle = pose.position(of: .rightAnkle) else {
            return nil
        }
        return angleBetween(a: hip, b: knee, c: ankle)
    }

    private static func computeShoulderRotation(pose: PoseSnapshot) -> Double? {
        guard let leftShoulder = pose.position(of: .leftShoulder),
              let rightShoulder = pose.position(of: .rightShoulder) else {
            return nil
        }
        let dx = Double(rightShoulder.x - leftShoulder.x)
        let dz = Double(rightShoulder.z - leftShoulder.z)
        return atan2(dz, dx) * 180 / .pi
    }

    private static func computeHipRotation(pose: PoseSnapshot) -> Double? {
        guard let leftHip = pose.position(of: .leftHip),
              let rightHip = pose.position(of: .rightHip) else {
            return nil
        }
        let dx = Double(rightHip.x - leftHip.x)
        let dz = Double(rightHip.z - leftHip.z)
        return atan2(dz, dx) * 180 / .pi
    }

    private static func computeWeightShift(pose: PoseSnapshot) -> Double? {
        guard let root = pose.position(of: .root),
              let leftAnkle = pose.position(of: .leftAnkle),
              let rightAnkle = pose.position(of: .rightAnkle) else {
            return nil
        }
        let midFoot = (leftAnkle.x + rightAnkle.x) / 2
        let targetFoot = leftAnkle.x // left foot is target side for right-hander
        let trailFoot = rightAnkle.x
        let range = abs(targetFoot - trailFoot)
        guard range > 0.01 else { return 0.5 }
        return Double((root.x - trailFoot) / range).clamped(to: 0...1)
    }

    private static func computeHeadStability(poses: [PoseSnapshot]) -> Double? {
        let headPositions = poses.compactMap { $0.position(of: .centerHead) }
        guard headPositions.count >= 3 else { return nil }

        let avgX = headPositions.map(\.x).reduce(0, +) / Float(headPositions.count)
        let avgY = headPositions.map(\.y).reduce(0, +) / Float(headPositions.count)

        var totalDist: Float = 0
        for pos in headPositions {
            totalDist += sqrt((pos.x - avgX) * (pos.x - avgX) + (pos.y - avgY) * (pos.y - avgY))
        }
        return Double(totalDist / Float(headPositions.count))
    }

    private static func angleBetween(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> Double {
        let ba = a - b
        let bc = c - b
        let dot = simd_dot(ba, bc)
        let magBA = simd_length(ba)
        let magBC = simd_length(bc)
        guard magBA > 0 && magBC > 0 else { return 0 }
        let cosAngle = dot / (magBA * magBC)
        return acos(Double(min(1, max(-1, cosAngle)))) * 180 / .pi
    }
}

// MARK: - Comparable Extension

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
