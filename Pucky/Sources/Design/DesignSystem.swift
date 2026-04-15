import SwiftUI

/// Pucky's design system.
///
/// Editorial, restrained, professional. Serif headlines for identity,
/// sans-serif body for readability, monospace ONLY when representing code.
enum PK {
    // MARK: — Color

    /// Dark warm lavender — slightly red-shifted from pure dark blue so
    /// the hot pink accent feels at home on it.
    static let bg = Color(red: 0.075, green: 0.063, blue: 0.094)
    /// Slightly elevated surface (cards, raised items).
    static let surface = Color(red: 0.114, green: 0.094, blue: 0.137)
    /// Secondary surface (code background, dropdowns).
    static let surfaceElevated = Color(red: 0.149, green: 0.122, blue: 0.176)
    /// Warm off-white. Not sterile `#FFFFFF`.
    static let text = Color(red: 0.918, green: 0.898, blue: 0.890)
    /// Dimmed body text — warm grey with a touch of pink.
    static let textDim = Color(red: 0.498, green: 0.475, blue: 0.510)
    /// Tertiary — timestamps, helper text, line numbers.
    static let textFaint = Color(red: 0.310, green: 0.290, blue: 0.329)
    /// Thin divider lines.
    static let rule = Color(red: 0.176, green: 0.157, blue: 0.196)

    /// The one accent: hot neon pink. Used sparingly.
    static let accent = Color(red: 1.000, green: 0.129, blue: 0.600)
    /// Success/alive signal.
    static let alive = Color(red: 0.380, green: 0.863, blue: 0.545)
    /// Error/warning: warm amber, not red.
    static let alert = Color(red: 1.000, green: 0.561, blue: 0.239)

    // MARK: — Typography
    //
    // Use `sans` for 95% of UI (labels, buttons, body text, navigation).
    // Use `serif` for identity/hero text — screen titles, filenames, empty-state headlines.
    // Use `mono` ONLY for things that actually are code (source, logs, technical specs).

    /// Sans-serif body and UI text.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Serif display — elegant, used for hero titles and screen headers.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Monospace — only for code and technical data.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: — Spacing

    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 40
    static let xxl: CGFloat = 64

    /// Top padding from the top of the safe-area-ignoring container
    /// down to the first row of header content. Sits just below the
    /// IslandRope (which wraps the Dynamic Island) so headers feel
    /// hung from the rope rather than floating in dead space.
    static let headerTop: CGFloat = 64
}

// MARK: — Shared chrome

/// A thin, horizontal rule.
struct Rule: View {
    var color: Color = PK.rule
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.5)
    }
}

/// 28×28 icon-only header button. Replaces the verbose `Logs` /
/// `Reload` / `New` text buttons so the chrome can stay tight against
/// the IslandRope without crowding it.
///
/// `tinted == true` uses the accent color (active state, e.g. logs
/// drawer open). Otherwise it sits in `textDim` so it doesn't pull
/// attention away from the actual content.
struct IconHeaderButton: View {
    let systemName: String
    var tinted: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tinted ? PK.accent : PK.textDim)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Single-character status dot. Reused by Chat (model load) and
/// Preview (runtime) so they read at the same visual weight.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

// MARK: — Send button

/// Circular send affordance in the brand accent color. Three states:
///
///   - `enabled` (text is non-empty, idle): solid accent disc with an
///     up-arrow glyph. Tapping calls `action`.
///   - `loading` (a generation is in flight): solid accent disc with a
///     white spinner. Non-interactive — the next message can't go out
///     until the current one finishes streaming.
///   - disabled (idle, empty input): muted disc with a dim arrow.
struct SendButton: View {
    var enabled: Bool
    var loading: Bool
    var action: () -> Void

    init(enabled: Bool, loading: Bool = false, action: @escaping () -> Void) {
        self.enabled = enabled
        self.loading = loading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(loading || enabled ? PK.accent : PK.surfaceElevated)
                if loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(enabled ? Color.white : PK.textDim)
                }
            }
            .frame(width: 34, height: 34)
        }
        .disabled(!enabled || loading)
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: loading)
    }
}
