import CoreMotion
import Combine

/// Manages device motion data for camera angle guidance.
/// Provides pitch (tilt up/down) to help users position the phone correctly.
final class DeviceMotionManager: ObservableObject {

    // MARK: - Published State

    /// Device pitch in degrees. 0 = horizontal, positive = tilted up, negative = tilted down.
    @Published private(set) var pitchDegrees: Double = 0

    /// Whether the device angle is acceptable for shot capture
    @Published private(set) var isAngleGood: Bool = false

    // MARK: - Private

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    /// Acceptable pitch range in degrees (80-90 = phone nearly vertical, pointing at ball)
    private let minPitch: Double = 80.0
    private let maxPitch: Double = 90.0

    // MARK: - Lifecycle

    func startMonitoring() {
        guard motionManager.isDeviceMotionAvailable else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionQueue.name = "com.apexvelocity.motion"
        motionQueue.maxConcurrentOperationCount = 1

        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: motionQueue
        ) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }

            // Pitch: rotation around x-axis
            // When phone is held in portrait, landscape-left filming position:
            // pitch ~0 = horizontal, positive = tilted up
            let pitch = motion.attitude.pitch * 180.0 / .pi

            DispatchQueue.main.async {
                self.pitchDegrees = pitch
                self.isAngleGood = pitch >= self.minPitch && pitch <= self.maxPitch
            }
        }
    }

    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
    }
}
