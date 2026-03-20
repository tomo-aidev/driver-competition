import SwiftUI
import AVKit

struct AnalysisView: View {
    @ObservedObject var shotStore: ShotStore
    @StateObject private var analyzer = VideoAnalyzer()
    @StateObject private var postAnalyzer = PostProcessAnalyzer()
    @State private var showPicker = false
    @State private var selectedVideoURL: URL?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            AppTheme.surface
                .ignoresSafeArea()

            if let url = selectedVideoURL, player != nil {
                // Video playing + analysis overlay
                videoAnalysisView(url: url)
            } else {
                emptyStateView
            }
        }
        .sheet(isPresented: $showPicker) {
            VideoPicker(selectedVideoURL: $selectedVideoURL)
        }
        .onChange(of: selectedVideoURL) { _, newURL in
            if let url = newURL {
                let avPlayer = AVPlayer(url: url)
                player = avPlayer
                avPlayer.play()
                analyzer.analyze(videoURL: url, player: avPlayer)

                // Also save to ShotStore and run post-processing
                Task { @MainActor in
                    do {
                        var record = try await shotStore.saveShot(from: url)
                        await postAnalyzer.analyze(
                            videoURL: shotStore.videoURL(for: record),
                            record: &record
                        )
                        shotStore.updateShot(record)
                    } catch {
                        print("[Analysis] Save failed: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            Button { showPicker = true } label: {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        AppTheme.outlineVariant.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .frame(width: 200, height: 160)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 40))
                                .foregroundStyle(AppTheme.primaryFixed)
                            Text(String(localized: "select_video", defaultValue: "Select Video"))
                                .font(.custom("SpaceGrotesk-Bold", size: 16, relativeTo: .body))
                                .foregroundStyle(AppTheme.primaryFixed)
                        }
                    }
            }
            .buttonStyle(.plain)

            Text(String(localized: "analysis_description",
                         defaultValue: "Upload a golf swing video to analyze the ball trajectory"))
                .font(.custom("Inter-Regular", size: 13, relativeTo: .caption))
                .foregroundStyle(AppTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Video + Analysis Overlay

    private func videoAnalysisView(url: URL) -> some View {
        GeometryReader { geo in
            ZStack {
                // Video player
                if let player {
                    VideoPlayerLayer(player: player)
                        .ignoresSafeArea()
                }

                // Swing trajectory overlay (blue=backswing, green=downswing)
                if analyzer.swingAnalyzed {
                    swingTrajectoryOverlay(in: geo.size)
                }

                // Ball marker
                if analyzer.ballDetected, let loc = analyzer.ballLocation {
                    ballMarker(position: loc.position, in: geo.size)
                }

                // Impact flash
                if analyzer.showImpactFlash {
                    impactFlashOverlay
                        .transition(.opacity)
                }

                // Status message (top)
                VStack {
                    statusBar
                    Spacer()
                }

                // Bottom controls
                VStack {
                    Spacer()
                    bottomBar
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: analyzer.ballDetected)
        .animation(.easeInOut(duration: 0.2), value: analyzer.showImpactFlash)
    }

    // MARK: - Swing Trajectory

    private func swingTrajectoryOverlay(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let detections = analyzer.swingDetections

            // Separate backswing and downswing points
            let backswing = detections.filter { $0.phase == .backswing }
            let downswing = detections.filter { $0.phase == .downswing }

            // Draw backswing (blue)
            drawSwingPath(context: context, detections: backswing,
                         color: Color(red: 0.2, green: 0.5, blue: 1.0), // blue
                         size: size, lineWidth: 4)

            // Draw downswing (green)
            drawSwingPath(context: context, detections: downswing,
                         color: AppTheme.primaryFixed, // neon green
                         size: size, lineWidth: 4)
        }
        .allowsHitTesting(false)
    }

    private func drawSwingPath(context: GraphicsContext, detections: [ClubHeadDetection],
                                color: Color, size: CGSize, lineWidth: CGFloat) {
        guard detections.count >= 2 else { return }

        var path = Path()
        let points = detections.map { CGPoint(x: $0.position.x * size.width, y: $0.position.y * size.height) }

        path.move(to: points[0])
        for i in 1..<points.count {
            if points.count > 3 {
                let p0 = points[max(i - 2, 0)]
                let p1 = points[i - 1]
                let p2 = points[i]
                let p3 = points[min(i + 1, points.count - 1)]
                let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: cp1, control2: cp2)
            } else {
                path.addLine(to: points[i])
            }
        }

        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

        // Glow effect
        context.stroke(path, with: .color(color.opacity(0.3)), style: StrokeStyle(lineWidth: lineWidth + 6, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Ball Marker

    private func ballMarker(position: CGPoint, in size: CGSize) -> some View {
        let x = position.x * size.width
        let y = position.y * size.height

        return ZStack {
            // Crosshair circle
            Circle()
                .stroke(AppTheme.primaryFixed, lineWidth: 2)
                .frame(width: 40, height: 40)

            // Crosshair lines
            Group {
                Rectangle().frame(width: 1, height: 16)
                Rectangle().frame(width: 16, height: 1)
            }
            .foregroundStyle(AppTheme.primaryFixed.opacity(0.6))

            // Center dot
            Circle()
                .fill(AppTheme.primaryFixed)
                .frame(width: 4, height: 4)

            // Label
            Text("BALL")
                .font(.custom("Inter-Bold", size: 8, relativeTo: .caption2))
                .tracking(2)
                .foregroundStyle(AppTheme.primaryFixed)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.surfaceContainerLowest.opacity(0.8))
                .clipShape(Capsule())
                .offset(y: 28)
        }
        .position(x: x, y: y)
    }

    // MARK: - Impact Flash

    private var impactFlashOverlay: some View {
        ZStack {
            // Subtle screen flash
            Color.white.opacity(0.1)
                .ignoresSafeArea()

            // Impact badge
            VStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(AppTheme.secondary)

                Text("IMPACT")
                    .font(.custom("SpaceGrotesk-Bold", size: 24, relativeTo: .title2))
                    .tracking(4)
                    .foregroundStyle(AppTheme.secondary)

                if let time = analyzer.impactTime {
                    Text(String(format: "%.2fs", time))
                        .font(.custom("SpaceGrotesk-Bold", size: 18, relativeTo: .body))
                        .foregroundStyle(AppTheme.onSurface)
                        .monospacedDigit()
                }
            }
            .padding(24)
            .background(AppTheme.surfaceContainerLowest.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            if !analyzer.statusMessage.isEmpty {
                HStack(spacing: 8) {
                    if !analyzer.ballDetected || !analyzer.impactDetected {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.primaryFixed))
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.primaryFixed)
                    }

                    Text(analyzer.statusMessage)
                        .font(.custom("Inter-Medium", size: 12, relativeTo: .caption))
                        .foregroundStyle(AppTheme.onSurface)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppTheme.surfaceContainerLowest.opacity(0.8))
                .clipShape(Capsule())
            }
        }
        .padding(.top, 16)
        .animation(.easeInOut, value: analyzer.statusMessage)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // New video button
            Button {
                player?.pause()
                player = nil
                analyzer.reset()
                selectedVideoURL = nil
                showPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 14))
                    Text(String(localized: "select_other", defaultValue: "Other Video"))
                        .font(.custom("Inter-Medium", size: 12, relativeTo: .caption))
                }
                .foregroundStyle(AppTheme.primaryFixed)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppTheme.surfaceContainerLowest.opacity(0.8))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            // Results summary
            if analyzer.impactDetected, let time = analyzer.impactTime {
                HStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Text(String(format: "%.2fs", time))
                            .font(.custom("SpaceGrotesk-Bold", size: 16, relativeTo: .body))
                            .foregroundStyle(AppTheme.primaryFixed)
                            .monospacedDigit()
                        Text("IMPACT")
                            .font(.custom("Inter-Medium", size: 8, relativeTo: .caption2))
                            .tracking(1)
                            .foregroundStyle(AppTheme.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(AppTheme.surfaceContainerLowest.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }
}

// MARK: - Video Player Layer (simple AVPlayerLayer wrapper)

struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill

        // Loop
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }

        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
