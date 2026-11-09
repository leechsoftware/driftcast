import SwiftUI

/// The captions symbol behind a red circle and slash: the video has no closed captions in
/// the language chosen in Settings > Subtitles. Drawn here because SF Symbols has no
/// slashed captions glyph.
struct NoCaptionsIcon: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Image(systemName: "captions.bubble")
                .font(.system(size: size * 0.55, weight: .medium))
                .foregroundStyle(.secondary)
            Circle()
                .strokeBorder(Color.red, lineWidth: max(1.5, size * 0.09))
            Capsule()
                .fill(Color.red)
                .frame(width: max(1.5, size * 0.09), height: size * 0.82)
                .rotationEffect(.degrees(45))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("No captions in your language")
    }
}

/// The captions symbol in the accent colour, or the crossed-out one when `missing`.
struct CaptionsIcon: View {
    var missing: Bool
    var filled = true
    var size: CGFloat = 20

    var body: some View {
        if missing {
            NoCaptionsIcon(size: size)
        } else {
            Image(systemName: filled ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: size * 0.7))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
        }
    }
}
