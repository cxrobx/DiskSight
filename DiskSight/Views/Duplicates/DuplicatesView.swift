import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var progress: DuplicateProgress?
    @State private var scanTask: Task<Void, Never>?
    @State private var showConfirmTrash = false
    @State private var filesToTrash: [FileNode] = []

    private var duplicateGroups: [DuplicateGroup] { appState.duplicateGroups ?? [] }

    var totalReclaimable: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            if isScanning {
                scanningView
            } else if duplicateGroups.isEmpty {
                emptyState
            } else {
                duplicatesList
            }
        }
        .alert("Move to Trash?", isPresented: $showConfirmTrash) {
            Button("Move to Trash", role: .destructive) {
                trashFiles(filesToTrash)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(filesToTrash.count) file(s) to Trash? This can be undone from Trash.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicates")
                    .font(.headline)
                if !duplicateGroups.isEmpty {
                    Text("\(duplicateGroups.count) groups | \(SizeFormatter.format(totalReclaimable)) reclaimable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isScanning {
                Button("Cancel") {
                    scanTask?.cancel()
                    isScanning = false
                }
                .controlSize(.small)
            } else {
                Button {
                    startDuplicateScan()
                } label: {
                    Label("Find Duplicates", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            if let p = progress {
                Text(p.stage.rawValue)
                    .font(.headline)

                if p.totalFiles > 0 {
                    ProgressView(value: Double(p.filesProcessed), total: Double(p.totalFiles))
                        .frame(maxWidth: 300)
                    Text("\(p.filesProcessed) / \(p.totalFiles) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if p.bytesProcessed > 0 {
                    Text("\(SizeFormatter.format(p.bytesProcessed)) processed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Duplicates Found")
                .font(.title3)
            Text("Click 'Find Duplicates' to scan for duplicate files")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Duplicates List

    private var duplicatesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Reclaimable banner
                GroupBox {
                    HStack {
                        Image(systemName: "arrow.3.trianglepath")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SizeFormatter.format(totalReclaimable))
                                .font(.title3.bold())
                            Text("reclaimable from \(duplicateGroups.count) duplicate groups")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(4)
                }

                ForEach(duplicateGroups) { group in
                    DuplicateGroupCard(group: group) { files in
                        filesToTrash = files
                        showConfirmTrash = true
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private func startDuplicateScan() {
        isScanning = true
        let finder = DuplicateFinder(repository: appState.fileRepository)

        scanTask = Task {
            let stream = await finder.findDuplicates()
            for await p in stream {
                self.progress = p
            }

            do {
                appState.duplicateGroups = try await finder.getDuplicateGroups()
            } catch {
                appState.presentAlert(
                    title: "Duplicate Scan Failed",
                    message: "DiskSight could not load duplicate groups. \(error.localizedDescription)"
                )
            }
            self.isScanning = false
        }
    }

    private func trashFiles(_ files: [FileNode]) {
        Task {
            let result = await appState.trashIndexedPaths(
                files.map(\.path),
                actionName: "removing duplicate files"
            )
            guard result.deletedCount > 0 else { return }

            await appState.refreshAfterIndexedFileMutation()
            let finder = DuplicateFinder(repository: appState.fileRepository)
            do {
                appState.duplicateGroups = try await finder.getDuplicateGroups()
            } catch {
                appState.presentAlert(
                    title: "Duplicate Refresh Failed",
                    message: "DiskSight moved the files, but could not refresh duplicate groups. \(error.localizedDescription)"
                )
            }
        }
    }
}

struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let onTrash: ([FileNode]) -> Void

    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(group.files.count) copies")
                            .font(.subheadline.bold())
                        Text("\(SizeFormatter.format(group.fileSize)) each | \(SizeFormatter.format(group.reclaimableSize)) reclaimable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }

                if isExpanded {
                    Divider()

                    ForEach(group.files, id: \.path) { file in
                        HStack {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name)
                                    .font(.caption.bold())
                                Text(file.path)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if let modified = file.modifiedAt {
                                Text(Date(timeIntervalSince1970: modified).relativeString)
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Keep Newest") {
                            keepNewest()
                        }
                        .controlSize(.small)

                        Button("Trash All But First") {
                            let toTrash = Array(group.files.dropFirst())
                            onTrash(toTrash)
                        }
                        .controlSize(.small)
                        .tint(.red)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(4)
        }
    }

    private func keepNewest() {
        let sorted = group.files.sorted { ($0.modifiedAt ?? 0) > ($1.modifiedAt ?? 0) }
        let toTrash = Array(sorted.dropFirst())
        onTrash(toTrash)
    }
}
