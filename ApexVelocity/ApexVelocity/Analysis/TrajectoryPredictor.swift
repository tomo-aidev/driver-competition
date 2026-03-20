import Foundation
import CoreGraphics

/// Predicts the full golf ball trajectory using physics simulation.
/// Takes initial detected positions and extrapolates using gravity, drag, and lift.
struct TrajectoryPredictor {

    struct PhysicsConfig {
        var gravity: Double = 9.81
        var dragCoefficient: Double = 0.25
        var liftCoefficient: Double = 0.15
        var ballMass: Double = 0.04593   // 45.93g
        var ballRadius: Double = 0.02135 // 21.35mm
        var airDensity: Double = 1.225   // kg/m³ at sea level
        var timeStep: Double = 0.002     // 2ms integration step
        var maxFlightTime: Double = 8.0  // max seconds of flight
    }

    /// Predict full trajectory from detected ball positions.
    /// - Parameters:
    ///   - detectedPoints: Ball positions detected via frame differencing
    ///   - videoSize: Video dimensions in pixels
    ///   - videoFPS: Video frame rate
    ///   - config: Physics parameters
    /// - Returns: Array of TrajectoryPoints in normalized coordinates
    static func predict(
        detectedPoints: [BallDetection],
        videoSize: CGSize,
        videoFPS: Double,
        config: PhysicsConfig = PhysicsConfig()
    ) -> [TrajectoryPoint] {
        guard detectedPoints.count >= 2 else { return [] }

        // Estimate initial conditions from detected points
        let initial = estimateInitialConditions(
            from: detectedPoints,
            videoSize: videoSize,
            fps: videoFPS
        )

        // Run physics simulation
        let simulated = simulate(
            launchAngle: initial.launchAngle,
            launchSpeed: initial.launchSpeed,
            lateralAngle: initial.lateralAngle,
            config: config
        )

        // Project 3D trajectory back to 2D video coordinates
        let projected = projectToVideo(
            trajectory3D: simulated,
            startPosition: detectedPoints[0].normalizedCenter,
            videoSize: videoSize,
            launchDirection: initial.lateralAngle
        )

        return projected
    }

    // MARK: - Initial Condition Estimation

    private struct InitialConditions {
        var launchAngle: Double   // radians, from horizontal
        var launchSpeed: Double   // m/s
        var lateralAngle: Double  // radians, 0 = straight, positive = right
    }

    private static func estimateInitialConditions(
        from detections: [BallDetection],
        videoSize: CGSize,
        fps: Double
    ) -> InitialConditions {
        // Use first and last detection to estimate velocity vector
        let first = detections[0]
        let last = detections[min(detections.count - 1, 5)] // use up to 5th detection

        let dx = (last.normalizedCenter.x - first.normalizedCenter.x) * Double(videoSize.width)
        let dy = (last.normalizedCenter.y - first.normalizedCenter.y) * Double(videoSize.height)
        let dt = Double(detections.count - 1) / fps

        guard dt > 0 else {
            return InitialConditions(launchAngle: 0.6, launchSpeed: 60, lateralAngle: 0)
        }

        let pixelVx = dx / dt
        let pixelVy = dy / dt

        // Estimate launch angle from pixel velocity direction
        // In video: negative dy = upward, positive dx = rightward
        let launchAngle = atan2(-pixelVy, abs(pixelVx))

        // Estimate lateral angle
        let lateralAngle = atan2(pixelVx, abs(pixelVy))

        // Rough speed estimate: assume camera covers ~30m of width at ball distance
        let metersPerPixel = 30.0 / Double(videoSize.width)
        let speedMps = sqrt(pixelVx * pixelVx + pixelVy * pixelVy) * metersPerPixel

        // Clamp to realistic golf ball speeds (30-80 m/s)
        let clampedSpeed = max(30, min(80, speedMps))

        return InitialConditions(
            launchAngle: max(0.15, min(1.3, launchAngle)), // 8-75 degrees
            launchSpeed: clampedSpeed,
            lateralAngle: max(-0.5, min(0.5, lateralAngle))
        )
    }

    // MARK: - Physics Simulation

    private struct Point3D {
        var x: Double // lateral (left/right)
        var y: Double // forward (distance)
        var z: Double // vertical (height)
    }

    private static func simulate(
        launchAngle: Double,
        launchSpeed: Double,
        lateralAngle: Double,
        config: PhysicsConfig
    ) -> [Point3D] {
        let crossArea = .pi * config.ballRadius * config.ballRadius

        // Initial velocity components
        var vx = launchSpeed * cos(launchAngle) * sin(lateralAngle) // lateral
        var vy = launchSpeed * cos(launchAngle) * cos(lateralAngle) // forward
        var vz = launchSpeed * sin(launchAngle)                     // vertical

        var x: Double = 0
        var y: Double = 0
        var z: Double = 0

        var trajectory: [Point3D] = [Point3D(x: x, y: y, z: z)]
        var t: Double = 0

        while t < config.maxFlightTime {
            let speed = sqrt(vx * vx + vy * vy + vz * vz)
            guard speed > 0.1 else { break }

            // Drag force magnitude
            let dragMag = 0.5 * config.dragCoefficient * config.airDensity * crossArea * speed * speed

            // Drag acceleration (opposes velocity)
            let ax_drag = -dragMag * vx / (speed * config.ballMass)
            let ay_drag = -dragMag * vy / (speed * config.ballMass)
            let az_drag = -dragMag * vz / (speed * config.ballMass)

            // Lift (Magnus effect — simplified upward force proportional to horizontal speed)
            let horizontalSpeed = sqrt(vx * vx + vy * vy)
            let liftMag = 0.5 * config.liftCoefficient * config.airDensity * crossArea * horizontalSpeed * horizontalSpeed
            let az_lift = liftMag / config.ballMass

            // Total acceleration
            let ax = ax_drag
            let ay = ay_drag
            let az = az_drag + az_lift - config.gravity

            // Euler integration
            vx += ax * config.timeStep
            vy += ay * config.timeStep
            vz += az * config.timeStep

            x += vx * config.timeStep
            y += vy * config.timeStep
            z += vz * config.timeStep

            t += config.timeStep

            // Record point every ~33ms (30fps output)
            if trajectory.count < Int(t * 30) + 1 {
                trajectory.append(Point3D(x: x, y: y, z: z))
            }

            // Ball hit the ground
            if z < 0 && t > 0.5 {
                // Interpolate to exact ground level
                let lastZ = trajectory[trajectory.count - 1].z
                if lastZ != 0 {
                    trajectory.append(Point3D(x: x, y: y, z: 0))
                }
                break
            }
        }

        return trajectory
    }

    // MARK: - 3D to 2D Projection

    private static func projectToVideo(
        trajectory3D: [Point3D],
        startPosition: CGPoint,
        videoSize: CGSize,
        launchDirection: Double
    ) -> [TrajectoryPoint] {
        guard let maxDistance = trajectory3D.last?.y, maxDistance > 0 else { return [] }

        // Vanishing point: where the fairway converges
        let vanishX = Double(videoSize.width) * 0.48
        let vanishY = Double(videoSize.height) * 0.35

        let startX = Double(startPosition.x * videoSize.width)
        let startY = Double(startPosition.y * videoSize.height)

        return trajectory3D.map { point in
            // Depth ratio (0 = at ball, 1 = at max distance)
            let depthRatio = point.y / maxDistance

            // Perspective: objects further away converge toward vanishing point
            let perspectiveScale = 1.0 / (1.0 + depthRatio * 2.0)

            // X position: start + lateral offset (scaled by perspective) + convergence to vanish
            let baseX = startX + (vanishX - startX) * depthRatio * 0.8
            let lateralOffset = point.x * 20.0 * perspectiveScale // scale lateral to pixels
            let screenX = baseX + lateralOffset

            // Y position: start + convergence to vanish - height offset (scaled by perspective)
            let baseY = startY + (vanishY - startY) * depthRatio * 0.8
            let heightOffset = point.z * 30.0 * perspectiveScale // scale height to pixels
            let screenY = baseY - heightOffset

            return TrajectoryPoint(
                position: CGPoint(x: screenX, y: screenY),
                timestamp: CFAbsoluteTimeGetCurrent()
            )
        }
    }
}
