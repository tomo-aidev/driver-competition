import SwiftUI
import AVKit
import AVFoundation

/// Dedicated menu for generating trail-baked videos.
/// Flow: Pick video → Auto-analyze → Preview → Export to camera roll
struct TrailExportView: View {

    @StateObject private var analyzer = VideoAnalyzer()
    @State private var showPicker = false
    @State private var pickedURL: URL?  // pickerが書き込む先（一時）
    @State private var sourceVideoURL: URL?  // 解析対象（トリミング済み）
    @State private var player: AVPlayer?

    // Trim flow
    @State private var pendingVideo: PendingVideoItem?
    struct PendingVideoItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    // Analysis state
    @State private var analysisStage: Stage = .empty

    enum Stage {
        case empty
        case analyzing
        case ready          // analyzed, ready to export
        case exporting
        case exported
    }

    // Trail data
    @State private var clubTrail: [ClubTrailRenderer.TrailPoint] = []
    @State private var snapshots: [ClubTrailRenderer.DetectionSnapshot] = []
    @State private var showSnapshotGallery = false

    // Export state
    @State private var exportProgress: Double = 0
    @State private var exportedVideoURL: URL?
    @State private var showExportAlert = false
    @State private var exportAlertMessage = ""
    @State private var saveSuccess = false

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                if analysisStage == .empty {
                    emptyState
                } else {
                    contentArea
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            VideoPicker(selectedVideoURL: $pickedURL)
        }
        .onChange(of: pickedURL) { _, newURL in
            guard let url = newURL else { return }
            // 一旦クリア + 遅延でcover表示
            pickedURL = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pendingVideo = PendingVideoItem(url: url)
            }
        }
        .fullScreenCover(item: $pendingVideo) { item in
            VideoTrimView(
                sourceURL: item.url,
                onConfirm: { start, end in
                    let url = item.url
                    pendingVideo = nil
                    Task { await startAnalysisWithTrim(sourceURL: url, start: start, end: end) }
                },
                onCancel: {
                    pendingVideo = nil
                }
            )
        }
        .sheet(isPresented: $showSnapshotGallery) {
            SnapshotGalleryView(snapshots: snapshots)
        }
        .alert(saveSuccess ? "✅ 完了" : "Export", isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
            if exportedVideoURL != nil && !saveSuccess {
                Button("カメラロールに保存") {
                    if let url = exportedVideoURL {
                        saveToCameraRoll(url: url)
                    }
                }
            }
        } message: {
            Text(exportAlertMessage)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trail Maker")
                    .font(.custom("SpaceGrotesk-Bold", size: 22, relativeTo: .title2))
                    .foregroundStyle(AppTheme.primaryFixed)
                Text("クラブ軌跡 + 弾道を動画に焼き込み")
                    .font(.custom("Inter-Medium", size: 11, relativeTo: .caption))
                    .foregroundStyle(AppTheme.onSurfaceVariant)
            }
            Spacer()
            if analysisStage != .empty && analysisStage != .exporting {
                Button {
                    resetAll()
                    showPicker = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18))
                        .foregroundStyle(AppTheme.primaryFixed)
                        .padding(8)
                        .background(AppTheme.surfaceContainerLowest.opacity(0.8))
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(AppTheme.primaryFixed.opacity(0.1))
                    .frame(width: 140, height: 140)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 56))
                    .foregroundStyle(AppTheme.primaryFixed)
            }

            VStack(spacing: 8) {
                Text("ゴルフ動画から残像動画を生成")
                    .font(.custom("SpaceGrotesk-Bold", size: 18, relativeTo: .title3))
                    .foregroundStyle(.white)

                Text("クラブヘッドの軌跡（青→緑→黄）と\nボールの弾道（赤）を動画に焼き込みます")
                    .font(.custom("Inter-Medium", size: 13, relativeTo: .body))
                    .foregroundStyle(AppTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Spacer()

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 16))
                    Text("動画を選択")
                        .font(.custom("Inter-Bold", size: 15, relativeTo: .body))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(AppTheme.primaryFixed)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer().frame(height: 80)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Content Area

    private var contentArea: some View {
        VStack(spacing: 0) {
            // Video preview
            ZStack {
                Color.black

                if let player {
                    VideoPlayerLayer(player: player)
                        .aspectRatio(9/16, contentMode: .fit)
                }

                if analysisStage == .analyzing {
                    analyzingOverlay
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)

            // Bottom action panel
            actionPanel
        }
    }

    // MARK: - Analyzing Overlay

    private var analyzingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.primaryFixed))
                .scaleEffect(1.6)

            Text(analyzer.statusMessage)
                .font(.custom("Inter-Medium", size: 13, relativeTo: .body))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                analysisStep("インパクト検出", done: analyzer.impactDetected)
                analysisStep("ボール位置検出", done: analyzer.ballDetected)
                analysisStep("クラブ軌跡計算", done: !clubTrail.isEmpty)
            }
            .padding(16)
            .background(.black.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
    }

    private func analysisStep(_ label: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AppTheme.primaryFixed : .gray)
            Text(label)
                .font(.custom("Inter-Medium", size: 12, relativeTo: .caption))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Action Panel

    private var actionPanel: some View {
        VStack(spacing: 12) {
            // Info row
            if analyzer.impactDetected, let impact = analyzer.impactTime {
                HStack(spacing: 16) {
                    infoChip(label: "IMPACT", value: String(format: "%.2fs", impact), color: AppTheme.primaryFixed)
                    infoChip(label: "クラブ点数", value: "\(clubTrail.count)", color: .cyan)
                    if let traj = analyzer.trajectoryResult {
                        infoChip(label: "弾道点数", value: "\(traj.points.count)", color: .red)
                    }
                }
            }

            // Main action button
            switch analysisStage {
            case .ready:
                // 検出スナップショット一覧ボタン
                if !snapshots.isEmpty {
                    Button {
                        showSnapshotGallery = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.stack").font(.system(size: 14))
                            Text("検出スナップショット (\(snapshots.count)枚)")
                                .font(.custom("Inter-Medium", size: 13, relativeTo: .body))
                        }
                        .foregroundStyle(AppTheme.primaryFixed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(AppTheme.primaryFixed.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await exportVideo() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars").font(.system(size: 16))
                        Text("軌跡動画を生成")
                            .font(.custom("Inter-Bold", size: 15, relativeTo: .body))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.primaryFixed)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

            case .exporting:
                VStack(spacing: 8) {
                    HStack {
                        Text("生成中...")
                            .font(.custom("Inter-Medium", size: 13, relativeTo: .caption))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(Int(exportProgress * 100))%")
                            .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                            .foregroundStyle(AppTheme.primaryFixed)
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.gray.opacity(0.3))
                            Capsule().fill(AppTheme.primaryFixed)
                                .frame(width: geo.size.width * exportProgress)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.vertical, 12)

            case .exported:
                Button {
                    if let url = exportedVideoURL {
                        saveToCameraRoll(url: url)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 16))
                        Text("カメラロールに保存")
                            .font(.custom("Inter-Bold", size: 15, relativeTo: .body))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.primaryFixed)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    resetAll()
                    showPicker = true
                } label: {
                    Text("別の動画を選択")
                        .font(.custom("Inter-Medium", size: 13, relativeTo: .caption))
                        .foregroundStyle(AppTheme.primaryFixed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

            case .empty, .analyzing:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AppTheme.surfaceContainerLowest.opacity(0.95))
    }

    private func infoChip(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.custom("Inter-Medium", size: 7, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(AppTheme.onSurfaceVariant)
        }
    }

    // MARK: - Analysis Flow

    @MainActor
    private func startAnalysisWithTrim(sourceURL: URL, start: Double, end: Double) async {
        analysisStage = .analyzing
        do {
            let trimmedURL = try await VideoTrimmer.trim(
                sourceURL: sourceURL,
                startSeconds: start,
                endSeconds: end
            )
            print("[TrailExport] Trimmed: \(start)s..\(end)s → \(trimmedURL.lastPathComponent)")
            // sourceVideoURL は exportVideo() が読む。pickerとは別state
            sourceVideoURL = trimmedURL
            startAnalysis(url: trimmedURL)
        } catch {
            print("[TrailExport] Trim failed: \(error)")
            analysisStage = .empty
            exportAlertMessage = "❌ 切り出しに失敗しました: \(error.localizedDescription)"
            showExportAlert = true
        }
    }

    private func startAnalysis(url: URL) {
        analysisStage = .analyzing
        clubTrail = []
        snapshots = []

        let avPlayer = AVPlayer(url: url)
        avPlayer.pause()
        player = avPlayer

        analyzer.knownBallPosition = CGPoint(x: 0.5, y: 0.72)
        analyzer.analyze(videoURL: url) {
            Task {
                guard let impactTime = analyzer.impactTime else {
                    await MainActor.run {
                        analysisStage = .empty
                        exportAlertMessage = "❌ インパクトが検出できませんでした"
                        showExportAlert = true
                    }
                    return
                }

                let asset = AVURLAsset(url: url)
                // スナップショット保存先: 一時ディレクトリにユニーク名で
                let snapDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("club_snapshots_\(Int(Date().timeIntervalSince1970))",
                                            isDirectory: true)

                let result = await ClubTrailRenderer.generateTrailWithSnapshots(
                    from: asset,
                    impactTime: impactTime,
                    snapshotDir: snapDir
                )

                await MainActor.run {
                    clubTrail = result.trail
                    snapshots = result.snapshots
                    analysisStage = .ready
                    avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                    avPlayer.play()
                }
            }
        }
    }

    @MainActor
    private func exportVideo() async {
        guard let sourceURL = sourceVideoURL,
              let impactTime = analyzer.impactTime else {
            print("[TrailExport] ❌ exportVideo guard failed: sourceVideoURL=\(sourceVideoURL?.lastPathComponent ?? "nil") impact=\(analyzer.impactTime ?? -1)")
            return
        }

        analysisStage = .exporting
        exportProgress = 0

        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let outputDir = docs.appendingPathComponent("Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970)
            let outputURL = outputDir.appendingPathComponent("trail_\(timestamp).mp4")

            let exporter = VideoExporter()
            exporter.progressHandler = { progress in
                Task { @MainActor in
                    self.exportProgress = progress
                }
            }

            let ballTrajectory = analyzer.trajectoryResult?.points ?? []

            try await exporter.exportVideo(
                sourceURL: sourceURL,
                outputURL: outputURL,
                clubTrail: clubTrail,
                ballTrajectory: ballTrajectory,
                impactTime: impactTime
            )

            exportedVideoURL = outputURL
            analysisStage = .exported
            exportAlertMessage = "✅ 軌跡動画を生成しました"
            showExportAlert = true

            // Replay with exported video
            let exportedPlayer = AVPlayer(url: outputURL)
            player = exportedPlayer
            exportedPlayer.play()

        } catch {
            analysisStage = .ready
            exportAlertMessage = "❌ 失敗: \(error.localizedDescription)"
            showExportAlert = true
            print("[TrailExport] Error: \(error)")
        }
    }

    private func resetAll() {
        player?.pause()
        player = nil
        analyzer.reset()
        pickedURL = nil
        sourceVideoURL = nil
        pendingVideo = nil
        clubTrail = []
        analysisStage = .empty
        exportedVideoURL = nil
        exportProgress = 0
        saveSuccess = false
    }

    private func saveToCameraRoll(url: URL) {
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
        saveSuccess = true
        exportAlertMessage = "✅ カメラロールに保存しました"
        showExportAlert = true
    }
}

// MARK: - Snapshot Gallery (検出結果の可視化)

/// 検出スナップショットを 2列グリッドで一覧表示するビュー
struct SnapshotGalleryView: View {
    let snapshots: [ClubTrailRenderer.DetectionSnapshot]
    @Environment(\.dismiss) var dismiss

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(snapshots.enumerated()), id: \.offset) { idx, snap in
                        SnapshotCard(index: idx, snapshot: snap)
                    }
                }
                .padding(12)
            }
            .background(AppTheme.surface)
            .navigationTitle("クラブヘッド検出結果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .foregroundStyle(AppTheme.primaryFixed)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SnapshotCard: View {
    let index: Int
    let snapshot: ClubTrailRenderer.DetectionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let img = UIImage(contentsOfFile: snapshot.imagePath.path) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(snapshot.detectedByMotion ? Color.yellow : Color.orange)
                    .frame(width: 8, height: 8)
                Text(String(format: "%.2fs", snapshot.time))
                    .font(.custom("SpaceGrotesk-Bold", size: 11, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Spacer()
                Text(snapshot.detectedByMotion ? "MOTION" : "POSE")
                    .font(.custom("Inter-Bold", size: 9, relativeTo: .caption2))
                    .foregroundStyle(snapshot.detectedByMotion ? Color.yellow : Color.orange)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
        .background(AppTheme.surfaceContainerLowest.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
