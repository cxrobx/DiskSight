import SwiftUI

struct CacheView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false

    private var detectedCaches: [DetectedCache] { appState.detectedCaches ?? [] }
    @State private var showConfirmClean = false
    @State private var cacheToClean: DetectedCache?

    var totalSize: Int64 {
        detectedCaches.reduce(0) { $0 + $1.totalSize }
    }

    var safeCaches: [DetectedCache] {
        detectedCaches.filter { $0.pattern.safetyLevel == .green }
    }

    var safeSize: Int64 {
        safeCaches.reduce(0) { $0 + $1.totalSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            if isLoading {
                ProgressView("Detecting caches...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if detectedCaches.isEmpty {
                emptyState
            } else {
                cacheList
            }
        }
        .task {
            if detectedCaches.isEmpty && appState.detectedCaches == nil {
                isLoading = true
                await appState.loadCacheData()
                isLoading = false
            }
        }
        .alert("Clean Cache?", isPresented: $showConfirmClean) {
            Button("Clean", role: .destructive) {
                if let cache = cacheToClean {
                    cleanCache(cache)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let cache = cacheToClean {
                Text("Delete \(cache.matchedPaths.count) items (\(SizeFormatter.format(cache.totalSize))) from \(cache.pattern.pattern)?")
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Caches")
                    .font(.headline)
                if !detectedCaches.isEmpty {
                    Text("\(detectedCaches.count) cache locations | \(SizeFormatter.format(totalSize)) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !safeCaches.isEmpty {
                Button {
                    cleanAllSafe()
                } label: {
                    Label("Clean All Safe (\(SizeFormatter.format(safeSize)))", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
            }

            Button {
                Task {
                    appState.detectedCaches = nil
                    isLoading = true
                    await appState.loadCacheData()
                    isLoading = false
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Caches Detected")
                .font(.title3)
            Text("Run a scan first, then come here to find reclaimable cache space")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cache List

    private var cacheList: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Safety legend
                safetyLegend

                // Group by category
                let categories = Dictionary(grouping: detectedCaches) { $0.pattern.category }
                ForEach(categories.keys.sorted(), id: \.self) { category in
                    if let caches = categories[category] {
                        categorySection(name: category, caches: caches)
                    }
                }
            }
            .padding(16)
        }
    }

    private var safetyLegend: some View {
        GroupBox {
            HStack(spacing: 20) {
                safetyBadge(level: .green, description: "Safe to delete, auto-regenerates")
                safetyBadge(level: .yellow, description: "May need reinstall or rebuild")
                safetyBadge(level: .red, description: "Risky, may cause issues")
            }
            .padding(4)
        }
    }

    private func safetyBadge(level: CacheSafety, description: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(colorForSafety(level))
                .frame(width: 10, height: 10)
            Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func categorySection(name: String, caches: [DetectedCache]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            ForEach(caches) { cache in
                CacheCard(cache: cache, safetyColor: colorForSafety(cache.pattern.safetyLevel)) {
                    cacheToClean = cache
                    showConfirmClean = true
                }
            }
        }
    }

    private func colorForSafety(_ level: CacheSafety) -> Color {
        switch level {
        case .green: return .green
        case .yellow: return .orange
        case .red: return .red
        }
    }

    // MARK: - Actions

    private func detectCaches() async {
        isLoading = true
        appState.detectedCaches = nil
        await appState.loadCacheData()
        isLoading = false
    }

    private func cleanCache(_ cache: DetectedCache) {
        Task {
            for path in cache.matchedPaths {
                let url = URL(fileURLWithPath: path)
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                try? await appState.fileRepository.deleteFile(path: path)
            }
            appState.invalidateCache()
            await detectCaches()
        }
    }

    private func cleanAllSafe() {
        Task {
            for cache in safeCaches {
                for path in cache.matchedPaths {
                    let url = URL(fileURLWithPath: path)
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    try? await appState.fileRepository.deleteFile(path: path)
                }
            }
            appState.invalidateCache()
            await detectCaches()
        }
    }
}

struct CacheCard: View {
    let cache: DetectedCache
    let safetyColor: Color
    let onClean: () -> Void

    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(safetyColor)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(cache.pattern.pattern)
                            .font(.caption.bold())
                        if let desc = cache.pattern.description {
                            Text(desc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Text(SizeFormatter.format(cache.totalSize))
                        .font(.subheadline.bold().monospacedDigit())

                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)

                    Button("Clean") {
                        onClean()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }

                if isExpanded {
                    Divider()
                    ForEach(cache.matchedPaths.prefix(20), id: \.self) { path in
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if cache.matchedPaths.count > 20 {
                        Text("... and \(cache.matchedPaths.count - 20) more")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .padding(4)
        }
    }
}
