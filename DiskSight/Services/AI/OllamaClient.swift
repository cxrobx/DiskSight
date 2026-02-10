import Foundation

// MARK: - Ollama Status

enum OllamaStatus {
    case available(models: [String])
    case unavailable
}

// MARK: - LLM File Analysis

struct LLMFileAnalysis {
    let filePath: String
    let category: FileCategoryType?
    let confidence: DeletionConfidence?
    let explanation: String
}

// MARK: - Ollama Client

actor OllamaClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: String = "http://localhost:11434") {
        self.baseURL = URL(string: baseURL)!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    /// Check if Ollama is running and list available models.
    func checkAvailability() async -> OllamaStatus {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unavailable
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                // Filter out embedding models — they can't generate text
                let embeddingFamilies: Set<String> = ["nomic-bert", "bert", "all-minilm"]
                let generativeModels = models.filter { model in
                    guard let details = model["details"] as? [String: Any],
                          let families = details["families"] as? [String] else { return true }
                    return !families.contains(where: { embeddingFamilies.contains($0) })
                }
                // Sort by parameter size descending (largest = most capable)
                let sorted = generativeModels.sorted { a, b in
                    let sizeA = Self.parameterSize(from: a)
                    let sizeB = Self.parameterSize(from: b)
                    return sizeA > sizeB
                }
                let names = sorted.compactMap { $0["name"] as? String }
                return names.isEmpty ? .unavailable : .available(models: names)
            }
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    /// Analyze a batch of files using the LLM for classification and explanation.
    func analyzeFiles(files: [(path: String, name: String, size: Int64, ext: String)], model: String) async -> [LLMFileAnalysis] {
        guard !files.isEmpty else { return [] }

        let fileList = files.prefix(50).map { file in
            "- \(file.name) (\(SizeFormatter.format(file.size))) at \(file.path)"
        }.joined(separator: "\n")

        let prompt = """
        You are a file cleanup advisor for macOS. Analyze these files and for each one, respond with a JSON array.
        Each element should have: "path" (string), "category" (one of: Build Artifact, Cache, Log, Temporary, Download, Media, Document, Source Code, Package Manager, Backup, System Data, Unknown), "confidence" (one of: safe, caution, risky, keep), "explanation" (brief reason, max 100 chars).

        Files:
        \(fileList)

        Respond with ONLY the JSON array, no other text.
        """

        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                return []
            }

            return parseAnalysisResponse(responseText, files: files)
        } catch {
            return []
        }
    }

    /// Generate a natural language cleanup summary.
    func generateCleanupSummary(totalSize: Int64, safeSize: Int64, categories: [(String, Int64)], model: String) async -> String? {
        let categoryList = categories.map { "\($0.0): \(SizeFormatter.format($0.1))" }.joined(separator: ", ")

        let prompt = """
        You are a disk cleanup advisor. Summarize these findings in 2-3 sentences:
        - Total reclaimable space: \(SizeFormatter.format(totalSize))
        - Safe to delete: \(SizeFormatter.format(safeSize))
        - Categories: \(categoryList)
        Be concise and helpful. Focus on what the user should prioritize cleaning first.
        """

        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.3]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                return nil
            }
            return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Response Parsing

    /// Extract numeric parameter size (in billions) from Ollama model metadata.
    /// e.g. "32.8B" → 32.8, "1.5B" → 1.5, "137M" → 0.137
    private static func parameterSize(from model: [String: Any]) -> Double {
        guard let details = model["details"] as? [String: Any],
              let sizeStr = details["parameter_size"] as? String else { return 0 }
        let cleaned = sizeStr.trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("B") {
            return Double(cleaned.dropLast()) ?? 0
        } else if cleaned.hasSuffix("M") {
            return (Double(cleaned.dropLast()) ?? 0) / 1000.0
        }
        return 0
    }

    private func parseAnalysisResponse(_ text: String, files: [(path: String, name: String, size: Int64, ext: String)]) -> [LLMFileAnalysis] {
        // Extract JSON array from response (may contain markdown fences)
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { item -> LLMFileAnalysis? in
            guard let path = item["path"] as? String,
                  let explanation = item["explanation"] as? String else { return nil }

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
