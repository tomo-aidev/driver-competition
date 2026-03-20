import AVFoundation
import CoreML
import Vision
import Combine

/// Manages CoreML/Vision-based golf ball detection.
/// When no .mlmodel is available, operates in mock mode with synthetic parabolic trajectory.
final class BallDetector: ObservableObject {

    // MARK: - Published State

    @Published private(set) var latestDetection: BallDetection?
    @Published private(set) var isModelLoaded = false

    // MARK: - Private State

    private var vnModel: VNCoreMLModel?
    private let inferenceQueue = DispatchQueue(
        label: "com.apexvelocity.inference",
        qos: .userInitiated
    )
    private let isProcessingLock = NSLock()
    private var _isProcessing = false
    private var isProcessing: Bool {
        get { isProcessingLock.withLock { _isProcessing } }
        set { isProcessingLock.withLock { _isProcessing = newValue } }
    }
    private let useMockDetections: Bool

    // MARK: - Ball Start Position

    /// Ball start position in SCREEN coordinates (pixels), set from UI
    var ballScreenPosition: CGPoint = CGPoint(x: 200, y: 600)
    /// Screen size for coordinate normalization
    var screenSize: CGSize = CGSize(width: 400, height: 800)

    // MARK: - Mock State

    private var mockStartTime: CFAbsoluteTime = 0
    private var mockPhase: MockPhase = .idle
    private var lastMockTrigger: CFAbsoluteTime = 0
    private var mockPatternIndex: Int = 0

    /// Shot patterns: (name, launchAngleDeg, curveDirection, distance)
    /// curveDirection: negative = draw/hook left, positive = fade/slice right, 0 = straight
    private let shotPatterns: [(angle: Double, curve: Double, label: String)] = [
        (75, 0.0, "Straight"),       // ストレート
        (70, -0.15, "Draw"),          // ドロー（左曲がり）
        (65, 0.2, "Fade"),            // フェード（右曲がり）
        (80, -0.25, "Hook"),          // フック（強い左曲がり）
        (60, 0.3, "Slice"),           // スライス（強い右曲がり）
        (85, 0.0, "High Straight"),   // 高弾道ストレート
    ]

    private enum MockPhase {
        case idle
        case flight
        case cooldown
    }

    // MARK: - Initialization

    init() {
        // Try to load a real model; fall back to mock if not found
        if let modelURL = Bundle.main.url(forResource: "GolfBallDetector", withExtension: "mlmodelc"),
           let mlModel = try? MLModel(contentsOf: modelURL),
           let vnModel = try? VNCoreMLModel(for: mlModel) {
            self.vnModel = vnModel
            self.useMockDetections = false
            self.isModelLoaded = true
        } else {
            self.vnModel = nil
            self.useMockDetections = true
            self.isModelLoaded = false
        }
    }

    // MARK: - Detection

    /// Submit a frame for ball detection. Non-blocking — skips if previous inference is still running.
    func detect(pixelBuffer: CVPixelBuffer) {
        guard !isProcessing else { return }
        isProcessing = true

        if useMockDetections {
            inferenceQueue.async { [weak self] in
                self?.runMockDetection()
                self?.isProcessing = false
            }
        } else {
            inferenceQueue.async { [weak self] in
                self?.runRealDetection(pixelBuffer: pixelBuffer)
                self?.isProcessing = false
            }
        }
    }

    /// Reset detector state (e.g., when recording stops)
    func reset() {
        inferenceQueue.async { [weak self] in
            self?.mockPhase = .idle
            self?.mockStartTime = 0
            DispatchQueue.main.async {
                self?.latestDetection = nil
            }
        }
    }

    // MARK: - Real CoreML Detection

    private func runRealDetection(pixelBuffer: CVPixelBuffer) {
        guard let vnModel else { return }

        let request = VNCoreMLRequest(model: vnModel) { [weak self] request, error in
            guard let self, error == nil else { return }
            self.processDetectionResults(request.results)
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func processDetectionResults(_ results: [Any]?) {
        guard let observations = results as? [VNRecognizedObjectObservation] else { return }

        // Find highest-confidence ball detection
        // YOLOv8 with COCO: "sports ball" class
        let ballObservation = observations
            .filter { $0.confidence >= DetectionConfig.minConfidence }
            .max(by: { $0.confidence < $1.confidence })

        guard let observation = ballObservation else { return }

        let bbox = observation.boundingBox
        let detection = BallDetection(
            normalizedCenter: CGPoint(
                x: bbox.midX,
                y: 1.0 - bbox.midY // Vision coordinates: origin at bottom-left
            ),
            confidence: observation.confidence,
            boundingBox: CGRect(
                x: bbox.origin.x,
                y: 1.0 - bbox.origin.y - bbox.height,
                width: bbox.width,
                height: bbox.height
            ),
            timestamp: CFAbsoluteTimeGetCurrent()
        )

        DispatchQueue.main.async { [weak self] in
            self?.latestDetection = detection
        }
    }

    // MARK: - Mock Detection (Parabolic Arc)

    private func runMockDetection() {
        let now = CFAbsoluteTimeGetCurrent()

        switch mockPhase {
        case .idle:
            if now - lastMockTrigger > 5.0 {
                mockPhase = .flight
                mockStartTime = now
                lastMockTrigger = now
                mockPatternIndex = (mockPatternIndex + 1) % shotPatterns.count
            }

        case .flight:
            let elapsed = now - mockStartTime
            let flightDuration: Double = 3.5

            if elapsed > flightDuration {
                mockPhase = .cooldown
                return
            }

            let t = CGFloat(elapsed / flightDuration) // 0-1
            let pattern = shotPatterns[mockPatternIndex]

            // Screen coordinates: ball starts at exact ball position
            let sx = ballScreenPosition.x
            let sy = ballScreenPosition.y
            let sw = screenSize.width
            let sh = screenSize.height

            // Landing point: same height as ball (sy), but further toward center (perspective)
            // Ball flies from start → up in arc → lands at ground level in the distance
            let landX = sx + (sw * 0.48 - sx) * 0.6  // lands partway toward center
            let landY = sy                             // same height = ground level

            // Midpoint in the air (vanishing direction)
            let midX = sx + (landX - sx) * 0.45
            let midY = sh * 0.30  // highest point of the arc base line

            // Curve: lateral deviation (hook/draw = left, fade/slice = right)
            let curveFactor = CGFloat(pattern.curve) * sw * 0.3
            let lateralOffset = curveFactor * t * t

            // Trajectory base: quadratic bezier from start → mid → land
            let baseX = (1 - t) * (1 - t) * sx + 2 * (1 - t) * t * midX + t * t * landX
            let baseY = (1 - t) * (1 - t) * sy + 2 * (1 - t) * t * midY + t * t * landY

            // Arc: additional height above the base bezier (the "lift" of the ball)
            // Peaks around t=0.35, zero at t=0 and t=1
            let launchRad = CGFloat(pattern.angle) * .pi / 180.0
            let maxArcHeight = sh * 0.15 * sin(launchRad)
            let arc = maxArcHeight * 4.0 * t * (1.0 - t) // simple parabola, zero at endpoints

            // Final screen position
            let finalX = baseX + lateralOffset
            let finalY = baseY - arc // negative = upward on screen

            // Convert to normalized for BallDetection (0-1)
            let normX = finalX / sw
            let normY = finalY / sh

            let detection = BallDetection(
                normalizedCenter: CGPoint(x: normX, y: normY),
                confidence: 0.95,
                boundingBox: CGRect(x: normX - 0.01, y: normY - 0.01, width: 0.02, height: 0.02),
                timestamp: now
            )

            DispatchQueue.main.async { [weak self] in
                self?.latestDetection = detection
            }

        case .cooldown:
            if now - mockStartTime > 5.0 {
                mockPhase = .idle
            }
        }
    }
}
