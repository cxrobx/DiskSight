import SwiftUI

struct SettingsView: View {
    @AppStorage("visualizationMode") private var defaultVizMode: VisualizationMode = .treemap
    @AppStorage("monitoringEnabled") private var monitoringEnabled = true
    @AppStorage("staleThreshold") private var staleThreshold: String = StaleThreshold.oneYear.rawValue

    var body: some View {
        Form {
            Section("Visualization") {
                Picker("Default mode", selection: $defaultVizMode) {
                    ForEach(VisualizationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            Section("Monitoring") {
                Toggle("Enable real-time monitoring", isOn: $monitoringEnabled)
                Text("When enabled, DiskSight watches for file changes after a scan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stale Files") {
                Picker("Default threshold", selection: $staleThreshold) {
                    ForEach(StaleThreshold.allCases) { threshold in
                        Text(threshold.rawValue).tag(threshold.rawValue)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Build", value: "1")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 350)
    }
}
