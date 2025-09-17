import SwiftUI
import AVKit
import Quartz
import UniformTypeIdentifiers

// MARK: - Embedded Preview Pane

/// A single row for displaying a piece of metadata.
struct MetadataRow: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundColor(.primary)
        }
    }
}

struct PreviewPane: View {
    let file: DisplayFile?
    @State private var metadata: FileMetadata?
    @State private var player: AVPlayer?
    @State private var metadataTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Use the file's ID for the transition, so it animates when the selection changes.
            if let file = file {
                VStack(spacing: 20) {
                    // Media View
                    mediaPlayerView(for: file.url)
                        // By constraining the max height of the media player, we break a potential
                        // layout cycle where the player's aspect ratio and the container's height
                        // depend on each other. This resolves the "AttributeGraph cycle" warnings.
                        .frame(maxHeight: 450)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    
                    // Details Section
                    VStack(spacing: 12) {
                        Text(file.fileName)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        
                        
                        if let metadata = metadata, !metadata.isEmpty {
                            VStack(spacing: 10) {
                                Divider()
                                ForEach(metadata, id: \.label) { item in
                                    MetadataRow(label: item.label, value: item.value, icon: item.icon)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.vertical, 20)
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                
            } else {
                ContentUnavailableView(label: "Select a file to preview", icon: "magnifyingglass")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
        .onChange(of: file) { oldFile, newFile in
            // Cancel any existing task and start a new one for the new file.
            metadataTask?.cancel()
            updatePreview(for: newFile)
        }
        .onAppear {
            updatePreview(for: file)
        }
        .onDisappear {
            // When the view disappears, cancel any in-flight tasks and release the player.
            metadataTask?.cancel()
            player = nil
        }
    }
    
    private func updatePreview(for displayFile: DisplayFile?) {
        // When the file is nil, there's nothing to show.
        guard let url = displayFile?.url else {
            self.metadata = nil
            self.player = nil
            return
        }
        
        // Set up the player or clear it for images.
        if isVideo(url) {
            self.player = AVPlayer(url: url)
        } else {
            self.player = nil
        }
        
        // Launch a new, cancellable task to fetch metadata.
        metadataTask = Task {
            // Must check for nil again inside the task, as the file selection
            // could change rapidly.
            guard let displayFile = displayFile else { return }
            
            let newMetadata = await fetchMetadata(for: displayFile)
            
            // Before updating the UI, check if the task has been cancelled.
            if Task.isCancelled { return }
            
            await MainActor.run {
                self.metadata = newMetadata
            }
        }
    }
    
    @ViewBuilder
    private func mediaPlayerView(for url: URL) -> some View {
        if isVideo(url), let player = self.player {
            VideoPlayer(player: player)
                .aspectRatio(16/9, contentMode: .fit)
        } else if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ContentUnavailableView(label: "Preview Unavailable", icon: "eye.slash.fill")
                .aspectRatio(16/9, contentMode: .fit)
        }
    }

    private func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .movie)
    }
    
    private func fetchMetadata(for file: DisplayFile) async -> FileMetadata {
        var details: FileMetadata = []
        
        // --- General Info (Always Available) ---
        details.append(("Size", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), "doc.text"))
        if let creationDate = (try? file.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
            details.append(("Created", creationDate.formatted(date: .long, time: .shortened), "calendar"))
        }

        // --- File Hash (for debugging duplicate detection) ---
        do {
            let hash = try calculateHash(for: file.url)
            details.append(("SHA256", hash, "number")) // Show full hash for comparison
        } catch {
            details.append(("SHA256", "计算失败: \(error.localizedDescription)", "exclamationmark.triangle"))
        }

        // --- Media-Specific Info ---
        if isVideo(file.url) {
            if Task.isCancelled { return [] }
            let asset = AVAsset(url: file.url)
            
            // --- Load basic properties concurrently ---
            async let duration = try? asset.load(.duration).seconds
            async let track = try? asset.loadTracks(withMediaType: .video).first
            // Correctly load the common metadata collection.
            async let commonMetadata = try? await asset.load(.commonMetadata)

            if let duration = await duration, duration > 0 {
                 if Task.isCancelled { return [] }
                details.append(("Duration", formatDuration(duration), "clock"))
            }
            if let track = await track,
               let size = try? await track.load(.naturalSize) {
                 if Task.isCancelled { return [] }
                details.append(("Dimensions", "\(Int(size.width)) x \(Int(size.height))", "arrow.up.left.and.arrow.down.right"))
            }

            // --- Process rich common metadata ---
            if let metadataItems = await commonMetadata {
                for item in metadataItems {
                    if Task.isCancelled { return [] }
                    
                    // Corrected: The key is synchronous, only the value needs async loading.
                    guard let key = item.commonKey?.rawValue,
                          let value = try? await item.load(.stringValue) else {
                        continue
                    }

                    switch key {
                    case "make":
                        details.append(("Make", value, "hammer"))
                    case "model":
                        details.append(("Model", value, "camera.shutter.button"))
                    case "software":
                        details.append(("Software", value, "computermouse"))
                    case "creationDate":
                        // Often more accurate than file system date for videos.
                        // Attempt to find and replace the existing creation date if this one is more specific.
                        if let index = details.firstIndex(where: { $0.label == "Created" }) {
                            details[index] = ("Shot On", value, "camera")
                        } else {
                            details.append(("Shot On", value, "camera"))
                        }
                    default:
                        // You could add more cases here if needed, e.g., for "artist", "albumName", etc.
                        break
                    }
                }
            }
            
        } else if let imageSource = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            
            if Task.isCancelled { return [] }

            // --- Image Dimensions ---
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if width > 0 && height > 0 {
                details.append(("Dimensions", "\(width) x \(height)", "arrow.up.left.and.arrow.down.right"))
            }

            // --- EXIF Data ---
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let originalDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    details.append(("Shot On", originalDate, "camera"))
                }
                if let lensModel = exif[kCGImagePropertyExifLensModel] as? String {
                    details.append(("Lens", lensModel, "camera.filters"))
                }
                if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                     details.append(("Aperture", "ƒ/\(String(format: "%.1f", fNumber))", "camera.aperture"))
                }
                if let exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double {
                    details.append(("Exposure", "\(fractionalExposureTime(exposureTime))s", "timer"))
                }
                if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
                    details.append(("ISO", "\(iso)", "camera.metering.matrix"))
                }
            }

            // --- TIFF Data for Camera Model ---
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
                let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
                if !make.isEmpty || !model.isEmpty {
                    details.append(("Device", "\(make) \(model)".trimmingCharacters(in: .whitespaces), "camera.shutter.button"))
                }
            }
        }
        
        return details
    }

    private func fractionalExposureTime(_ exposureTime: Double) -> String {
        if exposureTime < 1.0 {
            return "1/\(Int(1.0 / exposureTime))"
        } else {
            return String(format: "%.2f", exposureTime)
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: interval) ?? "0:00"
    }
}

struct ContentUnavailableView: View {
    let label: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 60, weight: .thin))
                .foregroundColor(.secondary.opacity(0.3))
            
            Text(label)
                .font(.system(.title3, design: .rounded))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
} 