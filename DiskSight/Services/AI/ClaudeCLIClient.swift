import Foundation

enum CleanupLLMProvider: String, CaseIterable, Identifiable {
    case ollama
    case claudeHeadless

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama:
            return "Ollama"
        case .claudeHeadless:
            return "Claude CLI"
        }
    }

    var shortLabel: String {
        switch self {
        case .ollama:
            return "Ollama"
        case .claudeHeadless:
            return "Claude"
        }
    }

    var detail: String {
        switch self {
        case .ollama:
            return "Use a local Ollama model for enhanced file explanations."
        case .claudeHeadless:
            return "Use the installed Claude CLI in headless mode and your Claude subscription."
        }
    }
}

enum ClaudeCLIStatus {
    case available(version: String?)
    case unavailable(message: String)
}

enum CleanupLLMResponseParser {
    static func parseAnalysis(from text: String) -> [LLMFileAnalysis] {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { item in
            guard let path = item["path"] as? String,
                  let explanation = item["explanation"] as? String else {
                return nil
            }

            let category = (item["category"] as? String).flatMap { FileCategoryType(rawValue: $0) }
            let confidence = (item["confidence"] as? String).flatMap { DeletionConfidence(rawValue: $0) }

            return LLMFileAnalysis(
                filePath: path,
                category: category,
                confidence: confidence,
                explanation: explanation
            )
        }
    }
}

actor ClaudeCLIClient: CleanupLLMServing {
    private struct ProcessOutput {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private enum ClaudeCLIError: LocalizedError {
        case timedOut
        case commandFailed(exitCode: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "The Claude CLI timed out."
            case .commandFailed(let exitCode, let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = trimmed.lowercased()
                if normalized.contains("not found") || normalized.contains("no such file") {
                    return "The `claude` CLI was not found in PATH."
                }
                if trimmed.isEmpty {
                    return "The Claude CLI exited with status \(exitCode)."
                }
                return trimmed
            }
        }
    }

    private let timeout: TimeInterval

    init(timeout: TimeInterval = 180) {
        self.timeout = timeout
    }

    func checkAvailability() async -> ClaudeCLIStatus {
        do {
            let output = try await Self.runClaudeCommand(arguments: ["claude", "--version"], timeout: 5)
            let version = [output.stdout, output.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .available(version: version.isEmpty ? nil : version)
        } catch {
            return .unavailable(message: error.localizedDescription)
        }
    }

    func analyzeFiles(
        files: [(path: String, name: String, size: Int64, ext: String)],
        model: String
    ) async -> [LLMFileAnalysis] {
        guard !files.isEmpty else { return [] }

        let prompt = Self.makePrompt(for: files)
        let systemPrompt = """
        You are a file cleanup advisor for macOS.
        Return valid JSON only. Do not include markdown or code fences.
        Use category values exactly as requested.
        Use confidence values exactly: safe, caution, risky, keep.
        """

        var arguments = [
            "claude",
            "--print",
            "--output-format", "json",
            "--no-session-persistence",
            "--max-turns", "1",
            "--system-prompt", systemPrompt
        ]

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments.append(contentsOf: ["--model", trimmedModel])
        }

        arguments.append(contentsOf: ["-p", prompt])

        do {
            let output = try await Self.runClaudeCommand(arguments: arguments, timeout: timeout)
            let responseText = Self.extractResponseText(from: output.stdout)
            return CleanupLLMResponseParser.parseAnalysis(from: responseText)
        } catch {
            return []
        }
    }

    static func buildProcessEnvironment(_ environment: [String: String]) -> [String: String] {
        var env = environment
        let extraPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let existingPaths = Set(currentPath.split(separator: ":").map(String.init))
        let missingPaths = extraPaths.filter { !existingPaths.contains($0) }
        if !missingPaths.isEmpty {
            env["PATH"] = missingPaths.joined(separator: ":") + ":" + currentPath
        }
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_PROJECT")
        return env
    }

    static func extractResponseText(from stdout: String) -> String {
        let stripped = stdout
            .replacingOccurrences(
                of: #"\x1b\].*?(?:\x07|\x1b\\)"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let jsonString: String
        if let jsonStart = stripped.firstIndex(of: "{"),
           let jsonEnd = stripped.lastIndex(of: "}") {
            jsonString = String(stripped[jsonStart...jsonEnd])
        } else {
            jsonString = stripped
        }

        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return stripped
        }

        if let result = object["result"] as? String,
           !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return result
        }

        if let text = object["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        return jsonString
    }

    private static func makePrompt(
        for files: [(path: String, name: String, size: Int64, ext: String)]
    ) -> String {
        let fileList = files.prefix(50).map { file in
            "- \(file.name) (\(SizeFormatter.format(file.size))) at \(file.path)"
        }.joined(separator: "\n")

        return """
        Analyze these files and respond with a JSON array.
        Each element must include:
        - "path" (string)
        - "category" (one of: Build Artifact, Cache, Log, Temporary, Download, Media, Document, Source Code, Package Manager, Backup, System Data, Unknown)
        - "confidence" (one of: safe, caution, risky, keep)
        - "explanation" (brief reason, max 100 chars)

        Files:
        \(fileList)
        """
    }

    private static func runClaudeCommand(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        try await Task.detached(priority: .userInitiated) {
            try Self.runClaudeCommandSync(arguments: arguments, timeout: timeout)
        }.value
    }

    private static func runClaudeCommandSync(
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = buildProcessEnvironment(ProcessInfo.processInfo.environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let startedAt = Date()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date().timeIntervalSince(startedAt) > timeout {
                process.terminate()
                throw ClaudeCLIError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let result = ProcessOutput(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)

        guard result.exitCode == 0 else {
            throw ClaudeCLIError.commandFailed(
                exitCode: result.exitCode,
                message: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }

        return result
    }
}
