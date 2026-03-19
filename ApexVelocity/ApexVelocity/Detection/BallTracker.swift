import AVFoundation
import Combine
import CoreGraphics

/// Tracks ball positions over time and maintains the trajectory path.
/// Converts normalized detection coordinates to screen coordinates.
final class BallTracker: ObservableObject {

    // MARK: - Published State

    @Published private(set) var trajectoryPoints: [TrajectoryPoint] = []
    @Published private(set) var isTrackingActive = false

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private var lastNormalizedPosition: CGPoint?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Initialization

    /// Bind to a BallDetector's detections
    func bind(to detector: BallDetector) {
        detector.$latestDetection
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detection in
                self?.addDetection(detection)
            }
            .store(in: &cancellables)
    }

    /// Set the preview layer for coordinate conversion
    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = layer
    }

    // MARK: - Detection Processing

    private func addDetection(_ detection: BallDetection) {
        let normalizedPoint = detection.normalizedCenter

        // Check for position jump (new trajectory)
        if let lastPos = lastNormalizedPosition {
            let dx = normalizedPoint.x - lastPos.x
            let dy = normalizedPoint.y - lastPos.y
            let distance = sqrt(dx * dx + dy * dy)

            if distance > DetectionConfig.maxPositionJump {
                // Position jumped too far — treat as new trajectory
                trajectoryPoints.removeAll()
            }
        }
        lastNormalizedPosition = normalizedPoint

        // Convert to screen coordinates
        let screenPoint: CGPoint
        if let layer = previewLayer {
            screenPoint = layer.layerPointConverted(fromCaptureDevicePoint: normalizedPoint)
        } else {
            // Fallback: use normalized coordinates directly
            // (will be scaled by the view's bounds)
            screenPoint = normalizedPoint
        }

        let point = TrajectoryPoint(
            position: screenPoint,
            timestamp: detection.timestamp
        )

        trajectoryPoints.append(point)

        // Trim to max points
        if trajectoryPoints.count > DetectionConfig.maxTrajectoryPoints {
            trajectoryPoints.removeFirst(trajectoryPoints.count - DetectionConfig.maxTrajectoryPoints)
        }

        // Update opacity for fade effect
        updateOpacities()

        isTrackingActive = true
    }

    // MARK: - State Management

    /// Clear all trajectory data
    func reset() {
        trajectoryPoints.removeAll()
        lastNormalizedPosition = nil
        isTrackingActive = false
    }

    /// Remove old points based on fade time
    func pruneOldPoints() {
        let now = CFAbsoluteTimeGetCurrent()
        trajectoryPoints.removeAll { point in
            now - point.timestamp > DetectionConfig.trajectoryFadeTime
        }
        if trajectoryPoints.isEmpty {
            isTrackingActive = false
        }
    }

    // MARK: - Private

    private func updateOpacities() {
        guard !trajectoryPoints.isEmpty else { return }
        let count = trajectoryPoints.count
        for i in 0..<count {
            // Linear fade: oldest = 0.3, newest = 1.0
            let ratio = CGFloat(i) / CGFloat(max(count - 1, 1))
            trajectoryPoints[i].opacity = 0.3 + 0.7 * ratio
        }
    }
}
