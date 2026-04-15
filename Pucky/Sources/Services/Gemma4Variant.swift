#if !targetEnvironment(simulator)
import Foundation

/// Which Gemma 4 weights to load. Both variants ship as MLX 4-bit
/// (Q4_0) so the inference path stays identical; the difference is
/// the parameter count and therefore the steady-state memory budget.
///
/// E4B has roughly 1.5–2x the resident-memory cost of E2B, so we only
/// pick it on phones that have headroom above the increased-memory
/// limit ceiling. iPhone 15/16/17 Pro and newer ship with 8 GB or
/// 12 GB of physical RAM and grant ~5 GB of foreground budget when
/// the entitlement is set, which is enough for E4B with breathing
/// room. Everything else stays on E2B.
enum Gemma4Variant: String, CaseIterable, Sendable {
    case e2b
    case e4b

    var modelId: String {
        switch self {
        case .e2b: "mlx-community/gemma-4-e2b-it-4bit"
        case .e4b: "mlx-community/gemma-4-e4b-it-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .e2b: "Gemma 4 E2B"
        case .e4b: "Gemma 4 E4B"
        }
    }

    /// Resident memory floor we expect from the model weights alone,
    /// rounded up. Used purely as a sanity check / log line.
    var weightBytes: Int {
        switch self {
        case .e2b: 1_700_000_000  // ~1.6 GB
        case .e4b: 2_900_000_000  // ~2.7 GB
        }
    }

    /// Pick a variant based on the physical RAM the device reports.
    /// On-device measurements show E4B is still too tight on a 12 GB
    /// iPhone 17 Pro: prefill spikes push the foreground past jetsam
    /// on real chats, especially with file snapshots in history. We
    /// now require `ProcessInfo.physicalMemory` to be **strictly
    /// greater than 12 GiB** (a 16 GB-class iPhone would report
    /// roughly 15 GB, a 12 GB iPhone reports ~11.45 GB). That keeps
    /// every current phone on E2B and only promotes to E4B on
    /// future hardware with real headroom.
    static func forCurrentDevice() -> Gemma4Variant {
        let physical = ProcessInfo.processInfo.physicalMemory
        let twelveGiB: UInt64 = 12 * 1024 * 1024 * 1024
        return physical > twelveGiB ? .e4b : .e2b
    }
}
#endif
