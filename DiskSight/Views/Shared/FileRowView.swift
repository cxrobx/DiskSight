import SwiftUI

struct FileRowView: View {
    let file: FileNode
    var showPath: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                if showPath, let parent = file.parentPath {
                    Text(parent)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if let modified = file.modifiedAt {
                Text(Date(timeIntervalSince1970: modified).relativeString)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }

            Text(SizeFormatter.format(file.size))
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
        }
    }

    private var iconName: String {
        if file.isDirectory { return "folder.fill" }
        let type = file.fileType?.lowercased() ?? ""
        if type.contains("image") { return "photo" }
        if type.contains("video") { return "film" }
        if type.contains("audio") { return "music.note" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("text") { return "doc.text" }
        if type.contains("zip") || type.contains("archive") { return "archivebox" }
        return "doc.fill"
    }

    private var iconColor: Color {
        if file.isDirectory { return .blue }
        let type = file.fileType?.lowercased() ?? ""
        if type.contains("image") { return .green }
        if type.contains("video") { return .purple }
        if type.contains("audio") { return .orange }
        return .secondary
    }
}
