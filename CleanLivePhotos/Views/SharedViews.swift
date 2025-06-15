import SwiftUI
#if os(macOS)
import AppKit
#endif

struct FooterView: View {
    let groups: [FileGroup]
    var onDelete: () -> Void
    var onGoHome: () -> Void

    private var filesToDelete: [DisplayFile] {
        groups.flatMap { $0.files }.filter { if case .delete = $0.action { return true } else { return false } }
    }
    
    private var filesToRename: [DisplayFile] {
        groups.flatMap { $0.files }.filter { if case .keepAndRename = $0.action { return true } else { return false } }
    }
    
    private var totalSizeToDelete: Int64 {
        filesToDelete.reduce(0) { $0 + $1.size }
    }
    
    var body: some View {
        let hasActions = !filesToDelete.isEmpty || !filesToRename.isEmpty
        
        VStack(spacing: 12) {
            Divider()
                .padding(.bottom, 8)

            if hasActions {
                VStack(spacing: 8) {
                    if !filesToDelete.isEmpty {
                        Text("Will delete \(filesToDelete.count) file(s), reclaiming \(ByteCountFormatter.string(fromByteCount: totalSizeToDelete, countStyle: .file)).")
                    }
                    if !filesToRename.isEmpty {
                        Text("Will repair \(filesToRename.count) file pair(s) by renaming.")
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("No redundant files found to clean or repair.")
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 15) {
                Button(action: onGoHome) {
                    HStack {
                        Image(systemName: "house.fill")
                        Text("Start Over")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.4))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .shadow(radius: 5)
                }
                .buttonStyle(PlainButtonStyle())

                if hasActions {
                    Button(action: onDelete) {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver.fill")
                            Text("Execute Plan")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.9))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .shadow(radius: 5)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .animation(.easeInOut, value: hasActions)
    }
}

struct NoResultsView: View {
    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            Text("All Clean!")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text("Your folder is perfectly organized. No duplicates found.")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        Spacer()
    }
}

struct ErrorView: View {
    let message: String
    var onDismiss: () -> Void
    
    @State private var didCopy: Bool = false

    var body: some View {
        Spacer()
        VStack(spacing: 20) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 80))
                .foregroundColor(.red)
            
            Text("An Error Occurred")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            // Use a TextEditor for scrollable, selectable text
            TextEditor(text: .constant(message))
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.black.opacity(0.2))
                .cornerRadius(8)
                .frame(minHeight: 100, maxHeight: 300)
                .shadow(radius: 5)
            
            HStack(spacing: 15) {
                Button(action: {
                    #if os(macOS)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(message, forType: .string)
                    #endif
                    withAnimation {
                        didCopy = true
                    }
                    // Reset the text after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            didCopy = false
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        Text(didCopy ? "Copied!" : "Copy Details")
                    }
                    .padding()
                    .frame(height: 44)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onDismiss) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Start Over")
                    }
                    .padding()
                    .frame(height: 44)
                    .background(Color.green.opacity(0.8))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(40)
        Spacer()
    }
}

// MARK: - Reusable UI Components

struct CloseButton: View {
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .padding(12)
                .background(.regularMaterial)
                .foregroundColor(.primary)
                .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .padding()
        .transition(.opacity.animation(.easeInOut))
    }
}

// MARK: - Window Configuration Helper
#if os(macOS)
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif 