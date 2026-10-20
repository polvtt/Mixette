import SwiftUI

struct PanelView: View {
    @EnvironmentObject var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if mixer.permission != .granted { PermissionBanner() }
            OutputSection()
            AppsSection()
            InputSection()
            Footer()
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.30), Color(red: 0.86, green: 0.22, blue: 0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 0) {
                Text("Mixette").font(.system(size: 14, weight: .semibold))
                Text("Volume et sortie par application").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Autorisation

struct PermissionBanner: View {
    @EnvironmentObject var mixer: Mixer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 16)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Accès à l'audio des apps requis").font(.system(size: 12, weight: .semibold))
                Text(mixer.permission == .denied
                     ? "Refusé. Activez Mixette dans Réglages › Confidentialité › Enregistrement audio du système."
                     : "Mixette doit lire le son d'une app pour en régler le volume ou la sortie. Rien n'est enregistré.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(mixer.permission == .denied ? "Ouvrir Réglages" : "Autoriser…") { mixer.requestPermission() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }
}

// MARK: - Appareils

struct OutputSection: View {
    @EnvironmentObject var mixer: Mixer
    var body: some View {
        Card("Sortie") {
            ForEach(mixer.outputs) { d in
                DeviceRow(device: d, direction: .output, isDefault: d.uid == mixer.defaultOutputUID)
            }
            if mixer.outputs.isEmpty { Empty(text: "Aucune sortie audio") }
        }
    }
}

struct InputSection: View {
    @EnvironmentObject var mixer: Mixer
    var body: some View {
        Card("Entrée") {
            ForEach(mixer.inputs) { d in
                DeviceRow(device: d, direction: .input, isDefault: d.uid == mixer.defaultInputUID)
            }
            if mixer.inputs.isEmpty { Empty(text: "Aucun micro") }
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var mixer: Mixer
    var device: AudioDevice
    var direction: Direction
    var isDefault: Bool

    var body: some View {
        VStack(spacing: 4) {
            Button { mixer.setDefault(device, direction) } label: {
                HStack(spacing: 9) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isDefault ? Color.white : Color.primary.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(isDefault ? Color.accentColor : Color.primary.opacity(0.08)))
                    Text(device.name).font(.system(size: 12.5, weight: isDefault ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if isDefault {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDefault ? "\(direction == .output ? "Sortie" : "Entrée") par défaut" : "Utiliser par défaut")

            if isDefault {
                HStack(spacing: 6) {
                    let muted = device.muted ?? false
                    IconButton(systemName: direction == .output
                               ? (muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                               : (muted ? "mic.slash.fill" : "mic.fill"),
                               tint: muted ? .red : .secondary,
                               help: muted ? "Réactiver" : "Couper") { mixer.toggleMute(device, direction) }
                        .disabled(!device.canMute)
                        .opacity(device.canMute ? 1 : 0.35)
                    if let v = mixer.displayedVolume(device, direction), device.canSetVolume {
                        VolumeSlider(value: v, dimmed: muted,
                                     onChange: { mixer.setVolume(device, direction, $0) },
                                     onEnd: { mixer.endVolumeDrag(device, direction) })
                        Text(percent(v)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    } else {
                        Text("Volume réglé sur l'appareil").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .padding(.leading, 1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isDefault ? Color.accentColor.opacity(0.07) : .clear))
    }
}

// MARK: - Applications

struct AppsSection: View {
    @EnvironmentObject var mixer: Mixer

    var body: some View {
        let custom = mixer.apps.filter { !mixer.settings(for: $0).isDefault }.count
        Card("Applications",
             trailing: custom > 0 ? AnyView(Text("\(custom) réglée\(custom > 1 ? "s" : "")")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)) : nil) {
            if mixer.apps.isEmpty {
                Empty(text: "Aucune app ne joue de son pour l'instant.\nLancez une vidéo ou de la musique.")
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(mixer.apps) { app in AppRow(app: app) }
                    }
                }
                .frame(maxHeight: 330)
                .fixedSize(horizontal: false, vertical: mixer.apps.count <= 5)
            }
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var mixer: Mixer
    var app: AudioApp

    var body: some View {
        let s = mixer.settings(for: app)
        let routed = mixer.resolvedOutputs(s)
        VStack(spacing: 3) {
            HStack(spacing: 9) {
                Image(nsImage: app.icon).resizable().frame(width: 26, height: 26)
                    .opacity(app.isPlaying ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        if app.isPlaying {
                            Circle().fill(Color.green).frame(width: 5, height: 5).help("Lecture en cours")
                        }
                        if let err = mixer.failures[app.id] {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(.orange).help(err)
                        }
                    }
                    Text(routeLabel(s, routed)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                BoostChip(level: s.boost) { mixer.cycleBoost(app) }
                RouteMenu(app: app, settings: s, routed: routed)
            }
            HStack(spacing: 6) {
                VolumeSlider(value: s.volume, peak: mixer.peaks[app.id] ?? 0,
                             tint: s.boost > 1 ? .orange : .accentColor, dimmed: s.muted) { mixer.setVolume(app, $0) }
                Text(s.muted ? "muet" : percent(s.volume * Float(s.boost)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(s.muted ? Color.red : s.boost > 1 ? Color.orange : Color.secondary)
                    .frame(width: 38, alignment: .trailing)
                PillButton(systemName: s.muted ? "speaker.slash.fill" : "speaker.fill", title: "Muet",
                           active: s.muted, tint: .red,
                           help: s.muted ? "Réactiver \(app.name)" : "Couper \(app.name)") { mixer.toggleMute(app) }
                PillButton(systemName: "speaker.wave.3.fill", title: "Max",
                           active: s.isUnityGain, tint: .accentColor,
                           help: "Remettre \(app.name) à 100 % (sans coupure ni boost)") { mixer.setMax(app) }
            }
            .padding(.leading, 2)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .contextMenu {
            Button("Réinitialiser \(app.name)") { mixer.reset(app) }.disabled(s.isDefault)
        }
    }

    private func routeLabel(_ s: AppSettings, _ routed: [String]) -> String {
        let names = routed.compactMap { uid in mixer.outputs.first { $0.uid == uid }?.name }
        if s.outputs.isEmpty { return "Sortie par défaut" + (names.first.map { " · \($0)" } ?? "") }
        return names.isEmpty ? "Sortie absente — défaut" : names.joined(separator: " + ")
    }
}

struct RouteMenu: View {
    @EnvironmentObject var mixer: Mixer
    var app: AudioApp
    var settings: AppSettings
    var routed: [String]

    var body: some View {
        Menu {
            check("Suivre la sortie par défaut", settings.outputs.isEmpty) { mixer.followDefault(app) }
            Divider()
            Text("Une seule sortie")
            ForEach(mixer.outputs) { d in
                check(d.name, settings.outputs == [d.uid]) { mixer.setOutput(app, only: d.uid) }
            }
            if mixer.outputs.count > 1 {
                Divider()
                Text("Plusieurs sorties à la fois")
                ForEach(mixer.outputs) { d in
                    check(d.name, settings.outputs.count > 1 && settings.outputs.contains(d.uid)) { mixer.toggleOutput(app, d.uid) }
                }
            }
        } label: {
            let first = mixer.outputs.first { $0.uid == routed.first }
            Image(systemName: routed.count > 1 ? "rectangle.stack.fill" : (first?.symbol ?? "speaker.wave.2.fill"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(settings.outputs.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 26, height: 20)
                .background(Capsule().fill(settings.outputs.isEmpty ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.15)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choisir la sortie de \(app.name)")
    }

    /// Élément de menu coché nativement.
    private func check(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
    }
}

// MARK: - Divers

struct Empty: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

struct Footer: View {
    @EnvironmentObject var mixer: Mixer
    var body: some View {
        HStack(spacing: 10) {
            Toggle("Ouvrir à la connexion", isOn: Binding(get: { mixer.launchAtLogin }, set: { mixer.setLaunchAtLogin($0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            Spacer()
            Button("Son…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound")!)
            }
            .controlSize(.small)
            Button("Quitter") { NSApp.terminate(nil) }.controlSize(.small).keyboardShortcut("q")
        }
        .padding(.horizontal, 2)
    }
}
