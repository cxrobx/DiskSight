import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var diskInfo: DiskInfo?

    private var topFolders: [FileNode] { appState.overviewTopFolders ?? [] }
    private var fileCount: Int { appState.overviewFileCount ?? 0 }
    private var totalIndexedSize: Int64 { appState.overviewTotalSize ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if case .scanning(let progress) = appState.scanState {
                    scanningBanner(progress: progress)
                }

                if diskInfo != nil || appState.scanState == .completed {
                    HStack(spacing: 16) {
                        diskUsageCard
                        scanInfoCard
                    }
                    .frame(maxHeight: 200)

                    if !topFolders.isEmpty {
                        topFoldersCard
                    }

                    quickActionsCard
                } else {
                    emptyStateView
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            loadDiskInfo()
            await appState.loadOverviewData()
        }
        .onChange(of: appState.scanState) {
            if appState.scanState == .completed {
                appState.invalidateCache()
                Task { await appState.loadOverviewData() }
            }
        }
    }

    // MARK: - Disk Usage Ring

    private var diskUsageCard: some View {
        GroupBox("Disk Usage") {
            if let info = diskInfo {
                HStack(spacing: 20) {
                    // Ring chart
                    ZStack {
                        Circle()
                            .stroke(.quaternary, lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: info.usedFraction)
                            .stroke(
                                info.usedFraction > 0.9 ? .red : info.usedFraction > 0.75 ? .orange : .blue,
                                style: StrokeStyle(lineWidth: 12, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text("\(Int(info.usedFraction * 100))%")
                                .font(.title2.bold())
                            Text("used")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 100, height: 100)

                    VStack(alignment: .leading, spacing: 8) {
                        diskStatRow(label: "Total", size: info.totalSpace, color: .primary)
                        diskStatRow(label: "Used", size: info.usedSpace, color: .blue)
                        diskStatRow(label: "Free", size: info.freeSpace, color: .green)
                    }
                }
                .padding(8)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func diskStatRow(label: String, size: Int64, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(SizeFormatter.format(size))
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Scan Info

    private var scanInfoCard: some View {
        GroupBox("Scan Status") {
            VStack(alignment: .leading, spacing: 10) {
                if let session = appState.lastScanSession {
                    infoRow(icon: "folder", label: "Root", value: session.rootPath)
                    infoRow(icon: "doc.text", label: "Files", value: fileCount.formatted())
                    infoRow(icon: "internaldrive", label: "Indexed", value: SizeFormatter.format(totalIndexedSize))
                    if let completed = session.completedAt {
                        infoRow(icon: "clock", label: "Scanned", value: Date(timeIntervalSince1970: completed).relativeString)
                    }
                } else {
                    Text("No scan data")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(8)
        }
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Top Folders

    private var topFoldersCard: some View {
        GroupBox("Top Folders by Size") {
            VStack(spacing: 6) {
                let maxSize = topFolders.first?.size ?? 1
                ForEach(topFolders, id: \.path) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text(folder.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 150, alignment: .leading)

                        GeometryReader { geometry in
                            let fraction = CGFloat(folder.size) / CGFloat(maxSize)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.blue.opacity(0.3))
                                .frame(width: geometry.size.width * fraction)
                        }
                        .frame(height: 16)

                        Text(SizeFormatter.format(folder.size))
                            .font(.caption.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Quick Actions

    private var quickActionsCard: some View {
        GroupBox("Quick Actions") {
            HStack(spacing: 12) {
                quickActionButton(icon: "square.grid.3x3.fill", label: "Visualize", section: .visualization)
                quickActionButton(icon: "doc.on.doc", label: "Find Duplicates", section: .duplicates)
                quickActionButton(icon: "internaldrive", label: "Clean Caches", section: .cache)

                Button {
                    appState.exportCSV()
                } label: {
                    VStack(spacing: 6) {
                        if appState.isExportingCSV {
                            ProgressView()
                                .controlSize(.small)
                                .frame(height: 22)
                        } else if appState.csvExportDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                        }
                        Text(appState.isExportingCSV ? "Exporting..." : appState.csvExportDone ? "Exported!" : "Export CSV")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isExportingCSV)
            }
            .padding(8)
        }
    }

    private func quickActionButton(icon: String, label: String, section: SidebarSection) -> some View {
        Button {
            appState.selectedSection = section
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Empty State

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
                fullDiskAccessBanner
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    private var fullDiskAccessBanner: some View {
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

    // MARK: - Scanning Banner

    private func scanningBanner(progress: ScanProgress) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanning...")
                        .font(.subheadline.bold())
                    Text("\(progress.filesScanned.formatted()) files | \(SizeFormatter.format(progress.totalSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    appState.cancelScan()
                }
                .controlSize(.small)
            }
            .padding(4)
        }
    }

    // MARK: - Data Loading

    private func loadDiskInfo() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            diskInfo = DiskInfo(totalSpace: total, freeSpace: free)
        }
    }

}

struct DiskInfo {
    let totalSpace: Int64
    let freeSpace: Int64

    var usedSpace: Int64 { totalSpace - freeSpace }
    var usedFraction: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }
}
