import Foundation

@MainActor
class FolderTreeNode: ObservableObject, Identifiable {
    let fileNode: FileNode
    let depth: Int
    var id: String { fileNode.path }

    @Published var children: [FolderTreeNode]?  // nil = not loaded, [] = loaded but empty
    @Published var isExpanded: Bool = false

    init(fileNode: FileNode, depth: Int = 0) {
        self.fileNode = fileNode
        self.depth = depth
    }

    func loadChildren(using repository: FileRepository, pathFilter: ((String) -> Bool)? = nil) async {
        guard children == nil else { return }
        do {
            let dirChildren = try repository.directoryChildrenConcurrent(ofPath: fileNode.path)
            let filtered = dirChildren.filter { node in
                pathFilter?(node.path) ?? true
            }
            children = filtered.map { FolderTreeNode(fileNode: $0, depth: depth + 1) }
        } catch {
            children = []
        }
    }

    /// Walk from this node down to targetPath, expanding each ancestor and loading children as needed.
    func expandTo(targetPath: String, using repository: FileRepository, pathFilter: ((String) -> Bool)? = nil) async {
        guard pathFilter?(targetPath) ?? true else { return }
        // If this node IS the target, we're done
        guard targetPath != fileNode.path else { return }

        // Target must be a descendant of this node
        let prefix = fileNode.path.hasSuffix("/") ? fileNode.path : fileNode.path + "/"
        guard targetPath.hasPrefix(prefix) else { return }

        // Ensure children are loaded
        await loadChildren(using: repository, pathFilter: pathFilter)
        isExpanded = true

        // Find the child that is an ancestor of (or is) the target
        guard let children = children else { return }
        for child in children {
            let childPrefix = child.fileNode.path.hasSuffix("/") ? child.fileNode.path : child.fileNode.path + "/"
            if targetPath == child.fileNode.path || targetPath.hasPrefix(childPrefix) {
                await child.expandTo(targetPath: targetPath, using: repository, pathFilter: pathFilter)
                return
            }
        }
    }
}
