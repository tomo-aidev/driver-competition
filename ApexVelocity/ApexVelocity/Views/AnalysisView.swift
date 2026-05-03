import SwiftUI
import AVKit
import Combine

struct AnalysisView: View {
    @ObservedObject var shotStore: ShotStore
    @StateObject private var analyzer = VideoAnalyzer()
    @StateObject private var postAnalyzer = PostProcessAnalyzer()
    @State private var showPicker = false
    @State private var selectedVideoURL: URL?
    @State private var player: AVPlayer?
    @State private var analysisComplete = false

    // Ball marker — updated by SwiftUI Timer
    @State private var ballMarkerPosition: CGPoint?
    @State private var ballMarkerOpacity: Double = 0
    @State private var currentPlaybackTime: Double = 0


    // SwiftUI-native timer (fires on main thread, updates @State correctly)
    private let playbackTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()

            if let url = selectedVideoURL {
                if analysisComplete, player != nil {
                    videoAnalysisView(url: url)
                } else {
                    analysisLoadingView
                }
            } else {
                emptyStateView
            }
        }
        .sheet(isPresented: $showPicker) {
            VideoPicker(selectedVideoURL: $selectedVideoURL)
        }
        .onChange(of: selectedVideoURL) { _, newURL in
            if let url = newURL { startAnalysis(url: url) }
        }
        // MARK: - Playback Timer (SwiftUI native)
        .onReceive(playbackTimer) { _ in
            guard analysisComplete, let player else { return }

            let time = CMTimeGetSeconds(player.currentTime())
            currentPlaybackTime = time

            // Look up ball position from analyzer's timeline
            if let result = analyzer.ballPosition(at: time) {
                ballMarkerPosition = result.position
                ballMarkerOpacity = result.opacity
            } else {
                ballMarkerPosition = nil
                ballMarkerOpacity = 0
            }
        }
    }

    // MARK: - Start Analysis

    private func startAnalysis(url: URL) {
        analysisComplete = false
        ballMarkerPosition = nil
        ballMarkerOpacity = 0

        let avPlayer = AVPlayer(url: url)
        avPlayer.pause()
        player = avPlayer

        // Use target frame position as known ball position (same as recording screen)
        // Target frame is at x=0.5, y=0.72 (bottom center)
        analyzer.knownBallPosition = CGPoint(x: 0.5, y: 0.72)

        analyzer.analyze(videoURL: url) {
            DispatchQueue.main.async {
                analysisComplete = true
                avPlayer.seek(to: .zero)
                avPlayer.play()
            }
        }

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

    // MARK: - Video + Overlay

    private func videoAnalysisView(url: URL) -> some View {
        GeometryReader { geo in
            ZStack {
                if let player {
                    VideoPlayerLayer(player: player).ignoresSafeArea()
                }

                // Ball marker
                if let pos = ballMarkerPosition, ballMarkerOpacity > 0.05 {
                    ballMarkerView(position: pos, in: geo.size)
                        .opacity(ballMarkerOpacity)
                }

                // Swing trajectory overlay removed

                // Ball trajectory animation (post-impact)
                if let trajectory = analyzer.trajectoryResult,
                   let impact = analyzer.impactTime {
                    TrajectoryAnimationView(
                        trajectoryPoints: trajectory.points,
                        impactTime: impact,
                        currentTime: currentPlaybackTime,
                        viewSize: geo.size
                    )
                }

                // Debug overlay
                debugOverlay(in: geo.size)

                VStack {
                    statusBar
                    Spacer()
                    bottomBar
                }
            }
        }
    }

    // MARK: - Ball Marker

    private func ballMarkerView(position: CGPoint, in size: CGSize) -> some View {
        let x = position.x * size.width
        let y = position.y * size.height

        return ZStack {
            Circle()
                .stroke(AppTheme.primaryFixed, lineWidth: 2)
                .frame(width: 40, height: 40)

            Group {
                Rectangle().frame(width: 1, height: 16)
                Rectangle().frame(width: 16, height: 1)
            }
            .foregroundStyle(AppTheme.primaryFixed.opacity(0.6))

            Circle()
                .fill(AppTheme.primaryFixed)
                .frame(width: 4, height: 4)

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

    // MARK: - Swing Trajectory

    private func swingTrajectoryOverlay(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            // Only show detections up to current playback time
            let visibleDetections = analyzer.swingDetections.filter {
                $0.frameTime <= currentPlaybackTime
            }

            let backswing = visibleDetections.filter { $0.phase == .backswing }
            let downswing = visibleDetections.filter { $0.phase == .downswing }

            // Backswing: blue
            drawSwingPath(context: context, detections: backswing,
                         color: Color(red: 0.3, green: 0.6, blue: 1.0), canvasSize: canvasSize)
            // Downswing: green
            drawSwingPath(context: context, detections: downswing,
                         color: Color(red: 0.2, green: 1.0, blue: 0.3), canvasSize: canvasSize)

            // Club head dot at current position (latest visible detection)
            if let latest = visibleDetections.last {
                let pt = CGPoint(
                    x: latest.position.x * canvasSize.width,
                    y: latest.position.y * canvasSize.height
                )
                // Outer glow
                context.fill(
                    Path(ellipseIn: CGRect(x: pt.x - 8, y: pt.y - 8, width: 16, height: 16)),
                    with: .color(Color.white.opacity(0.4))
                )
                // Inner dot
                let dotColor: Color = latest.phase == .backswing ?
                    Color(red: 0.3, green: 0.6, blue: 1.0) :
                    Color(red: 0.2, green: 1.0, blue: 0.3)
                context.fill(
                    Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                    with: .color(dotColor)
                )
            }
        }
    }

    private func drawSwingPath(context: GraphicsContext, detections: [ClubHeadDetection],
                                color: Color, canvasSize: CGSize) {
        guard detections.count >= 2 else { return }
        var path = Path()
        let points = detections.map {
            CGPoint(x: $0.position.x * canvasSize.width, y: $0.position.y * canvasSize.height)
        }
        path.move(to: points[0])
        for i in 1..<points.count { path.addLine(to: points[i]) }

        // Glow
        context.stroke(path, with: .color(color.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        // Core line
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Debug

    private func debugOverlay(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("DEBUG").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.red)
            Text("time: \(String(format: "%.2f", currentPlaybackTime))s")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.yellow)
            if let pos = ballMarkerPosition {
                Text("ball: (\(String(format: "%.3f", pos.x)), \(String(format: "%.3f", pos.y)))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.green)
            } else {
                Text("ball: hidden")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray)
            }
            Text("opacity: \(String(format: "%.2f", ballMarkerOpacity))")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.cyan)
            Text("timeline: \(analyzer.ballTimeline.count) entries")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.orange)
            Text("impact: \(String(format: "%.2f", analyzer.impactTime ?? 0))s")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white)
        }
        .padding(8)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .position(x: 120, y: 150)
    }

    // MARK: - Analysis Loading

    private var analysisLoadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle().stroke(AppTheme.outlineVariant.opacity(0.2), lineWidth: 4).frame(width: 80, height: 80)
                Circle().trim(from: 0, to: 0.7)
                    .stroke(AppTheme.primaryFixed, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 80, height: 80).rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: analysisComplete)
                Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 28)).foregroundStyle(AppTheme.primaryFixed)
            }

            Text(String(localized: "analyzing_video", defaultValue: "Analyzing Video..."))
                .font(.custom("SpaceGrotesk-Bold", size: 22, relativeTo: .title3)).foregroundStyle(AppTheme.onSurface)

            if !analyzer.statusMessage.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: AppTheme.primaryFixed)).scaleEffect(0.7)
                    Text(analyzer.statusMessage).font(.custom("Inter-Medium", size: 14, relativeTo: .body)).foregroundStyle(AppTheme.onSurfaceVariant)
                }.transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 12) {
                stageRow(done: analyzer.impactDetected, text: String(localized: "stage_impact", defaultValue: "Detect impact sound"))
                stageRow(done: analyzer.ballDetected, text: String(localized: "stage_ball", defaultValue: "Detect golf ball position"))
                stageRow(done: analyzer.swingAnalyzed, text: String(localized: "stage_swing", defaultValue: "Analyze swing trajectory"))
                stageRow(done: analyzer.ballTimelineReady, text: String(localized: "stage_tracking", defaultValue: "Build ball timeline"))
            }
            .padding(.horizontal, 40).padding(.top, 16)

            Spacer()

            Button { resetAll() } label: {
                Text(String(localized: "cancel", defaultValue: "Cancel"))
                    .font(.custom("Inter-Medium", size: 14, relativeTo: .body)).foregroundStyle(AppTheme.onSurfaceVariant)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(AppTheme.surfaceContainerHighest.opacity(0.5)).clipShape(Capsule())
            }.buttonStyle(.plain).padding(.bottom, 40)
        }
        .animation(.easeInOut(duration: 0.3), value: analyzer.statusMessage)
        .animation(.easeInOut(duration: 0.3), value: analyzer.ballDetected)
        .animation(.easeInOut(duration: 0.3), value: analyzer.impactDetected)
        .animation(.easeInOut(duration: 0.3), value: analyzer.swingAnalyzed)
        .animation(.easeInOut(duration: 0.3), value: analyzer.ballTimelineReady)
    }

    private func stageRow(done: Bool, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                .foregroundStyle(done ? AppTheme.primaryFixed : AppTheme.onSurfaceVariant.opacity(0.4))
            Text(text).font(.custom("Inter-Regular", size: 14, relativeTo: .body))
                .foregroundStyle(done ? AppTheme.onSurface : AppTheme.onSurfaceVariant.opacity(0.6))
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()
            Button { showPicker = true } label: {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(AppTheme.outlineVariant.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(width: 200, height: 160)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(AppTheme.primaryFixed)
                            Text(String(localized: "select_video", defaultValue: "Select Video"))
                                .font(.custom("SpaceGrotesk-Bold", size: 16, relativeTo: .body)).foregroundStyle(AppTheme.primaryFixed)
                        }
                    }
            }.buttonStyle(.plain)

            Text(String(localized: "analysis_description", defaultValue: "Upload a golf swing video to analyze the ball trajectory"))
                .font(.custom("Inter-Regular", size: 13, relativeTo: .caption)).foregroundStyle(AppTheme.onSurfaceVariant)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Status & Bottom Bar

    private var statusBar: some View {
        HStack {
            if !analyzer.statusMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(AppTheme.primaryFixed)
                    Text(analyzer.statusMessage).font(.custom("Inter-Medium", size: 12, relativeTo: .caption)).foregroundStyle(AppTheme.onSurface)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(AppTheme.surfaceContainerLowest.opacity(0.8)).clipShape(Capsule())
            }
        }.padding(.top, 16)
    }

    private var bottomBar: some View {
        HStack {
            Button { resetAll(); showPicker = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.system(size: 14))
                    Text(String(localized: "select_other", defaultValue: "Other Video"))
                        .font(.custom("Inter-Medium", size: 12, relativeTo: .caption))
                }.foregroundStyle(AppTheme.primaryFixed)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(AppTheme.surfaceContainerLowest.opacity(0.8)).clipShape(Capsule())
            }.buttonStyle(.plain)

            Spacer()

            if analyzer.impactDetected, let time = analyzer.impactTime {
                HStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Text(String(format: "%.2fs", time))
                            .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                            .foregroundStyle(AppTheme.primaryFixed).monospacedDigit()
                        Text("IMPACT").font(.custom("Inter-Medium", size: 7, relativeTo: .caption2))
                            .tracking(1).foregroundStyle(AppTheme.onSurfaceVariant)
                    }

                    if let metrics = postAnalyzer.status == .completed ? postAnalyzer.lastMetrics : nil {
                        if let hs = metrics.estimatedHeadSpeed {
                            VStack(spacing: 2) {
                                Text(String(format: "%.0f", hs))
                                    .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                                    .foregroundStyle(.cyan).monospacedDigit()
                                Text("m/s").font(.custom("Inter-Medium", size: 7, relativeTo: .caption2))
                                    .foregroundStyle(AppTheme.onSurfaceVariant)
                            }
                        }
                        if let angle = metrics.estimatedLaunchAngle {
                            VStack(spacing: 2) {
                                Text(String(format: "%.0f°", angle))
                                    .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                                    .foregroundStyle(.orange).monospacedDigit()
                                Text("ANGLE").font(.custom("Inter-Medium", size: 7, relativeTo: .caption2))
                                    .foregroundStyle(AppTheme.onSurfaceVariant)
                            }
                        }
                        if let yards = metrics.estimatedCarryDistance {
                            VStack(spacing: 2) {
                                Text(String(format: "%.0fy", yards))
                                    .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                                    .foregroundStyle(AppTheme.primaryFixed).monospacedDigit()
                                Text("CARRY").font(.custom("Inter-Medium", size: 7, relativeTo: .caption2))
                                    .foregroundStyle(AppTheme.onSurfaceVariant)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(AppTheme.surfaceContainerLowest.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }.padding(.horizontal, 16).padding(.bottom, 20)
    }

    private func resetAll() {
        player?.pause()
        player = nil
        analyzer.reset()
        selectedVideoURL = nil
        analysisComplete = false
        ballMarkerPosition = nil
        ballMarkerOpacity = 0
        currentPlaybackTime = 0
    }
}

// MARK: - Video Player Layer

struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
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
