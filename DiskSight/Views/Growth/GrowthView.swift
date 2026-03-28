import SwiftUI

struct GrowthView: View {
    @EnvironmentObject var appState: AppState

    private var folders: [FolderGrowth] { appState.growthFolders ?? [] }
    private var isLoading: Bool { appState.growthLoadingPeriod == appState.growthPeriod && appState.growthFolders == nil }
    private var isRefreshingVisibleData: Bool { appState.growthLoadingPeriod == appState.growthPeriod && appState.growthFolders != nil }

    var totalGrowth: Int64 {
        folders.reduce(0) { $0 + $1.recentGrowthSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            if isLoading {
                ProgressView("Finding recently growing folders...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if folders.isEmpty {
                emptyState
            } else {
                folderList
            }
        }
        .task {
            await appState.loadGrowthData()
        }
        .onChange(of: appState.scanState) { _, newState in
            if newState == .completed {
                Task {
                    await appState.refreshGrowthData()
                }
            }
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent Growth")
                    .font(.headline)
                if !folders.isEmpty {
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                appState.refreshMetrics()
            } label: {
                Label(appState.isSyncing ? "Refreshing..." : "Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(!appState.canRefreshMetrics || appState.isSyncing)

            Picker(
                "Created within:",
                selection: Binding(
                    get: { appState.growthPeriod },
                    set: { appState.switchGrowthPeriod(to: $0) }
                )
            ) {
                ForEach(GrowthPeriod.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Recent Growth")
                .font(.title3)
            Text("No folders have files created in the last \(appState.growthPeriod.rawValue.lowercased())")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                // Summary banner
                GroupBox {
                    HStack {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SizeFormatter.format(totalGrowth))
                                .font(.title3.bold())
                            Text("\(folders.count) folders with new files in the last \(appState.growthPeriod.rawValue.lowercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(4)
                }

                ForEach(folders) { folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.folderName)
                                .font(.caption.bold())
                            Text(folder.folderPath)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        // Growth proportion bar
                        growthBar(proportion: folder.growthProportion)
                            .frame(width: 40, height: 6)

                        // Recent file count badge
                        Text("\(folder.recentFileCount)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.blue.opacity(0.15)))
                            .foregroundStyle(.blue)

                        // Growth size (green, bold)
                        Text("+" + SizeFormatter.format(folder.recentGrowthSize))
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.green)
                            .frame(width: 90, alignment: .trailing)

                        // Total folder size
                        Text(SizeFormatter.format(folder.totalFolderSize))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                }
            }
            .padding(16)
        }
    }

    private func growthBar(proportion: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(.green)
                    .frame(width: max(2, geo.size.width * proportion))
            }
        }
    }

    private var subtitleText: String {
        let summary = "\(folders.count) folders | \(SizeFormatter.format(totalGrowth)) added"
        if isRefreshingVisibleData {
            return summary + " | updating..."
        }
        if appState.isSyncing {
            return summary + " | refreshing live"
        }
        return summary
    }
}
