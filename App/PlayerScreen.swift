import SwiftUI
import AVKit
import HLSCore

/// Reproductor del sistema sin marcos: la imagen ocupa toda la pantalla (o la rellena recortando, según Ajustes).
struct FullscreenVideo: UIViewControllerRepresentable {
    let player: AVPlayer
    /// Se llama al tocar la imagen (el reproductor del sistema se come los toques, por eso se engancha un reconocedor propio).
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func tapped() { onTap() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.videoGravity = AppSettings.fillScreen ? .resizeAspectFill : .resizeAspect
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.view.backgroundColor = .black
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        vc.view.addGestureRecognizer(tap)
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) { vc.player = player; context.coordinator.onTap = onTap }
}

/// Reproductor de un canal o título. Pasa por el relay local cuando el contenido lo necesita
/// (DASH, HLS cifrado o claves ClearKey), enseña la resolución que se está viendo y la causa si algo falla.
/// Con `itemKey` (películas y series) recuerda la posición para «Seguir viendo».
struct PlayerScreen: View {
    let channel: IptvChannel
    var itemKey: String? = nil
    @StateObject private var model = PlayerModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showBar = true
    private let full = AppSettings.fullscreen
    @State private var hideTask: Task<Void, Never>?

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled { withAnimation { showBar = false } } }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if model.engine == .vlc {
                VlcVideoView(engine: model.vlc, onTap: { withAnimation { showBar = true }; scheduleHide() }).ignoresSafeArea(edges: full ? .all : [])
                VlcStatusBadge(engine: model.vlc)
            }
            else if let player = model.player { FullscreenVideo(player: player, onTap: { withAnimation { showBar = true }; scheduleHide() }).ignoresSafeArea(edges: full ? .all : []) } else { ProgressView().tint(.white) }
            if AppSettings.ownSubtitles { SubtitleOverlay(text: model.subtitleText).ignoresSafeArea() }
            VStack(spacing: 0) {
                topBar
                Spacer()
                if !showBar, AppSettings.qualityAlways, !model.forcedFallback, !model.qualityText.isEmpty {
                    Text(model.qualityText).font(.caption2.monospacedDigit()).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                }
                if model.engine == .vlc, showBar { VlcTransportBar(engine: model.vlc, onTouch: scheduleHide).padding(.horizontal, 16).padding(.bottom, 8) }
                if let note = model.engineNote {
                    Label(note, systemImage: "info.circle").font(.caption2).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.orange.opacity(0.85), in: Capsule()).foregroundStyle(.black).padding(.bottom, 6)
                }
                if let n = model.notice {
                    HStack(spacing: 8) { ProgressView().tint(.white); Text(n).font(.caption.bold()) }
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white).padding(.bottom, 8)
                } else if let e = model.errorText {
                    Text(e).font(.caption).foregroundStyle(.red).padding(8).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)).padding()
                }
            }
        }
        .onChange(of: model.engineNote) { n in if n == nil { withAnimation { showBar = false } } }     // pasado el aviso: vídeo a pantalla completa
        .navigationBarBackButtonHidden(full)
        // Título y botón de cerrar solo al tocar la pantalla: con los controles ocultos queda solo el vídeo
        .toolbar((full || !showBar) ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(full || !showBar)
        .persistentSystemOverlays((full || !showBar) ? .hidden : .automatic)
        .navigationTitle(channel.name)
        .task {
            guard let url = URL(string: channel.url) else { model.errorText = "dirección no válida"; return }
            var headers = channel.httpHeaders
            if let ua = channel.userAgent { headers["User-Agent"] = ua }
            if let ref = channel.referrer { headers["Referer"] = ref }
            await model.start(url: url, headers: headers, clearKeys: channel.clearKeys)
            // Continuar donde se dejó
            let saved = MediaProgress.shared.position(channelId: channel.id)
            if itemKey != nil, saved > 20 { try? await Task.sleep(nanoseconds: 1_200_000_000); model.seek(to: saved) }
            // La barra se oculta sola a los pocos segundos
            try? await Task.sleep(nanoseconds: 5_000_000_000); withAnimation { showBar = false }
        }
        .onDisappear {
            if let k = itemKey { MediaProgress.shared.save(channelId: channel.id, itemKey: k, pos: model.lastTime, dur: model.duration) }
            model.stop()
        }
    }

    /// Barra superior flotante. El botón de volver está siempre a la vista; el resto se oculta solo a los pocos segundos.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.body.bold()).frame(width: 44, height: 44)
                    .background(.black.opacity(showBar ? 0.6 : 0.35), in: Circle())
            }
            if showBar {
                if model.engine == .avplayer { QualityMenu(model: model) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name).font(.subheadline.bold()).lineLimit(1)
                    if AppSettings.showQuality, !model.qualityText.isEmpty { Text(model.qualityText).font(.caption2.monospacedDigit()) }
                    if !model.audioInfo.isEmpty { Label(model.audioInfo, systemImage: "speaker.wave.2").font(.caption2) }
                }
                .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule())
                Spacer()
                TrackMenus(model: model)
            } else { Spacer() }
        }
        .foregroundStyle(.white).padding(.horizontal, 12).padding(.top, 76)      // por debajo de la fila de botones del sistema
    }
}

/// Menú de calidad de imagen (resoluciones con códec, HDR y bitrate; las que el aparato no abre salen apagadas).
struct QualityMenu: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        Menu {
                    Button { Task { await model.setQuality(height: 0) } } label: { Label("Automática", systemImage: model.chosenHeight == 0 ? "checkmark" : "") }
                    if model.videoOptions.isEmpty {
                        ForEach([2160, 1440, 1080, 720, 480, 360], id: \.self) { h in
                            Button { Task { await model.setQuality(height: h) } } label: { Label("Hasta \(h)p", systemImage: model.chosenHeight == h ? "checkmark" : "") }
                        }
                    } else {
                        // Todas las pistas con resolución, códec, HDR y bitrate; las que el aparato no abre salen marcadas y apagadas
                        ForEach(model.videoOptions) { v in
                            let ok = PlayerModel.canDecode(v)
                            Button { Task { await model.setQuality(height: v.height) } } label: {
                                Label(v.label + (ok ? "" : "  ✕ no compatible"), systemImage: model.chosenHeight == v.height ? "checkmark" : "")
                            }.disabled(!ok)
                        }
                    }
                } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
    }
}

/// Audio, subtítulos, estilo de subtítulos y AirPlay.
struct TrackMenus: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        HStack(spacing: 10) {
                if model.allAudio.count > 1 {
                    Menu {
                        ForEach(model.allAudio) { e in
                            Button { model.chooseAudio(e) } label: {
                                Label(e.isDescription ? "\(e.name) · audiodescripción" : e.name, systemImage: e.selected ? "checkmark" : "")
                            }
                        }
                    } label: { Image(systemName: "speaker.wave.2").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
                } else if model.audioChoices.count > 1 {
                    Menu {
                        ForEach(model.audioChoices) { c in
                            Button { model.selectAudio(c.id) } label: { Label(c.detail.isEmpty ? c.name : "\(c.name) · \(c.detail)", systemImage: c.selected ? "checkmark" : "") }
                        }
                    } label: { Image(systemName: "speaker.wave.2").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
                }
                if !model.subtitleChoices.isEmpty {
                    Menu {
                        Button { model.selectSubtitle(nil) } label: { Label("Sin subtítulos", systemImage: model.subtitleChoices.contains { $0.selected } ? "" : "checkmark") }
                        ForEach(model.subtitleChoices) { c in
                            Button { model.selectSubtitle(c.id) } label: { Label(c.detail.isEmpty ? c.name : "\(c.name) · \(c.detail)", systemImage: c.selected ? "checkmark" : "") }
                        }
                    } label: { Image(systemName: "captions.bubble").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
                }
                if model.externalURL != nil { ExternalPlayerButton(urlProvider: { model.externalURL }, iconOnly: true) }
                AudioDelayButton(applied: $model.audioDelayMs, apply: model.setAudioDelay)
                if AppSettings.ownSubtitles { SubtitleStyleMenu() }
                if model.engine == .avplayer { AirPlayButton().frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
        }
    }
}

/// Superficie de vídeo reutilizable (el reproductor del sistema con sus controles).
struct PlayerSurface: View {
    let player: AVPlayer
    var body: some View { FullscreenVideo(player: player) }
}

/// Botón de AirPlay del sistema: elegir la pantalla de destino y, si ya se emite, volver a este dispositivo.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white; v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

/// Vídeo del reproductor elegido: VLC o el reproductor del sistema. Lo usan todas las pantallas que reproducen
/// (si no, con VLC se oye el audio pero la pantalla se queda con la rueda).
struct ModelVideo: View {
    @ObservedObject var model: PlayerModel
    var onTap: () -> Void = {}
    var body: some View {
        if model.engine == .vlc {
            ZStack {
                VlcVideoView(engine: model.vlc, onTap: onTap)
                VlcStatusBadge(engine: model.vlc)
            }
        } else if let p = model.player {
            FullscreenVideo(player: p, onTap: onTap)
        } else {
            ProgressView().tint(.white)
        }
    }
}
