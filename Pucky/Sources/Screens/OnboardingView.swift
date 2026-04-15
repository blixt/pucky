import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var breathing = false

    var body: some View {
        ZStack {
            PK.bg.ignoresSafeArea()

            VStack(spacing: PK.lg) {
                Spacer()

                Text("Pucky")
                    .font(PK.serif(56, weight: .light))
                    .foregroundStyle(PK.accent)
                    // Breath: rests at full size (inhaled), contracts
                    // slightly on the exhale, expands back. The
                    // (0.65, 0, 0.35, 1) cubic spends more time near
                    // the extremes than `.easeInOut` does, which gives
                    // the soft "hold" between inhale and exhale that
                    // makes a real breath feel like a breath instead
                    // of a sine wave. ~2.4s per half-cycle ⇒ ~4.8s
                    // full cycle ⇒ ~12 breaths/min, the resting rate
                    // for a relaxed human.
                    .scaleEffect(breathing ? 0.94 : 1.0, anchor: .center)
                    .animation(
                        .timingCurve(0.65, 0.0, 0.35, 1.0, duration: 2.4)
                            .repeatForever(autoreverses: true),
                        value: breathing
                    )
                    .onAppear { breathing = true }

                Spacer()

                Group {
                    if let error = appState.loadError {
                        errorView(error)
                    } else {
                        loadingView
                    }
                }
                .padding(.horizontal, PK.xl)
                .padding(.bottom, PK.xl)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("OnboardingView")
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PK.rule)
                        .frame(height: 2)
                    Capsule()
                        .fill(PK.accent)
                        .frame(
                            width: max(2, geo.size.width * CGFloat(appState.modelService.loadProgress)),
                            height: 2
                        )
                        .animation(.easeOut(duration: 0.4), value: appState.modelService.loadProgress)
                }
            }
            .frame(height: 2)

            Text(appState.modelService.loadStatus)
                .font(PK.sans(12))
                .foregroundStyle(PK.textDim)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: PK.md) {
            Text("Couldn't load the model")
                .font(PK.serif(20, weight: .light))
                .foregroundStyle(PK.text)
            Text(message)
                .font(PK.sans(12))
                .foregroundStyle(PK.alert.opacity(0.9))
                .multilineTextAlignment(.center)
            Button {
                Task { await appState.initialize() }
            } label: {
                Text("Retry")
                    .font(PK.sans(13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(PK.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("OnboardingRetry")
        }
    }
}
