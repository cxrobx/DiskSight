import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            if case .scanning(let progress) = appState.scanState {
                scanningView(progress: progress)
            } else if appState.scanState == .completed || appState.lastScanSession != nil {
                completedView
            } else {
                emptyStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func scanningView(progress: ScanProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning...")
                .font(.title2)
            Text("\(progress.filesScanned.formatted()) files found")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: progress.totalSize, countStyle: .file))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            if !progress.currentPath.isEmpty {
                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }
        }
    }

    private var completedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Scan Complete")
                .font(.title2)
            if let session = appState.lastScanSession {
                VStack(spacing: 8) {
                    Text("Root: \(session.rootPath)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let count = session.fileCount {
                        Text("\(count.formatted()) files indexed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let size = session.totalSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.headline)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Scan Data")
                .font(.title2)
            Text("Select a folder to analyze disk usage")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !appState.hasFullDiskAccess {
                GroupBox {
                    VStack(spacing: 8) {
                        Label("Full Disk Access Recommended", systemImage: "exclamationmark.shield")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        Text("Grant Full Disk Access in System Settings > Privacy & Security to scan all folders.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(8)
                }
                .frame(maxWidth: 400)
            }
        }
    }
}
