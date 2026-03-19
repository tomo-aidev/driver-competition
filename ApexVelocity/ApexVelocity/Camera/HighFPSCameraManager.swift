import AVFoundation
import CoreImage
import Combine

/// Phase 1: High FPS camera capture manager
/// Configures AVCaptureSession for maximum frame rate capture
/// and extracts CVPixelBuffer frames on a background queue.
final class HighFPSCameraManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentFPS: Double = 0
    @Published private(set) var configuredFPS: Double = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isSessionRunning = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var errorMessage: String?

    // MARK: - Capture Components

    let captureSession = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoDataOutput = AVCaptureVideoDataOutput()

    // MARK: - Background Queues

    /// Dedicated queue for session configuration — never block main thread
    private let sessionQueue = DispatchQueue(
        label: "com.apexvelocity.session",
        qos: .userInitiated
    )

    /// Dedicated queue for frame processing — separate from session config
    private let videoProcessingQueue = DispatchQueue(
        label: "com.apexvelocity.videoprocessing",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )

    // MARK: - FPS Measurement

    private var frameCount: Int = 0
    private var lastFPSUpdate: CFAbsoluteTime = 0
    private let fpsUpdateInterval: CFAbsoluteTime = 0.5

    // MARK: - Frame Buffer & Detection

    /// Latest pixel buffer — accessible for AI processing pipeline
    private(set) var latestPixelBuffer: CVPixelBuffer?

    /// Frame counter for recorded session
    private(set) var recordedFrameCount: Int = 0

    /// Ball detector for CoreML inference (injected externally)
    var ballDetector: BallDetector?

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - Permission

    func requestPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.permissionGranted = true }
            sessionQueue.async { self.configureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async { self.permissionGranted = granted }
                if granted {
                    self.sessionQueue.async { self.configureSession() }
                }
            }
        default:
            DispatchQueue.main.async {
                self.permissionGranted = false
                self.errorMessage = String(
                    localized: "camera_permission_denied",
                    defaultValue: "Camera access denied. Please enable in Settings."
                )
            }
        }
    }

    // MARK: - Session Configuration

    private func configureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .inputPriority

        // Select back wide-angle camera (best for golf shot capture)
        guard let videoDevice = bestCameraDevice() else {
            DispatchQueue.main.async {
                self.errorMessage = String(
                    localized: "camera_not_available",
                    defaultValue: "Camera not available on this device."
                )
            }
            captureSession.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                videoDeviceInput = input
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
            }
            captureSession.commitConfiguration()
            return
        }

        // Configure video data output for frame extraction
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: videoProcessingQueue)

        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }

        // Configure highest FPS
        configureHighestFPS(for: videoDevice)

        captureSession.commitConfiguration()

        // Start session
        captureSession.startRunning()
        DispatchQueue.main.async {
            self.isSessionRunning = self.captureSession.isRunning
        }
    }

    // MARK: - High FPS Configuration

    private func configureHighestFPS(for device: AVCaptureDevice) {
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRate: Float64 = 0

        // Find the format supporting the highest frame rate
        // Prefer formats with reasonable resolution (1080p+) for golf tracking
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

            // Skip formats below 720p height
            guard dimensions.height >= 720 else { continue }

            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate > bestFrameRate {
                    // Prefer 1080p or higher for quality
                    if dimensions.height >= 1080 || range.maxFrameRate >= 120 {
                        bestFrameRate = range.maxFrameRate
                        bestFormat = format
                    }
                }
            }
        }

        // Fallback: just find absolute highest FPS regardless of resolution
        if bestFormat == nil {
            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate > bestFrameRate {
                        bestFrameRate = range.maxFrameRate
                        bestFormat = format
                    }
                }
            }
        }

        guard let selectedFormat = bestFormat else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = selectedFormat
            device.activeVideoMinFrameDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(bestFrameRate)
            )
            device.activeVideoMaxFrameDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(bestFrameRate)
            )
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.configuredFPS = bestFrameRate
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Device Selection

    private func bestCameraDevice() -> AVCaptureDevice? {
        // Prefer back dual/triple camera for best quality
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )

        return discoverySession.devices.first
    }

    // MARK: - Recording Control

    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.recordedFrameCount = 0
            DispatchQueue.main.async {
                self.isRecording = true
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }

    // MARK: - Session Lifecycle

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.captureSession.isRunning
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension HighFPSCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Extract pixel buffer for future CoreML processing
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Store latest frame
        latestPixelBuffer = pixelBuffer

        // Count frames during recording
        if isRecording {
            recordedFrameCount += 1
        }

        // Update FPS measurement
        updateFPSMeasurement()

        // Submit frame for ball detection (non-blocking)
        ballDetector?.detect(pixelBuffer: pixelBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Frame was dropped — this is expected behavior when processing can't keep up.
        // alwaysDiscardsLateVideoFrames ensures we don't accumulate memory pressure.
    }

    private func updateFPSMeasurement() {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()

        if lastFPSUpdate == 0 {
            lastFPSUpdate = now
            return
        }

        let elapsed = now - lastFPSUpdate
        if elapsed >= fpsUpdateInterval {
            let measuredFPS = Double(frameCount) / elapsed
            frameCount = 0
            lastFPSUpdate = now

            DispatchQueue.main.async { [weak self] in
                self?.currentFPS = measuredFPS
            }
        }
    }
}
