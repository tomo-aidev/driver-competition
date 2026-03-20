import Foundation
import AVFoundation
import UIKit

/// Manages persistent storage of shot records and video files.
/// All data is stored in Documents/Shots/ to survive app updates.
@MainActor
final class ShotStore: ObservableObject {
    @Published private(set) var shots: [ShotRecord] = []

    private let fileManager = FileManager.default

    private var shotsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Shots", isDirectory: true)
    }

    private var indexURL: URL {
        shotsDirectory.appendingPathComponent("index.json")
    }

    init() {
        ensureDirectoryExists()
        loadIndex()
    }

    // MARK: - Public API

    /// Save a video file and create a new shot record
    func saveShot(from sourceURL: URL) async throws -> ShotRecord {
        let fileName = "\(UUID().uuidString).mov"
        let destURL = shotsDirectory.appendingPathComponent(fileName)

        try fileManager.copyItem(at: sourceURL, to: destURL)

        // Generate thumbnail
        let thumbnailName = fileName.replacingOccurrences(of: ".mov", with: "_thumb.jpg")
        await generateThumbnail(from: destURL, saveTo: thumbnailName)

        var record = ShotRecord(videoFileName: fileName)
        record.thumbnailFileName = thumbnailName
        shots.insert(record, at: 0)
        saveIndex()

        return record
    }

    /// Update analysis results for a shot
    func updateShot(_ record: ShotRecord) {
        if let idx = shots.firstIndex(where: { $0.id == record.id }) {
            shots[idx] = record
            saveIndex()
        }
    }

    /// Get video URL for a shot
    func videoURL(for record: ShotRecord) -> URL {
        shotsDirectory.appendingPathComponent(record.videoFileName)
    }

    /// Get thumbnail URL for a shot
    func thumbnailURL(for record: ShotRecord) -> URL? {
        guard let name = record.thumbnailFileName else { return nil }
        return shotsDirectory.appendingPathComponent(name)
    }

    /// Delete a shot and its files
    func deleteShot(_ record: ShotRecord) {
        shots.removeAll { $0.id == record.id }
        let videoURL = shotsDirectory.appendingPathComponent(record.videoFileName)
        try? fileManager.removeItem(at: videoURL)
        if let thumbName = record.thumbnailFileName {
            let thumbURL = shotsDirectory.appendingPathComponent(thumbName)
            try? fileManager.removeItem(at: thumbURL)
        }
        saveIndex()
    }

    // MARK: - Private

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
    }

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            shots = try JSONDecoder().decode([ShotRecord].self, from: data)
        } catch {
            print("[ShotStore] Failed to load index: \(error)")
        }
    }

    private func saveIndex() {
        do {
            let data = try JSONEncoder().encode(shots)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("[ShotStore] Failed to save index: \(error)")
        }
    }

    private func generateThumbnail(from videoURL: URL, saveTo fileName: String) async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        var actualTime = CMTime.zero
        guard let image = try? generator.copyCGImage(at: time, actualTime: &actualTime) else { return }

        let uiImage = UIImage(cgImage: image)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.7) else { return }

        let thumbURL = shotsDirectory.appendingPathComponent(fileName)
        try? jpegData.write(to: thumbURL)
    }
}
