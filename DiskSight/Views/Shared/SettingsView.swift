import SwiftUI
import Sparkle

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    let updater: SPUUpdater

    @AppStorage("visualizationMode") private var defaultVizMode: VisualizationMode = .treemap
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue
    @AppStorage("monitoringEnabled") private var monitoringEnabled = true
    @AppStorage("staleThreshold") private var staleThreshold: String = StaleThreshold.oneYear.rawValue
    @AppStorage("llmEnabled") private var llmEnabled = false
    @AppStorage("ollamaURL") private var ollamaURL = "http://localhost:11434"
    @AppStorage("ollamaModel") private var ollamaModel = ""
    @State private var ollamaTestResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
            }

            Section("Visualization") {
                Picker("Default mode", selection: $defaultVizMode) {
                    ForEach(VisualizationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Toggle("Hide external drives", isOn: $appState.hideExternalDrives)
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

            Section("Smart Cleanup") {
                Toggle("Enable LLM enhancement", isOn: $llmEnabled)
                Text("Use a local Ollama model for enhanced file explanations")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if llmEnabled {
                    TextField("Ollama URL", text: $ollamaURL)
                        .textFieldStyle(.roundedBorder)

                    TextField("Model name", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(isTesting)

                        if let result = ollamaTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.contains("Connected") ? .green : .red)
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
            }

            Section("Updates") {
                HStack {
                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }

                    Spacer()

                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 500)
    }

    private func testConnection() {
        isTesting = true
        ollamaTestResult = nil
        Task {
            let client = OllamaClient(baseURL: ollamaURL)
            let status = await client.checkAvailability()
            await MainActor.run {
                switch status {
                case .available(let models):
                    ollamaTestResult = "Connected — \(models.count) model(s) available"
                case .unavailable:
                    ollamaTestResult = "Connection failed — is Ollama running?"
                }
                isTesting = false
            }
        }
    }
}
