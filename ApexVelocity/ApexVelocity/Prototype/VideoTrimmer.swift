import AVFoundation
import Foundation

/// 動画を指定時間範囲でトリミングして一時ファイルに出力するサービス。
/// AVAssetExportSession を使用、最大20秒まで（呼び出し側で制限）。
struct VideoTrimmer {

    enum TrimError: Error {
        case sessionInitFailed
        case exportFailed(String)
        case timedOut
    }

    /// 動画をトリミングして一時ファイルに保存する。
    /// - Parameters:
    ///   - sourceURL: 元動画
    ///   - startSeconds: 切り出し開始時刻
    ///   - endSeconds: 切り出し終了時刻
    /// - Returns: トリミング後の一時ファイルURL
    static func trim(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double
    ) async throws -> URL {

        let asset = AVURLAsset(url: sourceURL)

        // Output URL: temp directory
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("trimmed_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        // Setup export session
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw TrimError.sessionInitFailed
        }

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        // Time range
        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let duration = CMTime(seconds: endSeconds - startSeconds, preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: start, duration: duration)

        // Export
        await session.export()

        guard session.status == .completed else {
            throw TrimError.exportFailed(session.error?.localizedDescription ?? "unknown")
        }

        return outputURL
    }
}
