import SwiftUI

struct BreadcrumbItem: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
}

struct VisualizationContainer: View {
    @EnvironmentObject var appState: AppState
    @State private var currentPath: String?
    @State private var breadcrumbs: [BreadcrumbItem] = []
    @State private var childNodes: [FileNode] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb bar
            breadcrumbBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            // Visualization content
            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if childNodes.isEmpty {
                emptyState
            } else {
                TreemapView(nodes: childNodes) { node in
                    drillDown(to: node)
                }
            }
        }
        .task {
            await loadRoot()
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button {
                Task { await loadRoot() }
            } label: {
                Image(systemName: "house.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(breadcrumbs.isEmpty)

            if !breadcrumbs.isEmpty {
                ForEach(breadcrumbs) { crumb in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Button(crumb.name) {
                        navigateTo(crumb)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .lineLimit(1)
                }
            } else {
                Text("Root")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(childNodes.count) items")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Data to Visualize")
                .font(.title3)
            Text("Run a scan first to see disk usage visualization")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadRoot() async {
        isLoading = true
        breadcrumbs = []
        currentPath = nil

        do {
            if let root = try await appState.fileRepository.rootNode() {
                currentPath = root.path
                childNodes = try await appState.fileRepository.childrenWithSizes(ofPath: root.path)
                breadcrumbs = []
            } else {
                childNodes = []
            }
        } catch {
            childNodes = []
        }

        isLoading = false
    }

    private func drillDown(to node: FileNode) {
        guard node.isDirectory else { return }

        Task {
            isLoading = true

            // Add current to breadcrumbs
            if let currentPath = currentPath {
                let name = breadcrumbs.isEmpty
                    ? (appState.scanRootPath?.lastPathComponent ?? "Root")
                    : URL(fileURLWithPath: currentPath).lastPathComponent
                if !breadcrumbs.contains(where: { $0.path == currentPath }) {
                    breadcrumbs.append(BreadcrumbItem(id: currentPath, name: name, path: currentPath))
                }
            }

            currentPath = node.path
            do {
                childNodes = try await appState.fileRepository.childrenWithSizes(ofPath: node.path)
            } catch {
                childNodes = []
            }
            isLoading = false
        }
    }

    private func navigateTo(_ crumb: BreadcrumbItem) {
        Task {
            isLoading = true

            // Remove breadcrumbs after this one
            if let index = breadcrumbs.firstIndex(where: { $0.id == crumb.id }) {
                breadcrumbs = Array(breadcrumbs.prefix(index))
            }

            currentPath = crumb.path
            do {
                childNodes = try await appState.fileRepository.childrenWithSizes(ofPath: crumb.path)
            } catch {
                childNodes = []
            }
            isLoading = false
        }
    }
}
