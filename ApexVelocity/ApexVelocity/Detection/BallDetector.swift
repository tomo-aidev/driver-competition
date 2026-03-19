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

    // MARK: - Mock State

    private var mockStartTime: CFAbsoluteTime = 0
    private var mockPhase: MockPhase = .idle
    private var lastMockTrigger: CFAbsoluteTime = 0

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
            // Start a new flight every 4 seconds
            if now - lastMockTrigger > 4.0 {
                mockPhase = .flight
                mockStartTime = now
                lastMockTrigger = now
            }

        case .flight:
            let elapsed = now - mockStartTime
            let flightDuration: Double = 2.0

            if elapsed > flightDuration {
                mockPhase = .cooldown
                return
            }

            // Normalized time 0-1
            let t = elapsed / flightDuration

            // Parabolic arc: starts near bottom, arcs up and right
            let x = 0.3 + t * 0.5  // left to right
            let peakHeight: CGFloat = 0.35
            let y = 0.95 - (4.0 * peakHeight * t * (1.0 - t)) // starts just above record button area

            let detection = BallDetection(
                normalizedCenter: CGPoint(x: x, y: y),
                confidence: 0.95,
                boundingBox: CGRect(x: x - 0.01, y: y - 0.01, width: 0.02, height: 0.02),
                timestamp: now
            )

            DispatchQueue.main.async { [weak self] in
                self?.latestDetection = detection
            }

        case .cooldown:
            if now - mockStartTime > 3.0 {
                mockPhase = .idle
            }
        }
    }
}
