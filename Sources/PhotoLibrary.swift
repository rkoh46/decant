// Deleting through iCloud. iOS refuses deletes over USB while iCloud Photos is on, but with iCloud Photos on the
// phone's library is the iCloud library, so deleting the same assets from the Mac's Photos library (synced to
// the same account) removes them from iCloud and the phone. macOS confirms each batch with its own dialog.
import Foundation
import Photos

@MainActor
enum PhotoLibraryDeleter {
    static var authorized: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
    }

    /// Find the library assets that correspond to the phone's files: same original filename, same capture time.
    static func match(_ items: [MediaItem]) -> (found: [MediaItem: PHAsset], missing: [MediaItem]) {
        var found: [MediaItem: PHAsset] = [:]
        var missing: [MediaItem] = []
        for item in items {
            guard let date = item.date else { missing.append(item); continue }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                            date.addingTimeInterval(-2) as NSDate, date.addingTimeInterval(2) as NSDate)
            options.includeHiddenAssets = true
            let candidates = PHAsset.fetchAssets(with: options)
            var hit: PHAsset?
            candidates.enumerateObjects { asset, _, stop in
                let names = PHAssetResource.assetResources(for: asset).map { $0.originalFilename.lowercased() }
                if names.contains(item.name.lowercased()) { hit = asset; stop.pointee = true }
            }
            if let hit { found[item] = hit } else { missing.append(item) }
        }
        return (found, missing)
    }

    /// Delete the matched assets in one change (one system confirmation). Returns the items that were deleted.
    static func delete(_ items: [MediaItem]) async throws -> (deleted: [MediaItem], missing: [MediaItem]) {
        if !authorized {
            let granted = await requestAccess()
            guard granted else {
                throw NSError(domain: "Decant", code: 1, userInfo: [NSLocalizedDescriptionKey: "Decant was not allowed to access the Photos library (System Settings → Privacy & Security → Photos)"])
            }
        }
        let (found, missing) = match(items)
        guard !found.isEmpty else { return ([], missing) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(Array(found.values) as NSArray)
        }
        return (Array(found.keys), missing)
    }
}
