import SwiftUI
import AVKit
import AVFoundation
import Photos
import UIKit

/// AspectFit版のVideoPlayerLayer (オーバーレイの座標を正確に合わせるため)
struct VideoPlayerLayerFit: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect  // フィット表示（letterbox）
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

/// MVVM の View: ゴルフスイング解析プロトタイプの UI
/// - 動画選択 → 解析（骨格・クラブ・ボール）→ プレビュー → エクスポート の一連フロー
/// - 骨格・クラブ軌跡・ボール弾道は SwiftUI Canvas でリアルタイム描画
struct SwingPrototypeView: View {
    @StateObject private var viewModel = SwingPrototypeViewModel()
    @State private var showPicker = false
    @State private var currentTime: Double = 0
    @State private var alertMessage: String?
    @State private var showAlert = false

    // 動画選択 → トリミングフロー
    @State private var pickedURL: URL?  // pickerが書き込む先（実stateを持つ）
    @State private var pendingVideo: PendingVideoItem?

    struct PendingVideoItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    // SwiftUI ネイティブの Timer (再生時刻を 0.05秒間隔で取得)
    private let playbackTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                if case .empty = viewModel.stage {
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
            // pickerが選択を確定 → 一旦 pickedURL をクリアし、cover を表示
            pickedURL = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pendingVideo = PendingVideoItem(url: url)
            }
        }
        // item-based: pendingVideo が設定されると自動表示、解除で自動dismiss
        .fullScreenCover(item: $pendingVideo) { item in
            VideoTrimView(
                sourceURL: item.url,
                onConfirm: { start, end in
                    let url = item.url
                    pendingVideo = nil
                    Task { await viewModel.analyzeWithTrim(sourceURL: url, start: start, end: end) }
                },
                onCancel: {
                    pendingVideo = nil
                }
            )
        }
        .onReceive(playbackTimer) { _ in
            guard let player = viewModel.player else { return }
            currentTime = CMTimeGetSeconds(player.currentTime())
        }
        .alert("通知", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prototype")
                    .font(.custom("SpaceGrotesk-Bold", size: 22, relativeTo: .title2))
                    .foregroundStyle(AppTheme.primaryFixed)
                Text("骨格 + クラブ軌跡 + ボール弾道")
                    .font(.custom("Inter-Medium", size: 11, relativeTo: .caption))
                    .foregroundStyle(AppTheme.onSurfaceVariant)
            }
            Spacer()

            // リセットボタン
            if case .empty = viewModel.stage {
                EmptyView()
            } else {
                Button {
                    viewModel.reset()
                    currentTime = 0
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
                Image(systemName: "figure.golf")
                    .font(.system(size: 56))
                    .foregroundStyle(AppTheme.primaryFixed)
            }

            VStack(spacing: 8) {
                Text("ゴルフ動画を解析")
                    .font(.custom("SpaceGrotesk-Bold", size: 20, relativeTo: .title3))
                    .foregroundStyle(.white)

                Text("Vision Framework で骨格・クラブ軌跡・\nボール弾道を可視化します")
                    .font(.custom("Inter-Medium", size: 13, relativeTo: .body))
                    .foregroundStyle(AppTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            // 機能リスト
            VStack(alignment: .leading, spacing: 10) {
                featureRow(icon: "figure.run", title: "骨格推定", desc: "VNDetectHumanBodyPoseRequest")
                featureRow(icon: "scribble.variable", title: "クラブ軌跡", desc: "手首ポーズ + 補間")
                featureRow(icon: "scope", title: "ボール弾道", desc: "VNDetectTrajectoriesRequest")
            }
            .padding(20)
            .background(AppTheme.surfaceContainerLowest.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)

            Spacer()

            Button {
                requestPhotoLibraryAccessAndPick()
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

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.primaryFixed)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.custom("Inter-Bold", size: 13, relativeTo: .body)).foregroundStyle(.white)
                Text(desc).font(.custom("Inter-Medium", size: 10, relativeTo: .caption)).foregroundStyle(AppTheme.onSurfaceVariant)
            }
        }
    }

    // MARK: - Content Area (解析中・再生・エクスポート)

    private var contentArea: some View {
        VStack(spacing: 0) {
            // 動画 + オーバーレイプレビュー
            GeometryReader { geo in
                ZStack {
                    Color.black

                    if let player = viewModel.player {
                        // AspectFit版: 動画全体が見える（letterbox可能）→ オーバーレイ座標が正確
                        VideoPlayerLayerFit(player: player)
                    }

                    // === SwiftUI Canvas オーバーレイ（プレビュー用） ===
                    overlayCanvas(in: geo.size)

                    // 解析中オーバーレイ
                    if case let .analyzing(progress, message) = viewModel.stage {
                        analyzingOverlay(progress: progress, message: message)
                    }
                }
            }

            // ボトムアクションパネル
            actionPanel
        }
    }

    // MARK: - Overlay Canvas (骨格 + クラブ軌跡 + ボール弾道)

    @ViewBuilder
    private func overlayCanvas(in size: CGSize) -> some View {
        // 動画の表示領域を計算（aspectRatio 9:16 で表示中なのでそれに合わせる）
        let videoSize = videoFitSize(in: size)
        let offsetX = (size.width - videoSize.width) / 2
        let offsetY = (size.height - videoSize.height) / 2

        ZStack {
            Canvas { context, _ in
                // Proto: 骨格のみ描画（クラブ軌跡・ボール弾道は描画しない）
                if let pose = viewModel.currentPose(at: currentTime),
                   abs(pose.time - currentTime) < 0.15 {
                    SkeletonRenderer.drawSkeleton(frame: pose, in: context, size: videoSize)
                }
            }
            .frame(width: videoSize.width, height: videoSize.height)
            .offset(x: offsetX, y: offsetY)
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
    }

    /// 動画が aspectFit で表示されるサイズを計算（実アスペクト比に基づく）
    private func videoFitSize(in container: CGSize) -> CGSize {
        let aspect = viewModel.videoAspect  // 実際の動画アスペクト比 (width/height)
        let containerAspect = container.width / container.height
        if containerAspect > aspect {
            // コンテナのが横長 → 高さに合わせる、横は計算
            return CGSize(width: container.height * aspect, height: container.height)
        } else {
            // コンテナのが縦長 → 幅に合わせる、縦は計算
            return CGSize(width: container.width, height: container.width / aspect)
        }
    }

    private func drawClubTrailCanvas(_ points: [ClubTrailRenderer.TrailPoint], in context: GraphicsContext, size: CGSize) {
        guard points.count >= 2 else { return }

        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]

            let p1 = CGPoint(x: prev.position.x * size.width, y: prev.position.y * size.height)
            let p2 = CGPoint(x: curr.position.x * size.width, y: curr.position.y * size.height)

            // フェーズ別カラー
            let color: Color
            switch curr.phase {
            case .backswing:  color = Color(red: 0.3, green: 0.6, blue: 1.0)
            case .downswing:  color = Color(red: 0.4, green: 1.0, blue: 0.3)
            case .postImpact: color = Color(red: 1.0, green: 1.0, blue: 0.2)
            case .address:    color = Color.gray
            }

            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)

            // グロー
            context.stroke(path, with: .color(color.opacity(0.3)),
                          style: StrokeStyle(lineWidth: 16, lineCap: .round))
            // コア
            context.stroke(path, with: .color(color.opacity(0.9)),
                          style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }
    }

    private func drawBallTrajectoryCanvas(_ points: [TrajectoryDetector.TrajectoryPoint], in context: GraphicsContext, size: CGSize) {
        guard points.count >= 2 else { return }

        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]

            let p1 = CGPoint(x: prev.position.x * size.width, y: prev.position.y * size.height)
            let p2 = CGPoint(x: curr.position.x * size.width, y: curr.position.y * size.height)

            let red = Color(red: 1.0, green: 0.15, blue: 0.1)

            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)

            // グロー
            context.stroke(path, with: .color(Color(red: 1, green: 0.3, blue: 0).opacity(0.3)),
                          style: StrokeStyle(lineWidth: 20, lineCap: .round))
            // コア
            context.stroke(path, with: .color(red.opacity(0.95)),
                          style: StrokeStyle(lineWidth: 10, lineCap: .round))
        }
    }

    // MARK: - Analyzing Overlay

    private func analyzingOverlay(progress: Double, message: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.primaryFixed))
                .scaleEffect(1.6)

            Text(message)
                .font(.custom("Inter-Medium", size: 13, relativeTo: .body))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("\(Int(progress * 100))%")
                .font(.custom("SpaceGrotesk-Bold", size: 28, relativeTo: .title2))
                .foregroundStyle(AppTheme.primaryFixed)
                .monospacedDigit()
        }
        .padding(28)
        .background(.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Action Panel

    @ViewBuilder
    private var actionPanel: some View {
        VStack(spacing: 12) {
            // 解析結果のサマリー
            if case .ready = viewModel.stage {
                analysisInfo
            } else if case .exported = viewModel.stage {
                analysisInfo
            }

            // 主要アクション
            switch viewModel.stage {
            case .ready:
                Button {
                    Task { _ = await viewModel.exportVideo() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars").font(.system(size: 16))
                        Text("骨格動画を生成")
                            .font(.custom("Inter-Bold", size: 15, relativeTo: .body))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.primaryFixed)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

            case let .exporting(progress):
                VStack(spacing: 8) {
                    HStack {
                        Text("生成中...")
                            .font(.custom("Inter-Medium", size: 13, relativeTo: .caption))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                            .foregroundStyle(AppTheme.primaryFixed).monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.gray.opacity(0.3))
                            Capsule().fill(AppTheme.primaryFixed)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.vertical, 12)

            case let .exported(url):
                Button {
                    saveToCameraRoll(url: url)
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

            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AppTheme.surfaceContainerLowest.opacity(0.95))
    }

    private var analysisInfo: some View {
        HStack(spacing: 12) {
            infoChip(label: "POSE", value: "\(viewModel.poseFrames.count)", color: .yellow)
            infoChip(label: "JOINTS", value: "\(viewModel.poseFrames.first?.joints.count ?? 0)", color: AppTheme.primaryFixed)
            infoChip(label: "IMPACT", value: String(format: "%.1fs", viewModel.impactTime), color: .orange)
        }
    }

    private func infoChip(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.custom("SpaceGrotesk-Bold", size: 13, relativeTo: .body))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.custom("Inter-Medium", size: 7, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(AppTheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Photo Library アクセス権限

    private func requestPhotoLibraryAccessAndPick() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            showPicker = true
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        showPicker = true
                    } else {
                        alertMessage = "写真ライブラリへのアクセスが必要です"
                        showAlert = true
                    }
                }
            }
        case .denied, .restricted:
            alertMessage = "設定 > プライバシー > 写真 でアクセスを許可してください"
            showAlert = true
        @unknown default:
            break
        }
    }

    private func saveToCameraRoll(url: URL) {
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
        alertMessage = "✅ カメラロールに保存しました"
        showAlert = true
    }
}
