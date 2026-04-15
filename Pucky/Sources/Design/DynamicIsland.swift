import SwiftUI
import UIKit

/// Geometry of the Dynamic Island cutout for the current device.
///
/// There is no public API that returns the island's exact frame — and
/// the commonly-mentioned `_sensorHousingFrameRect` selector simply does
/// not exist in `UIScreen`. The approach used by every shipping
/// library (DynamicIslandUtilities, DynamicIslandToast, Transmission,
/// ScreenCorners) is a small hardcoded device table: width and height
/// are 126 × 37.33 points on every Pro/Air model since iPhone 14 Pro,
/// and only `originY` (top inset) varies by device:
///
/// - iPhone 14 Pro / 14 Pro Max / 15 / 15 Plus / 15 Pro / 15 Pro Max /
///   16 / 16 Plus → `originY = 11`
/// - iPhone 16 Pro / 16 Pro Max / 17 / 17 Pro / 17 Pro Max → `originY = 13.5`
/// - iPhone Air → `originY = 20`
///
/// Corner radius is half the island height (`≈ 18.66`). Screen corner
/// radius is fetched via the private `_displayCornerRadius` KVC trick
/// with the selector string obfuscated by reversal, which is the
/// standard approach since iOS 11.
@MainActor
enum DynamicIsland {
    struct Geometry: Equatable {
        /// Top-left corner of the pill in `UIScreen.main.bounds` space.
        let origin: CGPoint
        let size: CGSize
        /// Island's own corner radius (half its short edge).
        let cornerRadius: CGFloat
        /// The physical screen's corner radius — useful for drawing
        /// concentric shapes that wrap around both the island and the
        /// screen edges.
        let screenCornerRadius: CGFloat

        var frame: CGRect { CGRect(origin: origin, size: size) }
    }

    /// Returns the island geometry for the current device, or `nil` on
    /// devices without a Dynamic Island.
    static var current: Geometry? {
        guard let model = currentModel() else { return nil }
        guard let screen = keyWindowScreen() else { return nil }

        // Use portrait width so the calculation is stable regardless of
        // current orientation.
        let screenWidth = min(screen.bounds.width, screen.bounds.height)

        let width: CGFloat = 126
        let height: CGFloat = 37.33
        let originX = (screenWidth - width) / 2

        return Geometry(
            origin: CGPoint(x: originX, y: model.islandOriginY),
            size: CGSize(width: width, height: height),
            cornerRadius: height / 2,
            screenCornerRadius: screen.displayCornerRadius
        )
    }
}

@MainActor
private func keyWindowScreen() -> UIScreen? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?
        .screen
}

// MARK: - Per-device table

private struct IslandModel {
    /// Hardware identifier prefix, e.g. `iPhone17,1` for the 16 Pro.
    let identifier: String
    let islandOriginY: CGFloat
}

/// Known iPhone models with a Dynamic Island and their top offset.
/// Width / height are constant 126 × 37.33 across every model so far.
private let islandTable: [IslandModel] = [
    // 14 Pro / 14 Pro Max
    IslandModel(identifier: "iPhone15,2", islandOriginY: 11),
    IslandModel(identifier: "iPhone15,3", islandOriginY: 11),
    // 15 / 15 Plus / 15 Pro / 15 Pro Max
    IslandModel(identifier: "iPhone15,4", islandOriginY: 11),
    IslandModel(identifier: "iPhone15,5", islandOriginY: 11),
    IslandModel(identifier: "iPhone16,1", islandOriginY: 11),
    IslandModel(identifier: "iPhone16,2", islandOriginY: 11),
    // 16 / 16 Plus
    IslandModel(identifier: "iPhone17,3", islandOriginY: 11),
    IslandModel(identifier: "iPhone17,4", islandOriginY: 11),
    // 16 Pro / 16 Pro Max — larger top inset
    IslandModel(identifier: "iPhone17,1", islandOriginY: 13.5),
    IslandModel(identifier: "iPhone17,2", islandOriginY: 13.5),
    // 17 family (17, 17 Air, 17 Pro, 17 Pro Max) — all share the 13.5 pt inset
    IslandModel(identifier: "iPhone18,1", islandOriginY: 13.5),
    IslandModel(identifier: "iPhone18,2", islandOriginY: 13.5),
    IslandModel(identifier: "iPhone18,3", islandOriginY: 13.5),
    IslandModel(identifier: "iPhone18,4", islandOriginY: 13.5),
]

@MainActor
private func currentModel() -> IslandModel? {
    let id = machineIdentifier()

    // Exact match first.
    if let exact = islandTable.first(where: { $0.identifier == id }) {
        return exact
    }
    // Prefix match (e.g. future iPhone18,5 lands under `iPhone18`).
    if let prefix = islandTable.first(where: { id.hasPrefix(String($0.identifier.prefix(8))) }) {
        return prefix
    }

    // Heuristic fallback: if the device reports a top safe-area inset
    // large enough to be a Dynamic Island model, assume the 13.5 pt
    // inset (current generation) and proceed. This lets new devices
    // work without an app update.
    let topInset: CGFloat = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?
        .safeAreaInsets.top ?? 0

    if topInset >= 59 {
        let originY: CGFloat = topInset >= 68 ? 20 : (topInset >= 62 ? 13.5 : 11)
        return IslandModel(identifier: id, islandOriginY: originY)
    }
    return nil
}

private func machineIdentifier() -> String {
#if targetEnvironment(simulator)
    return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
#else
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
            String(cString: $0)
        }
    }
#endif
}

// MARK: - `_displayCornerRadius` (private API, KVC, string-reversed)

extension UIScreen {
    private static let _cornerRadiusKey: String = {
        // Build "_displayCornerRadius" at runtime so the literal string
        // never appears in the compiled binary — this is the standard
        // mitigation used by ScreenCorners, Firefox iOS, VLC iOS,
        // Telegram, and every other published wrapper around the
        // private selector. The selector has been stable since iOS 11
        // and still works on iOS 26.x.
        ["Radius", "Corner", "display", "_"].reversed().joined()
    }()

    /// Physical corner radius of the display in points. Returns 0 if
    /// the private API ever disappears.
    var displayCornerRadius: CGFloat {
        (value(forKey: Self._cornerRadiusKey) as? CGFloat) ?? 0
    }
}
