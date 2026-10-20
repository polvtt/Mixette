import SwiftUI

// Briques visuelles du panneau.

struct Card<Content: View>: View {
    var title: String
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            .padding(.horizontal, 4)
            VStack(spacing: 2) { content }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}

/// Curseur de volume dessiné à la main : piste, remplissage, VU-mètre en fond, pastille.
/// Pas d'état local (pas de @State avec les seuls Command Line Tools) : chaque geste écrit
/// directement dans le modèle.
struct VolumeSlider: View {
    var value: Float                 // 0…1
    var peak: Float = 0              // 0…1+, affiché sous le remplissage
    var tint: Color = .accentColor
    var dimmed = false
    var onChange: (Float) -> Void
    var onEnd: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let v = CGFloat(max(0, min(1, value)))
            let knob: CGFloat = 14
            let x = knob / 2 + v * (w - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.11)).frame(height: 5)
                Capsule().fill(tint.opacity(0.28))
                    .frame(width: min(w, CGFloat(min(peak, 1)) * w), height: 5)
                    .animation(.linear(duration: 0.05), value: peak)
                Capsule().fill(dimmed ? Color.secondary.opacity(0.55) : tint).frame(width: x, height: 5)
                Circle()
                    .fill(Color(nsColor: .controlColor).opacity(1))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.2, y: 0.6)
                    .frame(width: knob, height: knob)
                    .offset(x: x - knob / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let nv = max(0, min(1, Float((g.location.x - knob / 2) / (w - knob))))
                    // Ignorer les micro-déplacements (< 0,25 %) : moins d'écritures, aucun effet visible.
                    if abs(nv - value) >= 0.0025 || nv == 0 || nv == 1 { onChange(nv) }
                }
                .onEnded { _ in onEnd?() })
        }
        .frame(height: 18)
    }
}

/// Bouton icône compact (mute, menus…).
struct IconButton: View {
    var systemName: String
    var tint: Color = .secondary
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Bouton-pastille icône + libellé, coloré quand son état est actif (Muet, Max).
struct PillButton: View {
    var systemName: String
    var title: String
    var active: Bool
    var tint: Color
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemName).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .padding(.horizontal, 7).frame(height: 20)
            .foregroundStyle(active ? tint : Color.primary.opacity(0.7))
            .background(Capsule().fill(active ? tint.opacity(0.16) : Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(active ? tint.opacity(0.35) : .clear, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Pastille de boost ×1…×4 : grise au repos, orange quand active.
struct BoostChip: View {
    var level: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 1) {
                Image(systemName: level > 2 ? "chevron.up.2" : "chevron.up")
                    .font(.system(size: 8.5, weight: .bold))
                Text("×\(level)").font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .padding(.horizontal, 6).frame(height: 19)
            .foregroundStyle(level > 1 ? Color.white : Color.secondary)
            .background(Capsule().fill(level > 1 ? Color.orange : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(level > 1 ? "Boost ×\(level) — cliquer pour augmenter, revient à ×1 après ×\(AppSettings.maxBoost)"
                        : "Amplifier au-delà de 100 % (limiteur doux, pas de saturation)")
    }
}

func percent(_ v: Float) -> String { "\(Int((v * 100).rounded())) %" }
