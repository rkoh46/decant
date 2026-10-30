// Deleting through iCloud. iOS refuses deletes over USB while iCloud Photos is on, but with iCloud Photos on the
// phone's library is the iCloud library, so deleting the same assets from the Mac's Photos library (synced to
// the same account) removes them from iCloud and the phone. macOS confirms each batch with its own dialog.
import Foundation
import Photos

enum PhotoLibraryDeleter {
    nonisolated static var authorized: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    nonisolated static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
    }

    /// Library assets for the phone's files. Match by original filename first; the capture date only breaks
    /// ties, because saved and shared images carry a Photos date that differs from the file date the phone reports.
    nonisolated static func match(_ items: [MediaItem]) -> (found: [MediaItem: PHAsset], missing: [MediaItem]) {
        var found: [MediaItem: PHAsset] = [:]
        var missing: [MediaItem] = []
        let wanted = Set(items.map { $0.name.lowercased() })
        // One pass over the library, collecting assets whose original filename we are looking for.
        var byName: [String: [PHAsset]] = [:]
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            for r in PHAssetResource.assetResources(for: asset) where wanted.contains(r.originalFilename.lowercased()) {
                byName[r.originalFilename.lowercased(), default: []].append(asset); break
            }
        }
        for item in items {
            let candidates = byName[item.name.lowercased()] ?? []
            if candidates.count == 1 || (candidates.count > 1 && item.date == nil) { found[item] = candidates[0]; continue }
            if candidates.count > 1 {
                found[item] = candidates.min { a, b in
                    abs((a.creationDate ?? .distantPast).timeIntervalSince(item.date!)) < abs((b.creationDate ?? .distantPast).timeIntervalSince(item.date!))
                }
                continue
            }
            // Saved and shared images keep a different filename in Photos: fall back to the same pixel size
            // captured within a minute of the phone's date.
            if let asset = matchByShape(item) { found[item] = asset } else { missing.append(item) }
        }
        return (found, missing)
    }

    nonisolated private static func matchByShape(_ item: MediaItem) -> PHAsset? {
        guard let date = item.date, item.pixelWidth > 0 else { return nil }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@ AND pixelWidth == %d AND pixelHeight == %d",
                                        date.addingTimeInterval(-60) as NSDate, date.addingTimeInterval(60) as NSDate,
                                        item.pixelWidth, item.pixelHeight)
        let r = PHAsset.fetchAssets(with: item.isVideo ? .video : .image, options: options)
        var best: PHAsset?
        r.enumerateObjects { a, _, _ in
            if best == nil || abs((a.creationDate ?? .distantPast).timeIntervalSince(date)) < abs((best!.creationDate ?? .distantPast).timeIntervalSince(date)) { best = a }
        }
        return best
    }

    /// Delete the matched assets in one change (one system confirmation). Returns the items that were deleted.
    nonisolated static func delete(_ items: [MediaItem]) async throws -> (deleted: [MediaItem], missing: [MediaItem]) {
        if !authorized {
            let granted = await requestAccess()
            guard granted else {
                throw NSError(domain: "Decant", code: 1, userInfo: [NSLocalizedDescriptionKey: "Decant was not allowed to access the Photos library (System Settings → Privacy & Security → Photos)"])
            }
        }
        // The library scan is the slow part; keep it off the main thread so the window stays responsive.
        let (found, missing) = await Task.detached(priority: .userInitiated) { match(items) }.value
        guard !found.isEmpty else { return ([], missing) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(Array(found.values) as NSArray)
        }
        return (Array(found.keys), missing)
    }
}
