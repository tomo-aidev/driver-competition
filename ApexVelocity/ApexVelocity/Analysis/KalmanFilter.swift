import Foundation
import simd

/// 2D Kalman filter with constant-velocity motion model.
/// State: [x, y, vx, vy]
struct KalmanFilter2D {

    /// Current state estimate [x, y, vx, vy]
    private(set) var state: SIMD4<Double>

    /// State covariance matrix (4x4)
    private(set) var covariance: simd_double4x4

    /// Process noise covariance
    private let processNoise: simd_double4x4

    /// Measurement noise covariance (2x2, applied via observation matrix)
    private let measurementNoise: Double

    init(
        initialPosition: CGPoint,
        initialVelocity: CGPoint = .zero,
        processNoiseScale: Double = 1.0,
        measurementNoiseScale: Double = 3.0
    ) {
        self.state = SIMD4(initialPosition.x, initialPosition.y, initialVelocity.x, initialVelocity.y)

        // Initial covariance: high uncertainty
        self.covariance = simd_double4x4(diagonal: SIMD4(10, 10, 100, 100))

        // Process noise: acceleration uncertainty
        let q = processNoiseScale
        self.processNoise = simd_double4x4(rows: [
            SIMD4(q * 0.25, 0, q * 0.5, 0),
            SIMD4(0, q * 0.25, 0, q * 0.5),
            SIMD4(q * 0.5, 0, q, 0),
            SIMD4(0, q * 0.5, 0, q)
        ])

        self.measurementNoise = measurementNoiseScale
    }

    /// Predict step: advance state by dt seconds
    mutating func predict(dt: Double) {
        // State transition matrix (constant velocity model)
        let F = simd_double4x4(rows: [
            SIMD4(1, 0, dt, 0),
            SIMD4(0, 1, 0, dt),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        ])

        // Predict state
        state = F * state

        // Predict covariance
        let scaledQ = processNoise * (dt * dt)
        covariance = F * covariance * F.transpose + scaledQ
    }

    /// Update step: incorporate measurement
    mutating func update(measurement: CGPoint) -> CGPoint {
        // Observation matrix: we only measure position (x, y)
        // H = [[1,0,0,0],[0,1,0,0]]
        // Innovation: z - H*x
        let innovationX = measurement.x - state.x
        let innovationY = measurement.y - state.y

        // Innovation covariance: S = H*P*H' + R
        let s00 = covariance[0][0] + measurementNoise
        let s01 = covariance[0][1]
        let s10 = covariance[1][0]
        let s11 = covariance[1][1] + measurementNoise

        // Invert S (2x2)
        let det = s00 * s11 - s01 * s10
        guard abs(det) > 1e-10 else {
            return CGPoint(x: state.x, y: state.y)
        }
        let invDet = 1.0 / det
        let si00 = s11 * invDet
        let si01 = -s01 * invDet
        let si10 = -s10 * invDet
        let si11 = s00 * invDet

        // Kalman gain: K = P*H'*S^-1 (4x2)
        let k00 = covariance[0][0] * si00 + covariance[0][1] * si10
        let k01 = covariance[0][0] * si01 + covariance[0][1] * si11
        let k10 = covariance[1][0] * si00 + covariance[1][1] * si10
        let k11 = covariance[1][0] * si01 + covariance[1][1] * si11
        let k20 = covariance[2][0] * si00 + covariance[2][1] * si10
        let k21 = covariance[2][0] * si01 + covariance[2][1] * si11
        let k30 = covariance[3][0] * si00 + covariance[3][1] * si10
        let k31 = covariance[3][0] * si01 + covariance[3][1] * si11

        // Update state
        state.x += k00 * innovationX + k01 * innovationY
        state.y += k10 * innovationX + k11 * innovationY
        state.z += k20 * innovationX + k21 * innovationY // vx
        state.w += k30 * innovationX + k31 * innovationY // vy

        // Update covariance: P = (I - K*H)*P
        let kh = simd_double4x4(rows: [
            SIMD4(k00, k01, 0, 0),
            SIMD4(k10, k11, 0, 0),
            SIMD4(k20, k21, 0, 0),
            SIMD4(k30, k31, 0, 0)
        ])
        let I = simd_double4x4(diagonal: SIMD4(repeating: 1))
        covariance = (I - kh) * covariance

        return CGPoint(x: state.x, y: state.y)
    }

    /// Current estimated position
    var position: CGPoint {
        CGPoint(x: state.x, y: state.y)
    }

    /// Current estimated velocity
    var velocity: CGPoint {
        CGPoint(x: state.z, y: state.w)
    }
}
