import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    let onScanSelected: (URL) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Welcome to DiskSight")
                .font(.largeTitle.bold())

            Text("Analyze your disk usage with powerful visualizations, find duplicates, and reclaim wasted space.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "square.grid.3x3.fill", title: "Visualize", description: "Treemap, sunburst, and icicle charts")
                featureRow(icon: "doc.on.doc", title: "Find Duplicates", description: "3-stage detection with smart hashing")
                featureRow(icon: "clock.arrow.circlepath", title: "Stale Files", description: "Find files you haven't used in years")
                featureRow(icon: "internaldrive", title: "Cache Cleanup", description: "Safely reclaim cache space")
                featureRow(icon: "arrow.triangle.2.circlepath", title: "Real-time Monitoring", description: "Keep your index current via FSEvents")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.3)))

            // Full Disk Access note
            GroupBox {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full Disk Access Recommended")
                            .font(.caption.bold())
                        Text("For complete analysis, grant access in System Settings > Privacy & Security")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .controlSize(.small)
                }
                .padding(4)
            }
            .frame(maxWidth: 500)

            HStack(spacing: 16) {
                Button("Select Folder to Scan") {
                    selectFolder()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Skip for Now") {
                    isPresented = false
                }
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(width: 600, height: 680)
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold())
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to analyze"
        panel.prompt = "Scan"

        if panel.runModal() == .OK, let url = panel.url {
            onScanSelected(url)
            isPresented = false
        }
    }
}
