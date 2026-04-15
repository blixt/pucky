import SwiftUI

/// A minimal tab indicator that sits exactly on top of the Dynamic Island.
///
/// The island's position, size, and corner radius are resolved at runtime
/// via `DynamicIsland.current`, so the rope stays aligned across every
/// iPhone model that has an island (14 Pro through 17 Pro Max, iPhone Air).
///
/// A thin capsule outline is stroked around the island in dim rule color
/// to form the rope base. A second dashed stroke paints a short violet
/// segment centred on each tab's 1/N slot along the bottom edge of the
/// pill. The dash phase is driven directly by the scroll progress of the
/// page-style scroll view, so the accent slides 1:1 with the user's finger.
struct IslandRope: View {
    /// Continuous scroll progress. 0 = first tab, (tabCount - 1) = last tab.
    let scrollProgress: CGFloat
    let tabCount: Int

    /// Visual gap between the rope and the real island's edge.
    private let gap: CGFloat = 3.5
    private let strokeWidth: CGFloat = 3

    /// Extra length added on each side of the active segment beyond its
    /// base 1/N slot along the flat bottom edge. The outer tabs have all
    /// of this on the outside (wrapping into the end arcs), the inner
    /// tabs distribute it evenly — see `dashPhase(_:)`.
    private let segmentEndOverlap: CGFloat = 20

    var body: some View {
        // Resolve the island geometry at runtime. Falls back to a safe
        // default sized for iPhone 17 Pro if detection ever fails.
        let island = DynamicIsland.current ?? .fallback

        let w = island.size.width + gap * 2
        let h = island.size.height + gap * 2
        let perimeter = 2 * (w - h) + .pi * h

        // Base slot: 1/N of the flat bottom edge.
        let flatBottomEdge = w - h
        let slotLength = flatBottomEdge / CGFloat(max(tabCount, 1))
        let segmentLength = slotLength + 2 * segmentEndOverlap
        let gapLength = perimeter - segmentLength

        ZStack(alignment: .topLeading) {
            Capsule()
                .stroke(PK.rule, lineWidth: strokeWidth)
                .frame(width: w, height: h)

            Capsule()
                .stroke(
                    PK.accent,
                    style: StrokeStyle(
                        lineWidth: strokeWidth + 0.4,
                        lineCap: .round,
                        dash: [segmentLength, gapLength],
                        dashPhase: dashPhase(
                            w: w,
                            h: h,
                            perimeter: perimeter,
                            segmentLength: segmentLength,
                            slotLength: slotLength
                        )
                    )
                )
                .frame(width: w, height: h)
        }
        .frame(width: w, height: h)
        // Position the rope's top-left corner so the rope's inner edge
        // wraps exactly around the island. The island's own origin is in
        // screen coordinates; our parent centres us horizontally, so we
        // only need to offset vertically by the island's top inset minus
        // the visual gap.
        .offset(y: island.origin.y - gap)
    }

    /// Compute dashPhase so the middle tab's segment is centred on the
    /// bottom edge of the pill, with a linear asymmetry shift that
    /// pushes the overlap toward the outer edges for outer tabs.
    private func dashPhase(
        w: CGFloat,
        h: CGFloat,
        perimeter p: CGFloat,
        segmentLength: CGFloat,
        slotLength: CGFloat
    ) -> CGFloat {
        // SwiftUI's `Capsule.path(in:)` starts at the leftmost point of
        // the left arc and runs clockwise. The top edge's centre is
        // therefore a quarter-arc plus half a top edge from the path start.
        let quarterArc = .pi * h / 4
        let topEdgeHalf = (w - h) / 2
        let topCentreDistance = quarterArc + topEdgeHalf
        let bottomCentreDistance = topCentreDistance + p / 2
        let basePhase = bottomCentreDistance + segmentLength / 2

        // Slot shift: 1/N slot per unit of scroll progress.
        let middleIndex = CGFloat(tabCount) / 2.0 - 0.5
        let slotShift = (scrollProgress - middleIndex) * slotLength

        // Asymmetry shift: linearly interpolated from `-segmentEndOverlap`
        // at the leftmost tab to `+segmentEndOverlap` at the rightmost,
        // so outer tabs have all their overlap on the outside and inner
        // tabs distribute it evenly.
        let asymmetryShift: CGFloat
        if tabCount > 1 {
            let maxIndex = CGFloat(tabCount - 1)
            let normalized = scrollProgress / maxIndex
            asymmetryShift = (normalized - 0.5) * 2 * segmentEndOverlap
        } else {
            asymmetryShift = 0
        }

        return basePhase + slotShift + asymmetryShift
    }
}

// MARK: - Fallback

extension DynamicIsland.Geometry {
    /// Fallback geometry (iPhone 17 Pro dimensions) if runtime detection
    /// ever fails. Prevents the indicator from disappearing on unknown
    /// devices.
    static var fallback: DynamicIsland.Geometry {
        let width: CGFloat = 126
        let height: CGFloat = 37.33
        return DynamicIsland.Geometry(
            origin: CGPoint(x: 0, y: 13.5),
            size: CGSize(width: width, height: height),
            cornerRadius: height / 2,
            screenCornerRadius: 55
        )
    }
}
