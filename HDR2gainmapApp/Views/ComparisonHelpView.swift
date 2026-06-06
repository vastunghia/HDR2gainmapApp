import SwiftUI

/// Informational sheet shown when entering Compare mode, explaining how to assign the two sides via
/// drag & drop. Includes a "Do not show again" toggle bound to the persisted preference.
struct ComparisonHelpView: View {
    @Binding var dontShowAgain: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Comparing two previews", systemImage: "rectangle.split.2x1")
                .font(.title3.weight(.semibold))

            Text("""
                 Drag a preview from “Available previews” onto the left or right half of the image \
                 to choose what each side shows. Drag the divider to move the split.

                 Click the image to zoom toward a point, click again to reset, and drag to pan.
                 """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Do not show again", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Got it") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
