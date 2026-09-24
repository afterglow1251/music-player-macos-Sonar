import SwiftUI
import AppKit

/// Inline settings panel that takes the artwork's place — the visualizer below
/// stays visible so theme/EQ changes preview live. Equalizer is on top (most
/// used); themes are a compact swatch row that reveals names on hover.
struct SettingsView: View {
    @ObservedObject var controller: PlayerController
    private let accent = Theme.accent
    let width: CGFloat
    let height: CGFloat

    @State private var customMinutes = ""
    @State private var hoveredTheme: Int?
    @State private var hoveredAlbum = false
    @ObservedObject private var elevenLabs = ElevenLabsKey.shared
    /// The key being pasted — shown only while entering one (none saved yet, or
    /// replacing), never read back from the Keychain.
    @State private var keyDraft = ""
    @State private var replacingKey = false
    @State private var keyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EqualizerView(controller: controller)
                    sleepSection
                    themeSection
                    storageSection
                    elevenLabsSection
                }
                .padding(5)   // room for hover-scaled buttons
            }
            .scrollIndicators(.never)
        }
        .padding(14)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.08)))
    }

    // MARK: Sleep timer (compact)

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle("SLEEP TIMER")
                if let remaining = controller.sleepRemaining {
                    Text(clockTimeString(remaining))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                } else if controller.sleepMode == .endOfTrack {
                    Text("· end of track")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            }
            HStack(spacing: 5) {
                sleepChip("Off", active: controller.sleepMode == .off) { controller.setSleep(.off) }
                ForEach([15, 30, 45, 60], id: \.self) { m in
                    sleepChip("\(m)", active: controller.sleepMode == .timer(minutes: m)) {
                        controller.setSleep(.timer(minutes: m))
                    }
                }
                sleepChip("End", active: controller.sleepMode == .endOfTrack) {
                    controller.setSleep(.endOfTrack)
                }
                HStack(spacing: 3) {
                    SteadyTextField(placeholder: "min", text: $customMinutes,
                                    font: .systemFont(ofSize: 10), onSubmit: applyCustom)
                        .frame(width: 30)
                    Button(action: applyCustom) {
                        Image(systemName: "arrow.right.circle.fill").font(.system(size: 12))
                            .foregroundStyle(accent)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.06)))
            }
        }
    }

    private func sleepChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? accent : .white.opacity(0.55))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.05))
    }

    // MARK: Themes (compact swatches, name on hover)

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle("VISUALIZER THEME")
                Text("· \(themeLabel)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }
            HStack(spacing: 7) {
                albumSwatch
                ForEach(Array(VisualizerTheme.all.enumerated()), id: \.offset) { index, theme in
                    let selected = !controller.albumTheme && index == controller.themeIndex
                    Button {
                        controller.albumTheme = false
                        controller.themeIndex = index
                    } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LinearGradient(colors: [theme.colors.first ?? .green,
                                                          theme.colors[theme.colors.count / 2],
                                                          theme.colors.last ?? .red],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.white, lineWidth: selected ? 2 : 0))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: selected ? 0 : 1))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .onHover { hoveredTheme = $0 ? index : nil }
                    .help(theme.name)
                }
            }
        }
    }

    /// Tiles take their colors from the current song's cover. The swatch stays a
    /// neutral "mixed colors" glyph — only the tiles recolor, not this button.
    private var albumSwatch: some View {
        let selected = controller.albumTheme
        return Button { controller.albumTheme = true } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.14)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 26, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.white, lineWidth: selected ? 2 : 0))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: selected ? 0 : 1))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hoveredAlbum = $0 }
        .help("Mixes the tile colors from the current song's cover")
    }

    /// Name shown beside the section title, tracking hover then selection.
    private var themeLabel: String {
        if hoveredAlbum { return "Mixed from cover" }
        if let index = hoveredTheme { return VisualizerTheme.all[index].name }
        if controller.albumTheme { return "Mixed from cover" }
        return VisualizerTheme.all[controller.themeIndex].name
    }

    // MARK: Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("MUSIC FOLDER")
            Text(controller.library.folder.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 14) {
                Button("Change…", action: chooseFolder)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                Button("Show in Finder") { controller.library.revealInFinder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: ElevenLabs

    /// The API key behind "Sync words". Once saved it shows only masked
    /// ("sk_890f••••••••3155") — enough to tell which key it is, useless if seen.
    private var elevenLabsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("ELEVENLABS · WORD-BY-WORD LYRICS")
            if let masked = elevenLabs.masked, !replacingKey {
                HStack(spacing: 14) {
                    Text(masked)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    Button("Replace") { replacingKey = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                    Button("Remove") { elevenLabs.remove() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                HStack(spacing: 10) {
                    SteadyTextField(placeholder: "Paste your API key", text: $keyDraft,
                                    font: .monospacedSystemFont(ofSize: 10, weight: .regular), onSubmit: saveKey)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    Button("Save", action: saveKey)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? .white.opacity(0.3) : accent)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if replacingKey {
                        Button("Cancel") { replacingKey = false; keyDraft = "" }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Text(keyError ?? "Needs Forced Alignment + Speech to Text access · ≈ $0.01 per song")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func saveKey() {
        do {
            try elevenLabs.save(keyDraft)
            keyDraft = ""
            replacingKey = false
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = controller.library.folder
        if panel.runModal() == .OK, let url = panel.url {
            controller.library.setFolder(url)
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
    }

    private func applyCustom() {
        if let minutes = Int(customMinutes.trimmingCharacters(in: .whitespaces)), minutes > 0 {
            controller.setSleep(.timer(minutes: minutes))
            customMinutes = ""
        }
    }

}
