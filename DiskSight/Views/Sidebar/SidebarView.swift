import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedSection) {
            Section("Analyze") {
                ForEach([SidebarSection.overview, .visualization]) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }

            Section("Clean Up") {
                ForEach([SidebarSection.duplicates, .staleFiles, .cache]) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }

            Section {
                scanControlView
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DiskSight")
    }

    @ViewBuilder
    private var scanControlView: some View {
        switch appState.scanState {
        case .idle:
            Button {
                selectAndScan()
            } label: {
                Label("Scan Folder...", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.borderless)

        case .scanning(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(progress.filesScanned.formatted()) files")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: progress.totalSize, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !progress.currentPath.isEmpty {
                    Text(progress.currentPath)
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Cancel", role: .cancel) {
                    appState.cancelScan()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

        case .completed:
            VStack(alignment: .leading, spacing: 4) {
                Label("Scan Complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Button {
                    selectAndScan()
                } label: {
                    Label("Rescan...", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button {
                    selectAndScan()
                } label: {
                    Label("Retry...", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private func selectAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to analyze"
        panel.prompt = "Scan"

        if panel.runModal() == .OK, let url = panel.url {
            appState.scanRootPath = url
            appState.startScan(at: url)
        }
    }
}
