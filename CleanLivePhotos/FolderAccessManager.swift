import Foundation

// MARK: - Security Scoped Bookmark Manager
class FolderAccessManager {
    private var bookmark: Data?
    private var accessedURL: URL?

    @MainActor
    func requestAccess(to url: URL) async -> Bool {
        do {
            self.bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            return true
        } catch {
            print("Failed to create bookmark for \(url.path): \(error.localizedDescription)")
            self.bookmark = nil
            return false
        }
    }

    func startAccessing() async -> Bool {
        guard let bookmark = bookmark else {
            print("No bookmark available to start accessing.")
            return false
        }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            if isStale {
                print("Bookmark is stale, requesting new one is needed.")
                // In a real app, you might need to re-request access here.
                return false
            }

            if url.startAccessingSecurityScopedResource() {
                self.accessedURL = url
                return true
            } else {
                print("Failed to start accessing security scoped resource.")
                return false
            }
        } catch {
            print("Failed to resolve bookmark: \(error.localizedDescription)")
            return false
        }
    }

    func stopAccessing() {
        if let url = accessedURL {
            url.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
    }
} 