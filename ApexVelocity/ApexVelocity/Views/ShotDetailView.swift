import SwiftUI
import AVKit

struct ShotDetailView: View {
    let shot: ShotRecord
    let shotStore: ShotStore
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    // Video player
                    if let player {
                        VideoPlayerLayer(player: player)
                            .ignoresSafeArea()
                    }

                    // Trajectory overlay
                    trajectoryOverlay(in: geo.size)

                    // Swing overlay
                    swingOverlay(in: geo.size)

                    // Top bar
                    VStack {
                        topBar
                        Spacer()
                    }

                    // Bottom metrics
                    VStack {
                        Spacer()
                        metricsBar
                    }
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            let url = shotStore.videoURL(for: shot)
            let avPlayer = AVPlayer(url: url)
            player = avPlayer

            // Loop
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                avPlayer.seek(to: .zero)
                avPlayer.play()
            }

            avPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.onSurface)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.surfaceContainerLowest.opacity(0.8))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Analysis status
            HStack(spacing: 6) {
                if shot.analysisStatus == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.primaryFixed)
                }
                Text(formattedDate)
                    .font(.custom("Inter-Medium", size: 12, relativeTo: .caption))
                    .foregroundStyle(AppTheme.onSurface)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(AppTheme.surfaceContainerLowest.opacity(0.8))
            .clipShape(Capsule())

            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Ball Trajectory Overlay

    private func trajectoryOverlay(in size: CGSize) -> some View {
        Canvas { context, _ in
            let points = shot.ballTrajectory
            guard points.count >= 2 else { return }

            let screenPoints = points.map {
                CGPoint(x: $0.x * size.width, y: $0.y * size.height)
            }

            // Draw trajectory line (red, with glow)
            var path = Path()
            path.move(to: screenPoints[0])

            for i in 1..<screenPoints.count {
                if screenPoints.count > 3 {
                    let p0 = screenPoints[max(i - 2, 0)]
                    let p1 = screenPoints[i - 1]
                    let p2 = screenPoints[i]
                    let p3 = screenPoints[min(i + 1, screenPoints.count - 1)]
                    let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                    let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                    path.addCurve(to: p2, control1: cp1, control2: cp2)
                } else {
                    path.addLine(to: screenPoints[i])
                }
            }

            // Glow
            context.stroke(path, with: .color(.red.opacity(0.3)),
                          style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            // Main line
            context.stroke(path, with: .color(.red),
                          style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            // Draw detected vs predicted segments differently
            for (i, pt) in points.enumerated() {
                let screenPt = screenPoints[i]
                if pt.isDetected {
                    // Detected: solid dot
                    let dotRect = CGRect(x: screenPt.x - 3, y: screenPt.y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.red))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Swing Overlay

    private func swingOverlay(in size: CGSize) -> some View {
        Canvas { context, _ in
            let swingPoints = shot.swingTrajectory
            guard swingPoints.count >= 2 else { return }

            let backswing = swingPoints.filter { $0.phase == "backswing" }
            let downswing = swingPoints.filter { $0.phase == "downswing" }

            drawSwingPath(context: context, points: backswing,
                         color: Color(red: 0.2, green: 0.5, blue: 1.0), size: size)
            drawSwingPath(context: context, points: downswing,
                         color: AppTheme.primaryFixed, size: size)
        }
        .allowsHitTesting(false)
    }

    private func drawSwingPath(context: GraphicsContext, points: [SwingPointRecord],
                                color: Color, size: CGSize) {
        guard points.count >= 2 else { return }
        var path = Path()
        let screenPoints = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        path.move(to: screenPoints[0])
        for i in 1..<screenPoints.count {
            path.addLine(to: screenPoints[i])
        }
        context.stroke(path, with: .color(color.opacity(0.3)),
                      style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(color),
                      style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Metrics Bar

    private var metricsBar: some View {
        VStack(spacing: 0) {
            // Gradient fade
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 60)

            // Row 1: Shot metrics
            HStack(spacing: 0) {
                if let impact = shot.impactTimeSeconds {
                    metricTile(
                        value: String(format: "%.2fs", impact),
                        label: "IMPACT",
                        icon: "bolt.fill",
                        color: AppTheme.secondary
                    )
                }

                if let metrics = shot.metrics {
                    if let angle = metrics.estimatedLaunchAngle {
                        metricTile(
                            value: String(format: "%.1f°", angle),
                            label: "LAUNCH",
                            icon: "arrow.up.right",
                            color: AppTheme.primaryFixed
                        )
                    }

                    metricTile(
                        value: String(format: "%.0f%%", metrics.analysisConfidence * 100),
                        label: "CONFIDENCE",
                        icon: "chart.bar.fill",
                        color: .cyan
                    )
                }
            }

            // Row 2: Body pose swing metrics
            if let sm = shot.swingMetrics {
                Divider().background(AppTheme.outlineVariant.opacity(0.3))
                    .padding(.horizontal, 16)

                HStack(spacing: 0) {
                    if let tempo = sm.tempoRatio {
                        metricTile(
                            value: String(format: "%.1f:1", tempo),
                            label: "TEMPO",
                            icon: "metronome.fill",
                            color: .orange
                        )
                    }

                    if let xFactor = sm.xFactor {
                        metricTile(
                            value: String(format: "%.0f°", xFactor),
                            label: "X-FACTOR",
                            icon: "arrow.triangle.2.circlepath",
                            color: .purple
                        )
                    }

                    if let spine = sm.spineAngleAtAddress {
                        metricTile(
                            value: String(format: "%.0f°", spine),
                            label: "SPINE",
                            icon: "figure.stand",
                            color: .mint
                        )
                    }

                    if let head = sm.headMovementTotal {
                        metricTile(
                            value: String(format: "%.2f", head),
                            label: "HEAD",
                            icon: "circle.dotted",
                            color: head < 0.05 ? .green : .yellow
                        )
                    }
                }
            }

            // Padding
            Color.clear.frame(height: 16)

            .padding(.horizontal, 16)
            .padding(.bottom, 40)
            .background(.black.opacity(0.7))
        }
    }

    private func metricTile(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)

            Text(value)
                .font(.custom("SpaceGrotesk-Bold", size: 18, relativeTo: .body))
                .foregroundStyle(AppTheme.onSurface)
                .monospacedDigit()

            Text(label)
                .font(.custom("Inter-Medium", size: 8, relativeTo: .caption2))
                .tracking(1.5)
                .foregroundStyle(AppTheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: shot.createdAt)
    }
}
