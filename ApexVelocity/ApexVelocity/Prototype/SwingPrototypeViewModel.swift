import SwiftUI
import AVFoundation
import Combine

/// MVVM の ViewModel: 動画解析パイプライン全体を統括する。
///
/// 責務:
/// - 解析タスクのバックグラウンド実行 (Task / async-await)
/// - 解析結果（骨格・クラブ軌跡・ボール弾道）を @Published で View に通知
/// - 動画書き出し処理を VideoExporter に委譲
@MainActor
final class SwingPrototypeViewModel: ObservableObject {

    // MARK: - 解析状態

    enum Stage: Equatable {
        case empty               // 動画未選択
        case analyzing(progress: Double, message: String)  // 解析中
        case ready               // 解析完了、エクスポート可能
        case exporting(progress: Double)
        case exported(url: URL)
    }

    @Published var stage: Stage = .empty

    // MARK: - 解析結果（View が描画に使用）

    @Published var poseFrames: [PoseFrameExtractor.PoseFrame] = []
    @Published var clubTrail: [ClubTrailRenderer.TrailPoint] = []
    @Published var ballTrajectory: [TrajectoryDetector.TrajectoryPoint] = []
    @Published var impactTime: Double = 0
    @Published var ballPosition: CGPoint = CGPoint(x: 0.5, y: 0.72)

    /// 動画の表示時の縦横比（orientation 適用後）
    @Published var videoAspect: CGFloat = 9.0 / 16.0

    // MARK: - 動画

    @Published var videoURL: URL?
    @Published var player: AVPlayer?

    // 内部
    private var analysisTask: Task<Void, Never>?
    private let analyzer = VideoAnalyzer()

    // MARK: - 解析開始

    /// 元動画から指定範囲をトリミングしてから解析する。
    /// - Parameters:
    ///   - sourceURL: 元動画
    ///   - start: 開始時刻（秒）
    ///   - end: 終了時刻（秒）
    func analyzeWithTrim(sourceURL: URL, start: Double, end: Double) async {
        cancelAnalysis()
        stage = .analyzing(progress: 0.0, message: "動画を切り出し中...")

        do {
            let trimmedURL = try await VideoTrimmer.trim(
                sourceURL: sourceURL,
                startSeconds: start,
                endSeconds: end
            )
            print("[Prototype] Trimmed: \(start)s..\(end)s → \(trimmedURL.lastPathComponent)")
            analyze(videoURL: trimmedURL)
        } catch {
            print("[Prototype] Trim failed: \(error)")
            stage = .empty
        }
    }

    /// 動画ファイルを受け取り、骨格・クラブ・ボールの解析パイプラインを実行する。
    func analyze(videoURL: URL) {
        cancelAnalysis()

        self.videoURL = videoURL
        let avPlayer = AVPlayer(url: videoURL)
        avPlayer.pause()
        self.player = avPlayer
        self.poseFrames = []
        self.clubTrail = []
        self.ballTrajectory = []

        stage = .analyzing(progress: 0.0, message: "動画を読み込み中...")

        analysisTask = Task {
            let asset = AVURLAsset(url: videoURL)

            // 動画の実サイズと向きを取得
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 1080, height: 1920)
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let displayed = natural.applying(transform)
                let w = abs(displayed.width)
                let h = abs(displayed.height)
                if w > 0 && h > 0 {
                    self.videoAspect = w / h
                    print("[Prototype] Video aspect: \(w)x\(h) = \(String(format: "%.3f", w/h))")
                }
            }

            // === Step 1: 既存の VideoAnalyzer を使ってインパクト/ボール位置/弾道を取得 ===
            stage = .analyzing(progress: 0.05, message: "インパクトとボール位置を検出中...")

            analyzer.knownBallPosition = CGPoint(x: 0.5, y: 0.72)
            await withCheckedContinuation { continuation in
                analyzer.analyze(videoURL: videoURL) {
                    continuation.resume()
                }
            }

            guard !Task.isCancelled else { return }

            let detectedImpact = analyzer.impactTime ?? 1.0
            let detectedBall = analyzer.ballLocation?.position ?? CGPoint(x: 0.5, y: 0.72)
            let trajectory = analyzer.trajectoryResult?.points ?? []

            self.impactTime = detectedImpact
            self.ballPosition = detectedBall
            self.ballTrajectory = trajectory

            // === Step 2: 骨格抽出 (NEW) ===
            stage = .analyzing(progress: 0.4, message: "骨格を解析中...")

            let extractedPoses = await PoseFrameExtractor.extractPoses(
                from: asset,
                sampleInterval: 0.05  // 20fps
            )

            guard !Task.isCancelled else { return }
            self.poseFrames = extractedPoses

            // Proto: クラブ軌跡・ボール弾道は記録しない（骨格のみ）
            self.clubTrail = []
            self.ballTrajectory = []

            // === 解析完了 → プレビュー再生開始 ===
            stage = .ready
            avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            avPlayer.play()

            print("[Prototype] Analysis complete: \(extractedPoses.count) pose frames (skeleton-only mode)")
        }
    }

    // MARK: - 動画書き出し

    /// 解析結果を焼き込んだ動画を書き出す。
    /// - Returns: 書き出された動画の URL
    func exportVideo() async -> URL? {
        guard let sourceURL = videoURL else { return nil }

        stage = .exporting(progress: 0.0)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputDir = docs.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let outputURL = outputDir.appendingPathComponent("prototype_\(timestamp).mp4")

        let exporter = VideoExporter()
        exporter.progressHandler = { [weak self] progress in
            Task { @MainActor in
                self?.stage = .exporting(progress: progress)
            }
        }

        do {
            // Proto: 骨格のみを記録（クラブ軌跡・ボール弾道は除外）
            try await exporter.exportVideo(
                sourceURL: sourceURL,
                outputURL: outputURL,
                clubTrail: [],            // 空: クラブ軌跡を描画しない
                ballTrajectory: [],       // 空: ボール弾道を描画しない
                impactTime: impactTime,
                poseFrames: poseFrames    // 骨格のみ
            )

            stage = .exported(url: outputURL)

            // 書き出した動画を再生
            let exportedPlayer = AVPlayer(url: outputURL)
            self.player = exportedPlayer
            exportedPlayer.play()

            return outputURL
        } catch {
            print("[Prototype] Export failed: \(error)")
            stage = .ready
            return nil
        }
    }

    // MARK: - キャンセル/リセット

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analyzer.reset()
    }

    func reset() {
        cancelAnalysis()
        player?.pause()
        player = nil
        videoURL = nil
        poseFrames = []
        clubTrail = []
        ballTrajectory = []
        stage = .empty
    }

    /// 指定時刻に対応する PoseFrame を取得（プレビュー用）
    func currentPose(at time: Double) -> PoseFrameExtractor.PoseFrame? {
        PoseFrameExtractor.nearestPose(in: poseFrames, at: time)
    }
}
