import Foundation

extension UsageStore {
    // Custom on-device AI prompt, or nil when the built-in default instructions apply.
    var aiInstructions: String? {
        config?.aiInstructions
    }

    // Whether the on-device AI insight can run at all (macOS 26 + Apple Intelligence),
    // so Settings can hide the instructions editor on systems that never use it.
    var isAIInsightAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return InsightGenerator.isAvailable }
        #endif
        return false
    }

    // Persists custom AI instructions (empty clears back to the default) and regenerates
    // the insight immediately so the user sees the effect of their prompt. Returns the error
    // on failure so the editor can surface it inline instead of flashing a false "Saved".
    func updateAIInstructions(_ text: String) -> String? {
        guard var config else {
            DiagnosticLogger.shared.record(.error, component: "config", code: "ai_instructions_no_config", detail: "no config loaded")
            return "No config loaded to save into."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aiInstructions = trimmed.isEmpty ? nil : trimmed
        do {
            try ConfigLoader.save(config)
            self.config = config
            refreshAIInsight(for: snapshots)
            return nil
        } catch {
            DiagnosticLogger.shared.record(.error, component: "config", code: "ai_instructions_save_failed", detail: diagnosticErrorDetail(error))
            return "Could not save AI instructions: \(error.localizedDescription)"
        }
    }

    // Enriches the overview with an on-device LLM summary when Apple Intelligence is
    // available. The deterministic recommendation is already shown; this only replaces
    // it once ready, and stays nil (rule-based visible) on older systems or failure.
    func refreshAIInsight(for snapshots: [AccountSnapshot]) {
        // FoundationModels only exists in the macOS 26 SDK; when building against an older
        // SDK the generator is compiled out entirely and the rule-based recommendation stays.
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), InsightGenerator.isAvailable else {
            aiInsight = nil
            isGeneratingInsight = false
            return
        }
        let grounding = recommendation
        let instructions = config?.aiInstructions
        // Keep the previous summary visible while regenerating; a token guards against a
        // slower earlier generation overwriting a newer one.
        insightGeneration += 1
        let generation = insightGeneration
        isGeneratingInsight = true
        Task { @MainActor in
            let result = await InsightGenerator.generate(snapshots: snapshots, grounding: grounding, instructions: instructions)
            guard generation == insightGeneration else { return }
            if let result { aiInsight = result }
            isGeneratingInsight = false
        }
        #else
        aiInsight = nil
        isGeneratingInsight = false
        #endif
    }
}
