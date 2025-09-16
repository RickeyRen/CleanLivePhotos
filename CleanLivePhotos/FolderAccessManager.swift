import Foundation

// MARK: - Security Scoped Bookmark Manager
class FolderAccessManager {
    private var selectedURL: URL?

    @MainActor
    func requestAccess(to url: URL) async -> Bool {
        // Store the user-selected URL directly
        self.selectedURL = url
        return true
    }

    func startAccessing() async -> Bool {
        guard let url = selectedURL else {
            print("No URL available to start accessing.")
            return false
        }

        // Since the URL comes from NSOpenPanel, it already has access rights
        // We just need to start accessing the security-scoped resource
        if url.startAccessingSecurityScopedResource() {
            print("Successfully started accessing: \(url.path)")
            return true
        } else {
            print("Failed to start accessing security scoped resource: \(url.path)")
            return false
        }
    }

    func stopAccessing() {
        if let url = selectedURL {
            url.stopAccessingSecurityScopedResource()
            print("Stopped accessing: \(url.path)")
        }
    }
} 