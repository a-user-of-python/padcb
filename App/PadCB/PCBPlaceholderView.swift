import SwiftUI

/// Placeholder for the PCB editor, which arrives in a later part of the
/// PadCB project. Kept deliberately minimal: icon, title, one line of copy.
struct PCBPlaceholderView: View {
    var body: some View {
        ZStack {
            Color(white: 0.08)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "circuitboard")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text("PCB Editor")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Coming in a later part of the PadCB project.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(32)
        }
        .navigationTitle("PCB Editor")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}
