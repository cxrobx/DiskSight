import SwiftUI

struct StaleFilesView: View {
    @EnvironmentObject var appState: AppState
    @State private var staleFiles: [FileNode] = []
    @State private var selectedThreshold: StaleThreshold = .oneYear
    @State private var isLoading = false
    @State private var showConfirmTrash = false
    @State private var filesToTrash: [FileNode] = []

    var totalSize: Int64 {
        staleFiles.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            if isLoading {
                ProgressView("Finding stale files...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if staleFiles.isEmpty {
                emptyState
            } else {
                staleFilesList
            }
        }
        .task {
            await loadStaleFiles()
        }
        .onChange(of: selectedThreshold) {
            Task { await loadStaleFiles() }
        }
        .alert("Move to Trash?", isPresented: $showConfirmTrash) {
            Button("Move to Trash", role: .destructive) {
                trashFiles(filesToTrash)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(filesToTrash.count) file(s) to Trash?")
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stale Files")
                    .font(.headline)
                if !staleFiles.isEmpty {
                    Text("\(staleFiles.count) files | \(SizeFormatter.format(totalSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("Not accessed in:", selection: $selectedThreshold) {
                ForEach(StaleThreshold.allCases) { threshold in
                    Text(threshold.rawValue).tag(threshold)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Stale Files Found")
                .font(.title3)
            Text("No files older than \(selectedThreshold.rawValue.lowercased()) and larger than 1 MB")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var staleFilesList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                // Summary banner
                GroupBox {
                    HStack {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SizeFormatter.format(totalSize))
                                .font(.title3.bold())
                            Text("\(staleFiles.count) files not accessed in \(selectedThreshold.rawValue.lowercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(4)
                }

                ForEach(staleFiles, id: \.path) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.caption.bold())
                            Text(file.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        if let accessed = file.accessedAt {
                            Text(Date(timeIntervalSince1970: accessed).relativeString)
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }

                        Text(SizeFormatter.format(file.size))
                            .font(.caption.monospacedDigit())
                            .frame(width: 70, alignment: .trailing)

                        Button {
                            filesToTrash = [file]
                            showConfirmTrash = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                }
            }
            .padding(16)
        }
    }

    private func loadStaleFiles() async {
        isLoading = true
        let finder = StaleFinder(repository: appState.fileRepository)
        staleFiles = (try? await finder.findStaleFiles(threshold: selectedThreshold)) ?? []
        isLoading = false
    }

    private func trashFiles(_ files: [FileNode]) {
        Task {
            for file in files {
                let url = URL(fileURLWithPath: file.path)
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    try await appState.fileRepository.deleteFile(path: file.path)
                } catch {}
            }
            await loadStaleFiles()
        }
    }
}
