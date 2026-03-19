import SwiftUI

struct RecordingView: View {
    @ObservedObject var cameraManager: HighFPSCameraManager
    @ObservedObject var ballTracker: BallTracker

    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            // Camera Preview with trajectory overlay (full screen)
            if cameraManager.permissionGranted {
                CameraPreviewView(
                    session: cameraManager.captureSession,
                    trajectoryPoints: ballTracker.trajectoryPoints,
                    onPreviewLayerReady: { layer in
                        ballTracker.setPreviewLayer(layer)
                    }
                )
                .ignoresSafeArea()

                // Gradient overlays
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0.4), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 200)
                }
                .ignoresSafeArea()
            } else {
                cameraPermissionView
            }

            // Golfer guide overlay (center)
            GolferGuideOverlay(isRecording: cameraManager.isRecording)

            // Top bar
            VStack {
                topBar
                Spacer()
            }

            // Bottom controls
            VStack {
                Spacer()
                bottomControls
            }

            // FPS indicator (small, bottom-right corner, recording only)
            if cameraManager.isRecording {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        fpsIndicatorCompact
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 140)
                .transition(.opacity)
            }
        }
        .onAppear {
            cameraManager.requestPermission()
        }
        .onDisappear {
            stopTimer()
        }
    }

    // MARK: - Camera Permission View

    private var cameraPermissionView: some View {
        ZStack {
            AppTheme.surface
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(AppTheme.onSurfaceVariant)

                if let error = cameraManager.errorMessage {
                    Text(error)
                        .font(.custom("Inter-Regular", size: 14, relativeTo: .body))
                        .foregroundStyle(AppTheme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                } else {
                    Text(String(localized: "camera_requesting", defaultValue: "Requesting camera access..."))
                        .font(.custom("Inter-Regular", size: 14, relativeTo: .body))
                        .foregroundStyle(AppTheme.onSurfaceVariant)
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Hamburger menu
            iconButton(systemName: "line.3.horizontal") {
                // Menu action (future)
            }
            .accessibilityLabel(String(localized: "menu", defaultValue: "Menu"))

            Spacer()

            // Timer display
            timerDisplay

            Spacer()

            // Settings gear
            iconButton(systemName: "gearshape.fill") {
                // Settings action (future)
            }
            .accessibilityLabel(String(localized: "settings", defaultValue: "Settings"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AppTheme.primaryFixed)
                .frame(width: 40, height: 40)
                .background(AppTheme.surfaceContainerHighest.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var timerDisplay: some View {
        HStack(spacing: 8) {
            if cameraManager.isRecording {
                Circle()
                    .fill(AppTheme.secondary)
                    .frame(width: 8, height: 8)
                    .modifier(PulseModifier())
            }

            Text(formattedTime)
                .font(.custom("SpaceGrotesk-Bold", size: 24, relativeTo: .title2))
                .tracking(3)
                .foregroundStyle(AppTheme.onSurface)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
            AppTheme.surfaceContainerLowest.opacity(0.8)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(AppTheme.outlineVariant.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(alignment: .bottom) {
            // Album button (left)
            albumButton

            Spacer()

            // Record button (center)
            recordButton

            Spacer()

            // Frame count (right, during recording)
            if cameraManager.isRecording {
                frameCounter
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Color.clear.frame(width: 64, height: 64)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
        .animation(.easeInOut(duration: 0.3), value: cameraManager.isRecording)
    }

    private var albumButton: some View {
        Button {
            // Album action (future)
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppTheme.outlineVariant.opacity(0.3), lineWidth: 2)
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 24))
                            .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.6))
                    }

                Text(String(localized: "album", defaultValue: "Album"))
                    .font(.custom("Inter-Medium", size: 9, relativeTo: .caption2))
                    .tracking(1)
                    .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "album", defaultValue: "Album"))
    }

    private var recordButton: some View {
        Button {
            if cameraManager.isRecording {
                cameraManager.stopRecording()
                stopTimer()
                // Keep trajectory visible briefly before clearing
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    ballTracker.reset()
                    cameraManager.ballDetector?.reset()
                }
            } else {
                ballTracker.reset()
                cameraManager.ballDetector?.reset()
                cameraManager.startRecording()
                startTimer()
            }
        } label: {
            ZStack {
                // Outer ring glow
                Circle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 88, height: 88)
                    .blur(radius: 4)

                // Outer ring
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 80, height: 80)

                // Inner shape
                Group {
                    if cameraManager.isRecording {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppTheme.error)
                            .frame(width: 32, height: 32)
                            .shadow(color: AppTheme.error.opacity(0.5), radius: 10)
                    } else {
                        Circle()
                            .fill(AppTheme.error)
                            .frame(width: 56, height: 56)
                            .shadow(color: AppTheme.error.opacity(0.5), radius: 10)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: cameraManager.isRecording)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            cameraManager.isRecording
                ? String(localized: "stop_recording", defaultValue: "Stop Recording")
                : String(localized: "start_recording", defaultValue: "Start Recording")
        )
    }

    private var frameCounter: some View {
        VStack(spacing: 4) {
            Text("\(cameraManager.recordedFrameCount)")
                .font(.custom("SpaceGrotesk-Bold", size: 18, relativeTo: .body))
                .foregroundStyle(AppTheme.primaryFixed)
                .monospacedDigit()

            Text(String(localized: "frames_label", defaultValue: "FRAMES"))
                .font(.custom("Inter-Medium", size: 9, relativeTo: .caption2))
                .tracking(2)
                .foregroundStyle(AppTheme.onSurfaceVariant)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Compact FPS Indicator

    private var fpsIndicatorCompact: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(fpsColor)
                .frame(width: 6, height: 6)

            Text("\(Int(cameraManager.currentFPS))")
                .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .caption))
                .foregroundStyle(AppTheme.onSurface)

            Text("FPS")
                .font(.custom("Inter-Medium", size: 8, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(AppTheme.onSurfaceVariant)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private var fpsColor: Color {
        if cameraManager.currentFPS >= cameraManager.configuredFPS * 0.9 {
            return AppTheme.primaryFixed
        } else if cameraManager.currentFPS >= cameraManager.configuredFPS * 0.5 {
            return AppTheme.secondary
        } else {
            return AppTheme.error
        }
    }

    private var formattedTime: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func startTimer() {
        elapsedTime = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsedTime += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsedTime = 0
    }
}

// MARK: - Pulse Modifier

private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.0)
                    .repeatForever(autoreverses: true)
                ) {
                    isPulsing = true
                }
            }
    }
}
