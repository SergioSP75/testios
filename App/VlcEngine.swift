import SwiftUI
import UIKit
import AVFoundation
import HLSCore
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Motor de reproducción con VLC (MobileVLCKit): decodifica por software casi cualquier contenedor y códec (AVI, MKV con DTS/TrueHD/Opus,
/// MPEG-2, VC-1, VP9/AV1 sin hardware…), todo dentro de la app, sin abrir otros reproductores.
/// Si la librería no está en la compilación, `isAvailable` es falso y el selector de motor se queda con AVPlayer.
@MainActor
final class VlcEngine: NSObject, ObservableObject {
    /// ¿Viene VLC dentro de esta compilación?
    static var isAvailable: Bool {
        #if canImport(MobileVLCKit)
        return true
        #else
        return false
        #endif
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var failed = false
    @Published private(set) var positionSec: Double = 0
    @Published private(set) var durationSec: Double = 0
    @Published private(set) var videoSize = CGSize.zero
    @Published private(set) var audioChoices: [PlayerModel.TrackChoice] = []
    @Published private(set) var subtitleChoices: [PlayerModel.TrackChoice] = []
    /// Texto «Español · AC-3 5.1» de la pista que suena (lo que ve el usuario en la barra)
    @Published private(set) var audioInfo = ""
    @Published private(set) var errorText: String?
    /// Lo que está haciendo VLC («abriendo…», «cargando…», «sin imagen»): se enseña mientras no hay imagen para saber en qué punto se queda.
    @Published private(set) var statusText = ""
    /// Posición pedida antes de que el vídeo arranque (continuar donde se dejó): se aplica al empezar a sonar.
    private var pendingSeek: Double?
    private var lastLoggedState = -1
    private var healthTask: Task<Void, Never>?
    /// ¿Se espera imagen? (falso en música). Si suena pero no hay imagen en 10 s, se da por fallo para que la app pruebe otro camino.
    private var expectsVideo = true

    /// Superficie donde VLC pinta el vídeo (la pone VlcVideoView).
    let surface = VlcSurfaceView()

    #if canImport(MobileVLCKit)
    private let player = VLCMediaPlayer()
    private var startedAt = Date()
    #endif

    override init() {
        super.init()
        surface.backgroundColor = .black
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.clipsToBounds = true
        #if canImport(MobileVLCKit)
        player.drawable = surface
        player.delegate = self
        #endif
    }

    // MARK: - Arranque

    /// Opciones de VLC: colchón y cabeceras. VLC 3 solo sabe enviar User-Agent, Referer y Cookie; cualquier otra cabecera
    /// (tokens, X-…) la pone el relay local, y PlayerModel entonces le da a VLC la dirección del relay en vez de la original.
    static func options(headers: [String: String], networkCacheMs: Int) -> [String: Any] {
        // VLCMedia.addOptions antepone «:» a cada clave y escribe «clave=valor»
        // VLC no empieza a reproducir hasta llenar el colchón: con los 20 s de Ajustes una película de 30 Mbps tardaba minutos en enseñar imagen.
        // Se limita a 3 s; el reloj se deja como VLC lo trae (sin tocar clock-synchro ni clock-jitter).
        let cache = min(max(networkCacheMs, 1000), 3000)
        var o: [String: Any] = ["network-caching": cache, "file-caching": min(cache, 1500)]
        if let ua = RequestHeaders.value(headers, "User-Agent"), !ua.isEmpty { o["http-user-agent"] = ua }
        if let ref = RequestHeaders.value(headers, "Referer") ?? RequestHeaders.value(headers, "Referrer"), !ref.isEmpty { o["http-referrer"] = ref }
        if let cookie = RequestHeaders.value(headers, "Cookie"), !cookie.isEmpty { o["http-cookie"] = cookie }
        return o
    }

    /// Cabeceras que VLC no puede enviar por sí mismo (todas salvo User-Agent, Referer y Cookie): hay que pasar por el relay.
    static func needsRelayForHeaders(_ headers: [String: String]) -> Bool {
        headers.keys.contains { !["user-agent", "referer", "referrer", "cookie", "range"].contains($0.lowercased()) }
    }

    func play(url: URL, headers: [String: String], bufferSeconds: Double, expectsVideo: Bool = true) {
        self.expectsVideo = expectsVideo
        #if canImport(MobileVLCKit)
        stop()
        failed = false; errorText = nil; statusText = "abriendo…"
        let media = VLCMedia(url: url)
        media.addOptions(Self.options(headers: headers, networkCacheMs: Int(max(1, bufferSeconds) * 1000)))
        player.media = media
        player.drawable = surface                       // por si SwiftUI recreó la vista
        startedAt = Date()
        player.play()
        Trace.shared.log("vlc", "play \(url.host ?? url.lastPathComponent) · colchón \(Self.options(headers: headers, networkCacheMs: Int(max(1, bufferSeconds) * 1000))["network-caching"] ?? "?") ms")
        startHealthLog()
        #else
        failed = true; errorText = "Esta compilación no incluye VLC"
        #endif
    }

    func stop() {
        healthTask?.cancel(); healthTask = nil; pendingSeek = nil
        #if canImport(MobileVLCKit)
        if player.media != nil || player.isPlaying { player.stop() }
        #endif
        statusText = ""
        isPlaying = false; isBuffering = false; positionSec = 0; durationSec = 0
        audioChoices = []; subtitleChoices = []; audioInfo = ""
    }

    func pause() {
        #if canImport(MobileVLCKit)
        player.pause()
        #endif
    }
    func resume() {
        #if canImport(MobileVLCKit)
        player.play()
        #endif
    }

    func seek(to seconds: Double) {
        #if canImport(MobileVLCKit)
        // Antes de que arranque el vídeo VLC ignora el salto: se guarda y se aplica al empezar a sonar
        guard isPlaying, durationSec > 0 else { pendingSeek = seconds; return }
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
        #endif
    }

    /// Cada 5 s apunta qué ve VLC (para saber desde el PC por qué no hay imagen).
    private func startHealthLog() {
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                n += 1
                #if canImport(MobileVLCKit)
                let sz = self.player.videoSize
                Trace.shared.log("vlc", "salud \(n * 5)s · estado=\(self.player.state.rawValue) sonando=\(self.player.isPlaying) imagen=\(self.player.hasVideoOut) tamaño=\(Int(sz.width))x\(Int(sz.height)) t=\(self.player.time.intValue / 1000)s dur=\(self.durationSec)s audios=\(self.audioChoices.count) subs=\(self.subtitleChoices.count) superficie=\(Int(self.surface.bounds.width))x\(Int(self.surface.bounds.height)) enVentana=\(self.surface.window != nil)")
                if n >= 6 && !self.player.hasVideoOut && self.isPlaying { self.statusText = "suena pero VLC no da imagen" }
                // Solo audio: VLC reproduce el sonido pero no encuentra o no decodifica el vídeo (códec raro, pista de vídeo corrupta…).
                // Se avisa como error para que la pantalla de servidores pida al servidor que lo recodifique.
                if n >= 2, self.expectsVideo, self.player.isPlaying, self.player.time.intValue > 3000, !self.player.hasVideoOut, sz.width == 0 {
                    Trace.shared.log("vlc", "FALLO: suena pero no hay imagen tras \(n * 5) s → se avisa como error")
                    self.failed = true; self.statusText = ""
                    self.errorText = "VLC no pudo decodificar el vídeo (solo se oía el audio)"
                    return
                }
                #endif
            }
        }
    }

    // MARK: - Pistas

    func selectAudio(_ id: Int) {
        #if canImport(MobileVLCKit)
        player.currentAudioTrackIndex = Int32(id); refreshTracks()
        #endif
    }
    /// `nil` = sin subtítulos
    func selectSubtitle(_ id: Int?) {
        #if canImport(MobileVLCKit)
        player.currentVideoSubTitleIndex = Int32(id ?? -1); refreshTracks()
        #endif
    }
    /// Retardo del audio en milisegundos (positivo = suena más tarde). VLC lo cambia sin reiniciar.
    func setAudioDelay(ms: Int) {
        #if canImport(MobileVLCKit)
        player.currentAudioPlaybackDelay = ms * 1000
        #endif
    }
    /// Añade un subtítulo externo (fichero .srt/.vtt/.ass descargado o enlace).
    func addSubtitle(_ url: URL) {
        #if canImport(MobileVLCKit)
        player.addPlaybackSlave(url, type: .subtitle, enforce: true)
        #endif
    }

    /// El tiempo avanza: está reproduciendo aunque VLC siga diciendo «cargando». Quita la rueda y aplica la posición pendiente.
    func markPlaying() {
        #if canImport(MobileVLCKit)
        isPlaying = true; isBuffering = false; statusText = ""
        if let t = pendingSeek, durationSec > 0 { pendingSeek = nil; player.time = VLCTime(int: Int32(max(0, t) * 1000)) }
        #endif
    }

    /// Fotograma real que VLC está pintando (la captura normal de pantalla no ve el vídeo por GPU). Devuelve el JPEG y el brillo medio
    /// (0 = negro, 1 = blanco) para saber sin mirar si hay imagen de verdad. Solo para las pruebas.
    func snapshot() async -> (jpeg: Data, brightness: Double)? {
        #if canImport(MobileVLCKit)
        let path = NSTemporaryDirectory() + "vlc_snap_\(Int(Date().timeIntervalSince1970)).png"
        player.saveVideoSnapshot(at: path, withWidth: 640, andHeight: 0)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let d = FileManager.default.contents(atPath: path), let img = UIImage(data: d), let jpg = img.jpegData(compressionQuality: 0.6) {
                try? FileManager.default.removeItem(atPath: path)
                return (jpg, Self.brightness(of: img))
            }
        }
        #endif
        return nil
    }

    /// Brillo medio de una imagen: se reduce a 8x8 píxeles y se promedia.
    static func brightness(of img: UIImage) -> Double {
        guard let cg = img.cgImage else { return 0 }
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let ctx = CGContext(data: &px, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { sum += (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255 }
        return sum / 64
    }

    /// La vista ya está en pantalla: VLC pinta en ella (se vuelve a enlazar por si se había creado antes que la vista).
    func attachSurface() {
        #if canImport(MobileVLCKit)
        player.drawable = surface
        #endif
    }

    func refreshTracks() {
        #if canImport(MobileVLCKit)
        func list(_ names: [Any]?, _ idx: [Any]?, current: Int32) -> [PlayerModel.TrackChoice] {
            guard let n = names as? [String], let i = idx as? [NSNumber] else { return [] }
            return zip(n, i).compactMap { name, num in
                let id = num.intValue
                if id < 0 { return nil }                                  // «Desactivar» no es una pista
                return PlayerModel.TrackChoice(id: id, name: name, detail: "", selected: id == Int(current))
            }
        }
        audioChoices = list(player.audioTrackNames, player.audioTrackIndexes, current: player.currentAudioTrackIndex)
        subtitleChoices = list(player.videoSubTitlesNames, player.videoSubTitlesIndexes, current: player.currentVideoSubTitleIndex)
        audioInfo = audioChoices.first { $0.selected }?.name ?? ""
        let s = player.videoSize
        if s.width > 0 { videoSize = s }
        #endif
    }
}

#if canImport(MobileVLCKit)
extension VlcEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            let st = self.player.state
            if st.rawValue != self.lastLoggedState {
                self.lastLoggedState = st.rawValue
                Trace.shared.log("vlc", "estado \(st.rawValue) (0 parado, 1 abriendo, 2 cargando, 3 fin, 4 error, 5 sonando, 6 pausa, 7 pistas) a los \(Int(Date().timeIntervalSince(self.startedAt))) s")
            }
            switch st {
            case .playing:
                self.isPlaying = true; self.isBuffering = false; self.statusText = ""; self.refreshTracks()
                if let t = self.pendingSeek { self.pendingSeek = nil; self.player.time = VLCTime(int: Int32(max(0, t) * 1000)) }
            case .buffering:
                // VLC 3 informa «cargando» durante toda la reproducción: si el tiempo avanza, está sonando
                if self.player.isPlaying && self.positionSec > 0 { self.markPlaying() } else { self.isBuffering = true; self.statusText = "cargando…" }
            case .opening: self.isBuffering = true; self.statusText = "abriendo…"
            case .paused: self.isPlaying = false
            case .error:
                self.failed = true; self.isPlaying = false; self.statusText = ""
                self.errorText = "VLC no pudo abrir este vídeo"
                Trace.shared.log("vlc", "ERROR de reproducción tras \(Int(Date().timeIntervalSince(self.startedAt))) s")
            case .ended, .stopped: self.isPlaying = false
            default: break
            }
        }
    }
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            self.positionSec = Double(self.player.time.intValue) / 1000
            if self.player.isPlaying && self.positionSec > 0 && (!self.isPlaying || self.isBuffering || !self.statusText.isEmpty) { self.markPlaying() }
            let len = self.player.media?.length.intValue ?? 0
            if len > 0 { self.durationSec = Double(len) / 1000 }
            if self.audioChoices.isEmpty || self.subtitleChoices.isEmpty { self.refreshTracks() }   // las pistas aparecen unos instantes después de arrancar
        }
    }
}
#endif

/// Superficie donde pinta VLC. VLC mete su capa de vídeo como subvista con el tamaño que tenía la superficie al arrancar: si SwiftUI aún no la
/// había medido (tamaño 0), el vídeo suena pero no se ve. Aquí cada subvista se ajusta al tamaño real en cuanto se conoce y en cada cambio.
final class VlcSurfaceView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for v in subviews where v.frame != bounds { v.frame = bounds }
    }
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        setNeedsLayout()
    }
}

/// Vista SwiftUI de la superficie de VLC.
struct VlcVideoView: UIViewRepresentable {
    let engine: VlcEngine
    var onTap: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }
    final class Coordinator: NSObject {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func tapped() { onTap() }
    }
    func makeUIView(context: Context) -> UIView {
        let v = engine.surface
        engine.attachSurface()
        if v.gestureRecognizers?.isEmpty ?? true { v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))) }
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { context.coordinator.onTap = onTap }
}

/// Reproduce una película ya descargada con VLC (formatos que AVPlayer no abre: AVI, MKV con DTS/TrueHD, MPEG-2…), con sus pistas,
/// subtítulos bajados junto al fichero y ajuste del audio. Todo dentro de la app.
struct VlcOfflinePlayer: View {
    let file: URL, title: String
    var subs: [SubFile] = []
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = VlcEngine()
    @State private var showBar = true
    @State private var hide: Task<Void, Never>?
    @State private var audioDelay = 0
    private let full = AppSettings.fullscreen

    private func scheduleHide() {
        hide?.cancel()
        hide = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled { withAnimation { showBar = false } } }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VlcVideoView(engine: engine, onTap: { withAnimation { showBar = true }; scheduleHide() }).ignoresSafeArea()
            if engine.isBuffering && !engine.isPlaying { ProgressView().tint(.white).frame(maxHeight: .infinity) }
            VStack {
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.body.bold()).frame(width: 44, height: 44).background(.black.opacity(showBar ? 0.6 : 0.35), in: Circle())
                    }
                    if showBar {
                        Text(title).font(.subheadline.bold()).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                        if !engine.subtitleChoices.isEmpty || !subs.isEmpty {
                            Menu {
                                Button { engine.selectSubtitle(nil) } label: { Label("Sin subtítulos", systemImage: engine.subtitleChoices.contains { $0.selected } ? "" : "checkmark") }
                                ForEach(engine.subtitleChoices) { c in Button { engine.selectSubtitle(c.id) } label: { Label(c.name, systemImage: c.selected ? "checkmark" : "") } }
                                ForEach(subs, id: \.self) { s in Button { engine.addSubtitle(DownloadManager.folder.appendingPathComponent(s.file)) } label: { Label(s.name + " (archivo)", systemImage: "doc.text") } }
                            } label: { Image(systemName: "captions.bubble").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
                        }
                        if engine.audioChoices.count > 1 {
                            Menu {
                                ForEach(engine.audioChoices) { c in Button { engine.selectAudio(c.id) } label: { Label(c.name, systemImage: c.selected ? "checkmark" : "") } }
                            } label: { Image(systemName: "speaker.wave.2").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
                        }
                        ExternalFileButton(file: file, iconOnly: true)
                        AudioDelayButton(applied: $audioDelay, apply: { ms in engine.setAudioDelay(ms: ms); audioDelay = ms; return nil })
                    } else { Spacer() }
                }
                .foregroundStyle(.white).padding(.horizontal, 12).padding(.top, 76)
                Spacer()
                if let e = engine.errorText { Text(e).font(.caption).foregroundStyle(.red).padding(8).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)).padding() }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(full)
        .persistentSystemOverlays(full ? .hidden : .automatic)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.play(url: file, headers: [:], bufferSeconds: 2)
            // Subtítulos bajados junto al fichero: se añaden a VLC y el primero queda activo
            if let first = subs.first { engine.addSubtitle(DownloadManager.folder.appendingPathComponent(first.file)) }
            scheduleHide()
        }
        .onDisappear { hide?.cancel(); engine.stop() }
    }
}

/// Elige el reproductor de una descarga según el ajuste y el formato del fichero (AVPlayer para MP4/MOV, VLC para el resto).
struct OfflineRouter: View {
    let file: URL, title: String
    var subs: [SubFile] = []

    /// ¿Se abre con VLC? Con «Siempre VLC» sí; en automático, según la extensión y solo si VLC viene en la compilación.
    static func usesVlc(_ file: URL) -> Bool {
        guard VlcEngine.isAvailable else { return false }
        switch EngineSetting(rawValue: AppSettings.engine) ?? .auto {
        case .vlc: return true
        case .avplayer: return false
        case .auto: return EngineChooser.choose(setting: .auto, facts: MediaFacts(fileExtension: file.pathExtension)) == .vlc
        }
    }

    var body: some View {
        if Self.usesVlc(file) { VlcOfflinePlayer(file: file, title: title, subs: subs) }
        else { OfflinePlayer(file: file, title: title, subs: subs) }
    }
}

/// Aviso sobre la imagen mientras VLC abre o carga el vídeo (si no, solo se ve el fondo negro y no se sabe si va bien).
struct VlcStatusBadge: View {
    @ObservedObject var engine: VlcEngine
    var body: some View {
        if !engine.statusText.isEmpty && !engine.isPlaying || engine.statusText.hasPrefix("suena") {
            HStack(spacing: 8) { ProgressView().tint(.white); Text("VLC: \(engine.statusText)").font(.caption.bold()) }
                .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
        }
    }
}
