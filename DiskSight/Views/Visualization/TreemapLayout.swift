import Foundation

struct TreemapRect: Identifiable {
    let id: String
    let node: FileNode
    let rect: CGRect
    let depth: Int

    var color: (r: Double, g: Double, b: Double) {
        TreemapColor.forNode(node)
    }
}

enum TreemapColor {
    /// Distinct palette for directories — each gets a unique color based on name hash
    private static let directoryPalette: [(r: Double, g: Double, b: Double)] = [
        (0.35, 0.58, 0.87),  // blue
        (0.30, 0.72, 0.49),  // green
        (0.82, 0.45, 0.45),  // red
        (0.60, 0.45, 0.82),  // purple
        (0.90, 0.62, 0.25),  // orange
        (0.25, 0.72, 0.72),  // teal
        (0.80, 0.55, 0.70),  // pink
        (0.55, 0.70, 0.35),  // lime
        (0.72, 0.58, 0.35),  // brown
        (0.45, 0.60, 0.72),  // steel
        (0.75, 0.42, 0.60),  // magenta
        (0.40, 0.68, 0.60),  // sage
    ]

    static func forNode(_ node: FileNode) -> (r: Double, g: Double, b: Double) {
        if node.isDirectory {
            return forDirectory(name: node.name)
        }
        return forFileType(node.fileType)
    }

    static func forDirectory(name: String) -> (r: Double, g: Double, b: Double) {
        let hash = name.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(hash) % directoryPalette.count
        return directoryPalette[index]
    }

    static func forFileType(_ type: String?) -> (r: Double, g: Double, b: Double) {
        guard let type = type?.lowercased() else { return (0.5, 0.5, 0.5) }

        if type.contains("image") || type.contains("png") || type.contains("jpeg") || type.contains("gif") {
            return (0.33, 0.75, 0.44) // green
        } else if type.contains("video") || type.contains("movie") || type.contains("mpeg") {
            return (0.65, 0.35, 0.80) // purple
        } else if type.contains("audio") || type.contains("mp3") || type.contains("aac") {
            return (0.95, 0.60, 0.20) // orange
        } else if type.contains("text") || type.contains("document") || type.contains("pdf") {
            return (0.30, 0.55, 0.90) // blue
        } else if type.contains("zip") || type.contains("archive") || type.contains("gzip") || type.contains("tar") {
            return (0.85, 0.35, 0.35) // red
        } else if type.contains("source") || type.contains("swift") || type.contains("json") || type.contains("xml") {
            return (0.25, 0.75, 0.75) // teal
        } else if type.contains("executable") || type.contains("application") {
            return (0.75, 0.55, 0.35) // brown
        }
        return (0.50, 0.50, 0.55) // default gray
    }
}

enum TreemapAlgorithm {
    /// Squarified treemap algorithm — produces rectangles with good aspect ratios
    static func layout(nodes: [FileNode], in rect: CGRect, depth: Int = 0) -> [TreemapRect] {
        guard !nodes.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        let totalSize = nodes.reduce(Int64(0)) { $0 + max($1.size, 0) }
        guard totalSize > 0 else { return [] }

        var results: [TreemapRect] = []
        var remaining = nodes.sorted { $0.size > $1.size }
        var currentRect = rect

        while !remaining.isEmpty {
            let (row, rest) = squarify(
                remaining: remaining,
                totalSize: totalSize,
                containerRect: currentRect
            )

            let rowSize = row.reduce(Int64(0)) { $0 + max($1.size, 0) }
            let isHorizontal = currentRect.width >= currentRect.height
            let rowFraction = Double(rowSize) / Double(totalSize) * (isHorizontal ? Double(rect.width) : Double(rect.height))

            var offset: CGFloat = 0
            let rowLength = isHorizontal ? CGFloat(rowFraction) : currentRect.width
            let rowBreadth = isHorizontal ? currentRect.height : CGFloat(rowFraction)

            for node in row {
                let fraction = rowSize > 0 ? CGFloat(max(node.size, 0)) / CGFloat(rowSize) : 0
                let itemLength = (isHorizontal ? rowBreadth : rowLength) * fraction

                let itemRect: CGRect
                if isHorizontal {
                    itemRect = CGRect(
                        x: currentRect.minX,
                        y: currentRect.minY + offset,
                        width: rowLength,
                        height: itemLength
                    )
                    offset += itemLength
                } else {
                    itemRect = CGRect(
                        x: currentRect.minX + offset,
                        y: currentRect.minY,
                        width: itemLength,
                        height: rowBreadth
                    )
                    offset += itemLength
                }

                if itemRect.width >= 1 && itemRect.height >= 1 {
                    results.append(TreemapRect(
                        id: node.path,
                        node: node,
                        rect: itemRect,
                        depth: depth
                    ))
                }
            }

            // Shrink the remaining area
            if isHorizontal {
                currentRect = CGRect(
                    x: currentRect.minX + rowLength,
                    y: currentRect.minY,
                    width: currentRect.width - rowLength,
                    height: currentRect.height
                )
            } else {
                currentRect = CGRect(
                    x: currentRect.minX,
                    y: currentRect.minY + rowBreadth,
                    width: currentRect.width,
                    height: currentRect.height - rowBreadth
                )
            }

            remaining = rest
        }

        return results
    }

    private static func squarify(
        remaining: [FileNode],
        totalSize: Int64,
        containerRect: CGRect
    ) -> (row: [FileNode], rest: [FileNode]) {
        guard !remaining.isEmpty else { return ([], []) }

        let shorter = min(containerRect.width, containerRect.height)
        guard shorter > 0 else { return (remaining, []) }

        var row: [FileNode] = []
        var bestAspect = CGFloat.infinity

        for (i, node) in remaining.enumerated() {
            let candidate = row + [node]
            let candidateSize = candidate.reduce(Int64(0)) { $0 + max($1.size, 0) }
            let candidateFraction = CGFloat(candidateSize) / CGFloat(totalSize)
            let rowLength = candidateFraction * (containerRect.width >= containerRect.height ? containerRect.width : containerRect.height)

            guard rowLength > 0 else {
                row.append(node)
                continue
            }

            var worstAspect: CGFloat = 0
            for item in candidate {
                let itemFraction = CGFloat(max(item.size, 0)) / CGFloat(candidateSize)
                let itemBreadth = itemFraction * shorter
                guard itemBreadth > 0 else { continue }
                let aspect = max(rowLength / itemBreadth, itemBreadth / rowLength)
                worstAspect = max(worstAspect, aspect)
            }

            if worstAspect <= bestAspect || row.isEmpty {
                row.append(node)
                bestAspect = worstAspect
            } else {
                return (row, Array(remaining[i...]))
            }
        }

        return (row, [])
    }
}
