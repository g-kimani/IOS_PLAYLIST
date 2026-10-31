import SwiftUI

enum Theme {
    static let accent = Color(red: 0.55, green: 0.42, blue: 1.0)
    static let accent2 = Color(red: 0.96, green: 0.36, blue: 0.66)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.42)

    static let gradient = LinearGradient(
        colors: [accent, accent2],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cardFill = Color.white.opacity(0.07)
    static let cardStroke = Color.white.opacity(0.12)
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.08, blue: 0.20), Color(red: 0.03, green: 0.03, blue: 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(colors: [Theme.accent.opacity(0.35), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Theme.accent2.opacity(0.18), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Round icon button with a generous tap target (the whole circle is tappable).
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 44
    var tint: Color = .white
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if filled {
                    Circle().fill(Theme.gradient)
                } else {
                    Circle().fill(Color.white.opacity(0.10))
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
                Image(systemName: systemName)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundColor(filled ? .white : tint)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.10)))
    }
}

struct QueueRow: View {
    let index: Int
    let item: QueueItem
    let isCurrent: Bool
    let isPast: Bool
    var showDelete = false
    let onTap: () -> Void
    var onDelete: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        if isCurrent {
                            Circle().fill(Theme.gradient)
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Circle().fill(Color.white.opacity(0.08))
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .frame(width: 30, height: 30)

                    Text(item.name)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            if showDelete {
                IconButton(systemName: "xmark", size: 34, tint: Theme.danger, action: onDelete)
                    .padding(.trailing, 8)
            } else {
                Color.clear.frame(width: 8, height: 1)
            }
        }
        .cardStyle(cornerRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isCurrent ? Theme.accent.opacity(0.8) : .clear, lineWidth: 1.5)
        )
        // Videos before the current position are greyed out but still tappable.
        .opacity(isPast ? 0.45 : 1)
    }
}
