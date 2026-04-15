import Foundation
import Tokenizers
#if !targetEnvironment(simulator)
import Gemma4SwiftCore
import MLX
import MLXLLM
import MLXLMCommon
#endif

/// Manages the on-device Gemma 4 E2B model lifecycle and streaming
/// inference.
///
/// Backend: MLX Swift via Gemma4SwiftCore, using
/// `mlx-community/gemma-4-e2b-it-4bit`. The chat-template path is
/// bypassed in favour of `Gemma4PromptFormatter.userTurn` because
/// swift-jinja mangles Gemma 4's `<|turn>` special tokens.
///
/// **Simulator note:** MLX cannot instantiate a Metal device inside
/// the iOS Simulator — `mlx::core::metal::Device::Device()` SIGABRTs
/// because the simulator's software Metal path is missing ops MLX
/// needs. On simulator we stub the model with a canned response that
/// includes a real file patch so the end-to-end flow (prompt → patch
/// parse → Oxc transform → preview) is fully testable without a real
/// device. Real inference runs on iPhone only.
///
/// Expected on-device performance (iPhone 17 Pro, from Swift-gemma4-core README):
/// - Warm load: ~6 s
/// - Memory: 341–392 MB
/// - Time to first token: ~2.8 s
/// - Throughput: 12–14 tok/s
@MainActor
@Observable
final class ModelService {
    var loadProgress: Double = 0
    var loadStatus: String = "not loaded"
    var modelDisplayName: String = "Gemma 4"

    #if targetEnvironment(simulator)
    private var isLoaded = false
    #else
    private var container: ModelContainer?
    private let runtime = Gemma4Runtime()
    private(set) var variant: Gemma4Variant = .e2b
    #endif

    func loadModel() async throws {
        #if targetEnvironment(simulator)
        // Simulator: fake a fast load so the design is testable.
        loadStatus = "simulator stub"
        for i in 1...10 {
            try await Task.sleep(for: .milliseconds(80))
            loadProgress = Double(i) / 10.0
        }
        isLoaded = true
        loadStatus = "ready (simulator stub)"
        #else
        loadStatus = "Registering model"
        loadProgress = 0.02

        // Cap MLX's buffer recycling pool. Without this, MLX accumulates
        // intermediate buffers from prefill activations and the KV cache
        // and the cache can grow to several GB over a single inference,
        // which trips the iOS Jetsam compressor and kills the app
        // (`vm-compressor-thrashing`, confirmed in
        // `/tmp/pucky-crashes/JetsamEvent-2026-04-12-224140.ips` —
        // Pucky was the largest process at ~2.7 GB resident).
        //
        // The MLX docs explicitly call this out: "Adjusting the cache
        // limit is especially advantageous on devices with memory limits
        // (e.g. iOS devices where jetsam limits apply). Many developers
        // find that relatively small cache sizes (e.g., 2 MB) perform
        // just as well as unconstrained cache sizes." We use 8 MB —
        // tight enough that even with the 1.6 GB Gemma 4 weights and
        // KV cache we stay well under the ~3 GB foreground ceiling
        // without the Increased Memory Limit entitlement.
        MLX.GPU.set(cacheLimit: 8 * 1024 * 1024)
        MemoryProbe.snapshot("loadModel.start")

        // Pick the variant based on the device's physical RAM. iPhone
        // 15 Pro and newer ship with at least 8 GB and can host the
        // 4-bit E4B weights with breathing room above the increased
        // memory limit ceiling. Anything smaller stays on E2B.
        let chosen = Gemma4Variant.forCurrentDevice()
        self.variant = chosen
        self.modelDisplayName = chosen.displayName
        let physGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        PuckyLog.chat.notice(
            "[chat] variant=\(chosen.rawValue, privacy: .public) physMemGB=\(physGB, privacy: .public)"
        )

        // Honest progress reporting:
        // - 0%–8%: optimistic warm-up while we're still negotiating
        // - 8%–99%: real download, driven by HuggingFace's progress
        //   callback. Capped at 99% so the UI never sits at 100%
        //   while we're still mounting weights into Metal.
        // - 100%: only set after `loadContainer` returns successfully
        //   AND the bar is about to disappear into the main UI.
        //
        // `Gemma4Runtime` owns the registration + load with proper
        // actor serialization (fixes the thread-safety gap Codex
        // flagged in the upstream Gemma4SwiftCore review) and
        // post-load validation that rejects `attention_k_eq_v` variants.
        self.container = try await runtime.loadContainer(variant: chosen) { [weak self] fraction in
            let scaled = 0.08 + fraction * 0.91     // 8%..99%
            self?.loadProgress = min(0.99, scaled)
            self?.loadStatus = fraction < 1.0
                ? "Downloading \(chosen.displayName) · \(Int(fraction * 100))%"
                : "Mounting \(chosen.displayName)"
        }
        loadProgress = 1.0
        loadStatus = "Ready"
        MemoryProbe.snapshot("loadModel.done")
        #endif
    }

    /// Errors that the inference path can surface to its caller.
    /// Codex flagged that the original implementation yielded
    /// `[Model not loaded]` and `[Error: …]` as ordinary stream
    /// chunks, which made infra failures indistinguishable from
    /// model prose and bypassed the chat-side error handling. The
    /// new path throws these instead so callers can render them as
    /// system messages.
    enum GenerateError: Error, LocalizedError {
        case modelNotLoaded
        case inferenceFailed(any Error)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "The model is not loaded yet. Wait for the loading screen to finish."
            case .inferenceFailed(let underlying):
                return "Inference failed: \(underlying.localizedDescription)"
            }
        }
    }

    /// Stream tokens for a fully-formed Gemma 4 prompt. Prompt
    /// construction (system turn, tool declarations, multi-turn
    /// history, continuation prompts for the agent loop) lives in
    /// `Gemma4ToolPromptBuilder`; this method just runs inference. The
    /// streamed text will contain `<|tool_call>...<tool_call|>`
    /// regions, which the caller filters via `Gemma4StreamingHandler`.
    ///
    /// On simulator we return a canned response that uses the same
    /// native tool format the device path produces, so the parser
    /// gets exercised in both builds.
    ///
    /// Throws `GenerateError.modelNotLoaded` if no container has been
    /// loaded, and `GenerateError.inferenceFailed(...)` if the
    /// underlying MLX call throws mid-generation. Successful streams
    /// finish normally.
    func generate(rawPrompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream<String, any Error> { (continuation: AsyncThrowingStream<String, any Error>.Continuation) in
            let task = Task { [weak self] in
                #if targetEnvironment(simulator)
                _ = self
                _ = rawPrompt
                let response = Self.stubResponse()
                for char in response {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(10))
                    continuation.yield(String(char))
                }
                continuation.finish()
                #else
                guard let container = await self?.container else {
                    continuation.finish(throwing: GenerateError.modelNotLoaded)
                    return
                }

                do {
                    MemoryProbe.snapshot("generate.start promptChars=\(rawPrompt.count)")
                    let tokenIds = await container.encode(rawPrompt)
                    MemoryProbe.snapshot("generate.encoded promptTokens=\(tokenIds.count)")

                    // Bypass `container.generate` and own the
                    // detokenization for two reasons:
                    //
                    // 1. mlx-swift-lm 2.30.6's `NaiveStreamingDetokenizer`
                    //    (used by `container.generate`) does a
                    //    Character-level diff after `startNewSegment()`,
                    //    which can drop the leading character of a
                    //    SentencePiece token. Concretely: it caused
                    //    `import React from 'react'` to be streamed as
                    //    `import React from 'eact'`. We need byte-level
                    //    diffing instead.
                    //
                    // 2. We need to bound the per-step decode work and
                    //    its transient allocations — naïvely re-decoding
                    //    the FULL accumulated token list every step is
                    //    O(n²) work AND O(n) garbage per step, which on
                    //    a 1024-token generation thrashes the iOS VM
                    //    compressor and triggers a Jetsam kill within
                    //    seconds (confirmed: rpages ≈ 172k pages = 2.7 GB,
                    //    reason `vm-compressor-thrashing`).
                    //
                    // `BoundedByteDetokenizer` mirrors
                    // `NaiveStreamingDetokenizer`'s reset-on-newline
                    // strategy (so the per-step `tokenizer.decode` call
                    // only ever sees a short window) but does its diff
                    // in UTF-8 bytes instead of grapheme clusters.
                    //
                    // Gemma 4 official sampling recipe is
                    // `temperature 1.0, top_p 0.95, top_k 64`.
                    // mlx-swift-lm 2.30.6 doesn't expose top_k, so we
                    // use temperature + top_p alone.
                    //
                    // `LMInput` and `GenerateParameters` are constructed
                    // *inside* the `perform` closure so they don't need
                    // to cross the actor isolation boundary (LMInput is
                    // non-Sendable).
                    try await container.perform { context in
                        MemoryProbe.snapshot("generate.perform.enter")
                        let input = LMInput(tokens: MLXArray(tokenIds.map { Int32($0) }))
                        // `maxTokens: 3000` gives the model enough head-
                        // room to write a complete RN screen file in a
                        // single tool call. The on-device probe shows
                        // the KV cache is essentially flat under load
                        // (active footprint moved +13 MB across 1024
                        // generated tokens on Gemma 4 E2B), so even at
                        // 3000 tokens we're well under the headroom
                        // the Increased Memory Limit entitlement gives
                        // us. Capping below this caused silent
                        // truncation: the model started a write_file
                        // call, ran out of budget mid-content, and the
                        // streaming handler swallowed all 1024 tokens
                        // because it never saw a closing `<tool_call|>`.
                        //
                        // We do NOT set `kvBits` even though it would
                        // shrink the cache further: Swift-gemma4-core's
                        // Gemma 4 model layer (commit a98eff80) calls
                        // `update` on the cache instead of
                        // `updateQuantized`, tripping a fatal error in
                        // `MLXLMCommon/KVCache.swift:880` when a
                        // `QuantizedKVCache` is in play. Until upstream
                        // fixes the dispatch we use a plain FP16 KV
                        // cache.
                        let params = GenerateParameters(
                            maxTokens: 3000,
                            temperature: 1.0,
                            topP: 0.95
                        )

                        let stream = try MLXLMCommon.generateTokens(
                            input: input,
                            parameters: params,
                            context: context
                        )

                        var detokenizer = BoundedByteDetokenizer(tokenizer: context.tokenizer)
                        var generated = 0
                        var firstTokenLogged = false
                        for await event in stream {
                            if Task.isCancelled { break }
                            guard case .token(let t) = event else { continue }
                            generated += 1
                            if !firstTokenLogged {
                                MemoryProbe.snapshot("generate.firstToken")
                                firstTokenLogged = true
                            } else if generated.isMultiple(of: 32) {
                                MemoryProbe.snapshot("generate.tokens=\(generated)")
                            }
                            if let chunk = detokenizer.append(token: t),
                               !chunk.isEmpty {
                                continuation.yield(chunk)
                            }
                        }
                        MemoryProbe.snapshot("generate.streamEnd tokens=\(generated)")
                    }
                    MemoryProbe.snapshot("generate.perform.exit")
                    // Drop any cached buffers MLX held onto during
                    // prefill and decode. The 8 MB cache limit set in
                    // `loadModel` already caps the steady state, but
                    // `clearCache()` brings us back to baseline
                    // between user turns so a big prompt doesn't
                    // bleed into the next one.
                    MemoryProbe.snapshot("generate.beforeClearCache")
                    MLX.GPU.clearCache()
                    MemoryProbe.snapshot("generate.afterClearCache")
                    continuation.finish()
                } catch {
                    MemoryProbe.snapshot("generate.error")
                    MLX.GPU.clearCache()
                    continuation.finish(throwing: GenerateError.inferenceFailed(error))
                }
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if targetEnvironment(simulator)
    /// Canned response for the simulator. Uses Gemma 4's NATIVE tool
    /// call format (`<|tool_call>call:write_file{...}<tool_call|>`)
    /// with the special `<|"|>` string delimiter, so the same
    /// `Gemma4StreamingHandler` exercises both the simulator and
    /// device paths.
    private static func stubResponse() -> String {
        let appBody = """
            import React, { useState } from 'react';
            import { View, Text, Pressable, StyleSheet } from 'react-native';

            export default function App() {
              const [count, setCount] = useState(0);
              return (
                <View style={styles.container}>
                  <Text style={styles.title}>Counter</Text>
                  <Text style={styles.count}>{count}</Text>
                  <Pressable style={styles.button} onPress={() => setCount(count + 1)}>
                    <Text style={styles.buttonLabel}>Tap</Text>
                  </Pressable>
                </View>
              );
            }

            const styles = StyleSheet.create({
              container: { flex: 1, backgroundColor: '#13101c', alignItems: 'center', justifyContent: 'center' },
              title: { fontSize: 22, color: '#e8e6e3', marginBottom: 24 },
              count: { fontSize: 64, fontWeight: '300', color: '#ff2199', marginBottom: 32 },
              button: { backgroundColor: '#ff2199', paddingHorizontal: 32, paddingVertical: 12, borderRadius: 24 },
              buttonLabel: { color: '#ffffff', fontWeight: '600' },
            });
            """
        let q = "<|\"|>"
        // Args sorted alphabetically (path < text) to match Gemma 4's
        // training-time emission order so the live tool chip can pick
        // up the filename from the very first bytes of the call.
        return "Building a counter screen.\n<|tool_call>call:write_file{path:\(q)src/App.tsx\(q),text:\(q)\(appBody)\(q)}<tool_call|>"
    }
    #endif
}

/// Streaming detokenizer that mirrors `NaiveStreamingDetokenizer`'s
/// reset-on-newline strategy (so the per-step `tokenizer.decode` call
/// only ever sees a short window of recent tokens — bounded memory,
/// no `vm-compressor-thrashing` Jetsam kills) but does its diff in
/// UTF-8 bytes instead of grapheme clusters.
///
/// The byte-level diff is the important bit: Gemma's tokenizer can
/// emit tokens whose decoded text changes character boundaries when a
/// following token arrives. `NaiveStreamingDetokenizer` diffs by
/// `String.count`, which is based on extended grapheme clusters; that
/// can swallow the leading bytes of the next token after a segment
/// reset, producing corrupt text like `from 'eact'`.
///
/// Memory bound: at most ~one line of tokens in `segmentTokens` at
/// any time. After every newline (or after `segmentResetThreshold`
/// tokens, whichever comes first) the segment resets to a short
/// contextual tail, so peak transient allocation per step is
/// O(line length), not O(generated length).
struct BoundedByteDetokenizer {
    private let tokenizer: Tokenizer
    private var segmentTokens: [Int] = []
    private var emittedPrefixBytes: [UInt8] = []
    private var emissionChunks: [[UInt8]] = []

    /// Hard cap on segment length even if no newline appears. SentencePiece
    /// tokens are typically 1–4 characters, so 32 keeps the per-step decode
    /// to ~64–128 chars, well clear of compressor pressure.
    private let segmentResetThreshold: Int

    /// Keep a small contextual tail when re-anchoring. The important part
    /// is that we preserve the tail's *contextual* decoded bytes from the
    /// full segment, not `decode(tail)` in isolation.
    private let carryTokenCount: Int

    init(
        tokenizer: Tokenizer,
        segmentResetThreshold: Int = 32,
        carryTokenCount: Int = 4
    ) {
        self.tokenizer = tokenizer
        self.segmentResetThreshold = max(1, segmentResetThreshold)
        self.carryTokenCount = max(1, carryTokenCount)
    }

    /// Append a token and return the new text bytes that should be
    /// emitted to the user, or nil if the token didn't produce any
    /// emittable text yet (incomplete UTF-8 sequence).
    mutating func append(token: Int) -> String? {
        segmentTokens.append(token)
        let decoded = tokenizer.decode(tokens: segmentTokens)

        // Hold back if the new bytes don't form a complete unicode
        // scalar yet — the next token will complete the rune.
        if decoded.unicodeScalars.last == "\u{fffd}" {
            emissionChunks.append([])
            return nil
        }

        let decodedBytes = Array(decoded.utf8)
        guard decodedBytes.count >= emittedPrefixBytes.count else {
            emissionChunks.append([])
            return nil
        }
        guard decodedBytes.starts(with: emittedPrefixBytes) else {
            // If the tokenizer revises bytes we already emitted, don't
            // guess. Keep buffering until the next reset point settles it.
            emissionChunks.append([])
            return nil
        }

        let newBytes = Array(decodedBytes.dropFirst(emittedPrefixBytes.count))
        let result = String(bytes: newBytes, encoding: .utf8)
        emittedPrefixBytes = decodedBytes
        emissionChunks.append(newBytes)

        // Reset on a line boundary, or when the segment has grown long
        // enough that the per-step decode would start to dominate.
        if decoded.hasSuffix("\n") || segmentTokens.count >= segmentResetThreshold {
            reanchor()
        }

        return result
    }

    /// Re-anchor on a short suffix, but preserve the suffix bytes exactly
    /// as they appeared in the full contextual decode. Re-decoding the kept
    /// suffix in isolation is what caused `from 'react'` to stream as
    /// `from 'eact'`: the isolated suffix decode can include extra leading
    /// bytes that were never actually emitted.
    private mutating func reanchor() {
        let keptCount = min(segmentTokens.count, carryTokenCount)
        segmentTokens = Array(segmentTokens.suffix(keptCount))
        emissionChunks = Array(emissionChunks.suffix(keptCount))
        emittedPrefixBytes = emissionChunks.flatMap { $0 }
    }
}
