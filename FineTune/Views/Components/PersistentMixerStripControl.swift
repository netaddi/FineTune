import SwiftUI

/// Edits the deterministic Console 1 startup position for a pinned application's AU chain.
/// Changing the number never destroys a live Audio Unit; the new creation order is applied
/// the next time FineTune launches.
struct PersistentMixerStripControl: View {
    let slot: Int
    let maximumSlot: Int
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Label("Console 1 startup order", systemImage: "slider.horizontal.3")
                    .font(DesignTokens.Typography.rowName)
                Spacer()
                Menu("Next launch #\(slot)") {
                    ForEach(1...max(maximumSlot, 1), id: \.self) { candidate in
                        Button {
                            onChange(candidate)
                        } label: {
                            if candidate == slot {
                                Label("Position \(candidate)", systemImage: "checkmark")
                            } else {
                                Text("Position \(candidate)")
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text("Only pinned strips with one non-quarantined Console 1 are ordered. A normal bypass keeps its position. Restart to apply; the live instance stays on its current track until then.")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DesignTokens.Spacing.sm)
    }
}
