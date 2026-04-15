#if !targetEnvironment(simulator)
import Foundation
import Gemma4SwiftCore
import MLXLLM
import MLXLMCommon

/// Thin actor over `Gemma4SwiftCore` that addresses two issues Codex
/// flagged in its review of the upstream package:
///
/// 1. **Registration is not actually thread-safe.**
///    `Gemma4Registration.registrationTask` is a plain unsynchronised
///    static variable. Two concurrent callers can race before the
///    write. We only call it from a single `@MainActor` site today,
///    but an actor-owned `ensureRegistered()` makes the invariant
///    explicit and safe if we ever add another caller.
///
/// 2. **`attention_k_eq_v` support is silent.** The upstream
///    `Gemma4TextConfiguration` decodes the flag but never enforces
///    it, so a future Gemma 4 variant with `attention_k_eq_v == true`
///    would load and produce wrong logits. We can't reject it inside
///    Gemma4Registration without forking the package, but we can
///    inspect the model's `config.json` from the HuggingFace cache
///    after the container has loaded and surface an error if the flag
///    is set. That makes the failure loud instead of silent.
///
/// Everything is scoped inside `#if !targetEnvironment(simulator)` so
/// the MLX imports stay out of the simulator build (MLX can't run
/// there — it SIGABRTs on Metal device creation).
actor Gemma4Runtime {

    enum RuntimeError: Error, LocalizedError {
        case attentionKEqVUnsupported

        var errorDescription: String? {
            switch self {
            case .attentionKEqVUnsupported:
                return "This Gemma 4 variant uses attention_k_eq_v which Gemma4SwiftCore doesn't implement. Choose the text 4-bit variant."
            }
        }
    }

    private var registrationTask: Task<Void, Never>?

    /// Register the Gemma 4 handlers exactly once, even under
    /// concurrent callers. Subsequent calls await the first task.
    func ensureRegistered() async {
        if let existing = registrationTask {
            await existing.value
            return
        }
        let task = Task {
            await Gemma4Registration.registerIfNeeded().value
        }
        registrationTask = task
        await task.value
    }

    /// Load the requested Gemma 4 4-bit container. The variant is
    /// chosen by the caller via `Gemma4Variant.forCurrentDevice()` so
    /// the runtime stays oblivious to device-class policy. Progress is
    /// reported via the `onProgress` callback on the `@MainActor`.
    func loadContainer(
        variant: Gemma4Variant,
        onProgress: @MainActor @escaping (Double) -> Void
    ) async throws -> ModelContainer {
        await ensureRegistered()

        let configuration = ModelConfiguration(id: variant.modelId)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { progress in
            Task { @MainActor in
                onProgress(progress.fractionCompleted)
            }
        }

        // After the container has loaded, inspect the model's config
        // and reject variants the upstream code would silently
        // mis-handle.
        try await validateConfig(for: configuration)

        return container
    }

    /// Read the `config.json` that `LLMModelFactory` downloaded for
    /// this model and sanity-check it.
    ///
    /// Codex flagged that the original implementation only looked
    /// inside `~/Documents/huggingface/models/...`, but mlx-swift-lm's
    /// HubApi writes to the app's caches directory by default on
    /// iOS — so the validation almost always took the soft-fail path
    /// and the safety check was effectively disabled. We now probe
    /// every plausible HuggingFaceHub cache location and only soft
    /// fail if `config.json` truly cannot be found. If we DO find
    /// it, the `attention_k_eq_v` check is enforced strictly.
    private func validateConfig(for configuration: ModelConfiguration) async throws {
        let fm = FileManager.default
        let relativePath = "huggingface/models/\(configuration.name)/config.json"
        let searchRoots: [URL] = [
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }

        var configData: Data? = nil
        for root in searchRoots {
            let candidate = root.appending(path: relativePath, directoryHint: .notDirectory)
            if let data = try? Data(contentsOf: candidate) {
                configData = data
                break
            }
        }

        guard let data = configData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Truly couldn't find the config — soft fail rather than
            // crashing the app, but log it so the regression is loud.
            print("[Gemma4Runtime] could not locate config.json for \(configuration.name); attention_k_eq_v check skipped")
            return
        }

        // Top-level or nested under `text_config` depending on model
        // packaging. We check both and fail if either sets the flag.
        if flagIsTrue(in: json, key: "attention_k_eq_v") {
            throw RuntimeError.attentionKEqVUnsupported
        }
        if let text = json["text_config"] as? [String: Any],
           flagIsTrue(in: text, key: "attention_k_eq_v") {
            throw RuntimeError.attentionKEqVUnsupported
        }
    }

    private func flagIsTrue(in dict: [String: Any], key: String) -> Bool {
        if let b = dict[key] as? Bool, b { return true }
        if let n = dict[key] as? NSNumber, n.boolValue { return true }
        return false
    }
}
#endif
