import SwiftUI
import AVKit
import AVFoundation

/// 動画の解析範囲を選択する画面（デュアルハンドル式）。
/// - 動画タイムライン上に左右2つのハンドル（開始・終了）
/// - ハンドルをドラッグして範囲指定（最大20秒）
/// - 下部に確定ボタン
struct VideoTrimView: View {

    let sourceURL: URL
    let onConfirm: (Double, Double) -> Void
    let onCancel: () -> Void

    @State private var player: AVPlayer?
    @State private var videoDuration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var currentTime: Double = 0
    @State private var isLoading = true
    @State private var thumbnails: [UIImage] = []

    // ドラッグ開始時のハンドル位置を記憶（translation 累積バグ対策）
    @State private var dragStartXForStart: CGFloat? = nil
    @State private var dragStartXForEnd: CGFloat? = nil

    private let maxDuration: Double = 20.0
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let handleWidth: CGFloat = 16
    private let timelineHeight: CGFloat = 56

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                // 動画プレビュー
                ZStack {
                    Color.black

                    if let player {
                        VideoPlayerLayerFit(player: player)
                            .allowsHitTesting(false)
                    }

                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.primaryFixed))
                    }
                }

                // タイムライン + 確定ボタン
                trimPanel
            }
        }
        .task {
            await loadVideo()
        }
        .onReceive(timer) { _ in
            guard let player else { return }
            let t = CMTimeGetSeconds(player.currentTime())
            currentTime = t
            // 範囲外に出たら開始位置に戻す
            if t >= endTime - 0.05 || t < startTime - 0.05 {
                seekTo(startTime)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button { onCancel() } label: {
                Text("キャンセル")
                    .font(.custom("Inter-Medium", size: 14, relativeTo: .body))
                    .foregroundStyle(.white)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("解析範囲を選択")
                    .font(.custom("SpaceGrotesk-Bold", size: 16, relativeTo: .body))
                    .foregroundStyle(AppTheme.primaryFixed)
                Text("最大 20秒・両端をドラッグ")
                    .font(.custom("Inter-Medium", size: 10, relativeTo: .caption))
                    .foregroundStyle(AppTheme.onSurfaceVariant)
            }
            Spacer()
            // 右上はスペーサーのみ
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Trim Panel

    private var trimPanel: some View {
        VStack(spacing: 18) {
            // 範囲情報
            HStack {
                infoBox(label: "開始", value: timeString(startTime))
                Spacer()
                infoBox(
                    label: "範囲",
                    value: String(format: "%.1fs", endTime - startTime),
                    highlight: endTime - startTime > maxDuration
                )
                Spacer()
                infoBox(label: "終了", value: timeString(endTime))
            }

            // タイムラインバー（サムネイル + 両端ハンドル）
            timelineWithHandles

            // 確定ボタン
            Button {
                onConfirm(startTime, endTime)
            } label: {
                Text("この範囲で解析")
                    .font(.custom("Inter-Bold", size: 15, relativeTo: .body))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canConfirm ? AppTheme.primaryFixed : AppTheme.primaryFixed.opacity(0.4))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 32)
        .background(AppTheme.surfaceContainerLowest.opacity(0.95))
    }

    private var canConfirm: Bool {
        !isLoading && endTime - startTime >= 0.5 && endTime - startTime <= maxDuration
    }

    // MARK: - Dual-Handle Timeline

    private var timelineWithHandles: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let total = max(0.1, videoDuration)

            // 各位置のX座標
            let startX = CGFloat(startTime / total) * totalWidth
            let endX = CGFloat(endTime / total) * totalWidth
            let currentX = CGFloat(currentTime / total) * totalWidth

            ZStack(alignment: .topLeading) {
                // 背景：サムネイルストリップ
                HStack(spacing: 0) {
                    ForEach(0..<thumbnails.count, id: \.self) { i in
                        Image(uiImage: thumbnails[i])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    }
                }
                .frame(width: totalWidth, height: timelineHeight)
                .clipped()
                .background(.gray.opacity(0.2))

                // 範囲外（左側）を暗く
                Rectangle()
                    .fill(.black.opacity(0.5))
                    .frame(width: max(0, startX), height: timelineHeight)

                // 範囲外（右側）を暗く
                Rectangle()
                    .fill(.black.opacity(0.5))
                    .frame(width: max(0, totalWidth - endX), height: timelineHeight)
                    .offset(x: endX)

                // 範囲ハイライト枠
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppTheme.primaryFixed, lineWidth: 3)
                    .frame(width: max(0, endX - startX), height: timelineHeight)
                    .offset(x: startX)

                // タッチエリアを広く取った透明ボタン状の開始ハンドル
                Color.clear
                    .frame(width: max(48, handleWidth + 32), height: timelineHeight + 32)
                    .contentShape(Rectangle())
                    .overlay(handleView().frame(width: handleWidth, height: timelineHeight + 16))
                    .offset(x: startX - max(48, handleWidth + 32) / 2, y: -16)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // ドラッグ開始時のハンドル位置を一度だけ記憶
                                if dragStartXForStart == nil {
                                    dragStartXForStart = startX
                                }
                                let baseX = dragStartXForStart ?? startX
                                let newX = max(0, min(endX - 20, baseX + value.translation.width))
                                let newTime = Double(newX / totalWidth) * total
                                startTime = max(0, newTime)
                                if endTime - startTime > maxDuration {
                                    endTime = min(total, startTime + maxDuration)
                                }
                                seekTo(startTime)
                            }
                            .onEnded { _ in
                                dragStartXForStart = nil
                            }
                    )

                // タッチエリアを広く取った透明ボタン状の終了ハンドル
                Color.clear
                    .frame(width: max(48, handleWidth + 32), height: timelineHeight + 32)
                    .contentShape(Rectangle())
                    .overlay(handleView().frame(width: handleWidth, height: timelineHeight + 16))
                    .offset(x: endX - max(48, handleWidth + 32) / 2, y: -16)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStartXForEnd == nil {
                                    dragStartXForEnd = endX
                                }
                                let baseX = dragStartXForEnd ?? endX
                                let newX = max(startX + 20, min(totalWidth, baseX + value.translation.width))
                                let newTime = Double(newX / totalWidth) * total
                                endTime = min(total, newTime)
                                if endTime - startTime > maxDuration {
                                    startTime = max(0, endTime - maxDuration)
                                }
                                seekTo(max(0, endTime - 0.1))
                            }
                            .onEnded { _ in
                                dragStartXForEnd = nil
                            }
                    )

                // 現在再生位置インジケーター
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: timelineHeight)
                    .offset(x: max(0, min(totalWidth - 1, currentX - 1)))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: timelineHeight)
    }

    private func handleView() -> some View {
        ZStack {
            // ハンドル本体
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.primaryFixed)

            // 中央のグリップライン
            VStack(spacing: 2) {
                Rectangle().fill(.black.opacity(0.6)).frame(width: 2, height: 12)
            }
        }
    }

    // MARK: - Components

    private func infoBox(label: String, value: String, highlight: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.custom("SpaceGrotesk-Bold", size: 14, relativeTo: .body))
                .foregroundStyle(highlight ? .red : AppTheme.primaryFixed)
                .monospacedDigit()
            Text(label)
                .font(.custom("Inter-Medium", size: 8, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(AppTheme.onSurfaceVariant)
        }
    }

    // MARK: - Helpers

    private func timeString(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    private func loadVideo() async {
        let asset = AVURLAsset(url: sourceURL)
        let duration = (try? await asset.load(.duration)) ?? CMTime.zero
        let seconds = max(0.5, CMTimeGetSeconds(duration))

        // サムネイルを8枚生成
        let thumbs = await generateThumbnails(asset: asset, count: 8, totalSeconds: seconds)

        await MainActor.run {
            self.videoDuration = seconds
            self.startTime = 0
            self.endTime = min(seconds, maxDuration)
            self.thumbnails = thumbs
            self.player = AVPlayer(url: sourceURL)
            self.player?.play()
            self.isLoading = false
        }
    }

    private func generateThumbnails(asset: AVURLAsset, count: Int, totalSeconds: Double) async -> [UIImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        generator.maximumSize = CGSize(width: 80, height: 120)

        var images: [UIImage] = []
        for i in 0..<count {
            let t = totalSeconds * Double(i) / Double(count)
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var actual = CMTime.zero
            if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: &actual) {
                images.append(UIImage(cgImage: cgImage))
            }
        }
        return images
    }

    private func seekTo(_ seconds: Double) {
        guard let player else { return }
        let cmTime = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
    }
}
