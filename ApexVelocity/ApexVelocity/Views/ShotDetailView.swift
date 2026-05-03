import SwiftUI
import AVKit

struct ShotDetailView: View {
    let shot: ShotRecord
    let shotStore: ShotStore
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var showKeyFrames = false
    @State private var selectedKeyFrameIndex: Int?
    @State private var savedToPhotos = false
    @State private var saveError: String?

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()

            if showKeyFrames {
                keyFrameGalleryView
            } else {
                GeometryReader { geo in
                    ZStack {
                        if let player {
                            VideoPlayerLayer(player: player).ignoresSafeArea()
                        }
                        // Trajectory and swing overlays removed (data shown in table below)

                        VStack {
                            topBar
                            Spacer()
                        }

                        VStack {
                            Spacer()
                            metricsBar
                        }
                    }
                }
            }

            // Full-screen key frame slideshow
            if selectedKeyFrameIndex != nil {
                keyFrameSlideshow
            }
        }
        .statusBarHidden(true)
        .onAppear {
            let url = shotStore.videoURL(for: shot)
            let avPlayer = AVPlayer(url: url)
            player = avPlayer
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

            // Key frames button
            if !shot.keyFrames.isEmpty {
                Button {
                    withAnimation { showKeyFrames.toggle() }
                    if showKeyFrames { player?.pause() } else { player?.play() }
                } label: {
                    Image(systemName: showKeyFrames ? "play.rectangle.fill" : "photo.stack.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.onSurface)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.surfaceContainerLowest.opacity(0.8))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Ball Trajectory Overlay

    private func trajectoryOverlay(in size: CGSize) -> some View {
        Canvas { context, _ in
            // Only show trajectory if we have DETECTED points (not just predicted)
            let allPoints = shot.ballTrajectory
            let detectedPoints = allPoints.filter { $0.isDetected }
            // If no detected points, don't show any trajectory (avoid showing fake predictions)
            guard detectedPoints.count >= 2 else { return }
            let points = allPoints

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

    // MARK: - Metrics Bar (Data Table + Save)

    private var metricsBar: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 40)

            VStack(spacing: 8) {
                // Row 1: Main metrics
                HStack(spacing: 0) {
                    if let metrics = shot.metrics {
                        if let hs = metrics.estimatedHeadSpeed {
                            metricTile(value: String(format: "%.0f", hs), label: "H/S (m/s)", icon: "gauge.with.dots.needle.33percent", color: .cyan)
                        }
                        if let angle = metrics.estimatedLaunchAngle {
                            metricTile(value: String(format: "%.1f°", angle), label: "ANGLE", icon: "arrow.up.right", color: .orange)
                        }
                        if let dir = metrics.estimatedLaunchDirection {
                            let dirStr = dir > 1 ? "R \(String(format: "%.0f°", dir))" : dir < -1 ? "L \(String(format: "%.0f°", abs(dir)))" : "STRAIGHT"
                            metricTile(value: dirStr, label: "DIRECTION", icon: "arrow.left.and.right", color: AppTheme.primaryFixed)
                        }
                        if let yards = metrics.estimatedCarryDistance {
                            metricTile(value: String(format: "%.0f", yards), label: "CARRY (y)", icon: "flag.fill", color: .green)
                        }
                    }
                }

                // Row 2: Impact + Swing metrics
                HStack(spacing: 0) {
                    if let impact = shot.impactTimeSeconds {
                        metricTile(value: String(format: "%.2fs", impact), label: "IMPACT", icon: "bolt.fill", color: AppTheme.secondary)
                    }
                    if let bs = shot.metrics?.estimatedBallSpeed {
                        metricTile(value: String(format: "%.0f", bs), label: "B/S (m/s)", icon: "sportscourt.fill", color: .yellow)
                    }
                    if let sm = shot.swingMetrics {
                        if let tempo = sm.tempoRatio {
                            metricTile(value: String(format: "%.1f:1", tempo), label: "TEMPO", icon: "metronome.fill", color: .purple)
                        }
                        if let xFactor = sm.xFactor {
                            metricTile(value: String(format: "%.0f°", xFactor), label: "X-FACTOR", icon: "arrow.triangle.2.circlepath", color: .mint)
                        }
                    }
                }

                // Save to Camera Roll button
                HStack(spacing: 12) {
                    Button {
                        saveVideoToCameraRoll()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: savedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                                .font(.system(size: 14))
                            Text(savedToPhotos ? "Saved" : "Save to Camera Roll")
                                .font(.custom("Inter-Medium", size: 12, relativeTo: .caption))
                        }
                        .foregroundStyle(savedToPhotos ? .green : AppTheme.onSurface)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(AppTheme.surfaceContainerHighest.opacity(0.6))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(savedToPhotos)

                    if let err = saveError {
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
            .background(.black.opacity(0.85))
        }
    }

    private func saveVideoToCameraRoll() {
        let url = shotStore.videoURL(for: shot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            saveError = "Video not found"
            return
        }
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
        withAnimation { savedToPhotos = true }
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

    // MARK: - Key Frame Gallery

    private var keyFrameGalleryView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    withAnimation { showKeyFrames = false }
                    player?.play()
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

                Text(String(localized: "key_frames_title", defaultValue: "Key Frames"))
                    .font(.custom("SpaceGrotesk-Bold", size: 18, relativeTo: .title3))
                    .foregroundStyle(AppTheme.onSurface)

                Spacer()

                Text("\(shot.keyFrames.count)")
                    .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                    .foregroundStyle(AppTheme.primaryFixed)
                    .frame(width: 40, height: 40)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Scrollable grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(Array(shot.keyFrames.enumerated()), id: \.offset) { index, kf in
                        keyFrameCard(kf, index: index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private func keyFrameCard(_ kf: KeyFrameRecord, index: Int) -> some View {
        let shotsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shots", isDirectory: true)
        let imageURL = shotsDir.appendingPathComponent(kf.imageFileName)

        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedKeyFrameIndex = index
            }
        } label: {
            VStack(spacing: 0) {
                // Thumbnail
                if let data = try? Data(contentsOf: imageURL),
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 200)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(AppTheme.surfaceContainerHighest)
                        .frame(height: 200)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 30))
                                .foregroundStyle(AppTheme.onSurfaceVariant.opacity(0.3))
                        }
                }

                // Label
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kf.label)
                            .font(.custom("Inter-Bold", size: 10, relativeTo: .caption2))
                            .foregroundStyle(AppTheme.onSurface)
                            .lineLimit(1)

                        Text(String(format: "%.2fs", kf.time))
                            .font(.custom("Inter-Regular", size: 9, relativeTo: .caption2))
                            .foregroundStyle(AppTheme.onSurfaceVariant)
                            .monospacedDigit()
                    }

                    Spacer()

                    if kf.ballX != nil {
                        Image(systemName: "scope")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.primaryFixed)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppTheme.surfaceContainerHighest)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppTheme.outlineVariant.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Key Frame Slideshow (horizontal swipe)

    private var keyFrameSlideshow: some View {
        let shotsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shots", isDirectory: true)

        return ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: Binding(
                get: { selectedKeyFrameIndex ?? 0 },
                set: { selectedKeyFrameIndex = $0 }
            )) {
                ForEach(Array(shot.keyFrames.enumerated()), id: \.offset) { index, kf in
                    let imageURL = shotsDir.appendingPathComponent(kf.imageFileName)

                    ZStack {
                        // Image
                        if let data = try? Data(contentsOf: imageURL),
                           let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .ignoresSafeArea()

                            // Ball marker overlay
                            if let bx = kf.ballX, let by = kf.ballY {
                                GeometryReader { geo in
                                    let cx = bx * geo.size.width
                                    let cy = by * geo.size.height
                                    Circle()
                                        .stroke(AppTheme.primaryFixed, lineWidth: 2)
                                        .frame(width: 30, height: 30)
                                        .position(x: cx, y: cy)

                                    Text("BALL")
                                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                                        .foregroundStyle(AppTheme.primaryFixed)
                                        .position(x: cx, y: cy + 22)
                                }
                            }
                        } else {
                            VStack {
                                Image(systemName: "photo")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.white.opacity(0.3))
                                Text("Image not found")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Top bar: close + counter
            VStack {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedKeyFrameIndex = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Page counter
                    Text("\((selectedKeyFrameIndex ?? 0) + 1) / \(shot.keyFrames.count)")
                        .font(.custom("Inter-Bold", size: 14, relativeTo: .body))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.15))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()
            }

            // Bottom info bar
            VStack {
                Spacer()

                let currentIndex = selectedKeyFrameIndex ?? 0
                if currentIndex < shot.keyFrames.count {
                    let kf = shot.keyFrames[currentIndex]
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kf.label)
                                .font(.custom("SpaceGrotesk-Bold", size: 18, relativeTo: .title3))
                                .foregroundStyle(.white)

                            Text(String(format: "%.2fs", kf.time))
                                .font(.custom("Inter-Medium", size: 14, relativeTo: .body))
                                .foregroundStyle(.white.opacity(0.7))
                                .monospacedDigit()
                        }

                        Spacer()

                        // Swipe hint
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("swipe")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(20)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.8)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
            }
        }
        .transition(.opacity)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: shot.createdAt)
    }
}
