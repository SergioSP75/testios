import Foundation
import Combine
import AVFoundation
import VideoToolbox
import HLSCore

/// Reproduce un canal o película con AVPlayer y cuenta qué pasa (estado, error, tiempo).
/// Lo usan la pantalla del reproductor y el modo de pruebas automáticas.
@MainActor
final class PlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    /// Qué reproductor está abierto ahora: AVPlayer (con el relay propio) o VLC (decodifica casi todo por software).
    @Published private(set) var engine: PlaybackEngine = .avplayer
    /// Aviso permanente sobre el motor («VLC no abre contenido con claves: se usa el reproductor interno»); nil si no hay nada que avisar.
    @Published private(set) var engineNote: String?
    /// VLC estaba forzado pero hubo que usar el reproductor interno: la resolución fija se esconde, que no quede nada pegado a la imagen.
    private(set) var forcedFallback = false
    /// VLC: se crea la primera vez que hace falta (la librería es pesada).
    private(set) lazy var vlc = VlcEngine()
    private var vlcSinks: [AnyCancellable] = []
    /// Retardo del audio pedido por el usuario (ms): positivo = suena más tarde.
    @Published var audioDelayMs = 0
    /// El reproductor que está en marcha (lo usan las órdenes de depuración para simular acciones).
    static weak var current: PlayerModel?
    @Published var status = "preparando…"
    @Published var errorText: String?
    /// Resolución e velocidad que se están viendo ahora («1920x1080 · 6,2 Mbps»).
    @Published var qualityText = ""
    private(set) var duration: Double = 0
    private var tick = 0
    private var lastStart: (URL, [String: String], [String: String])?
    /// Calidad elegida a mano (0 = automática); se enseña marcada en el menú.
    @Published var chosenHeight = 0
    /// Subtítulo que toca enseñar ahora (lo dibuja la app con el estilo de Ajustes).
    @Published var subtitleText = ""
    private let legibleBridge = LegibleBridge()
    /// Pistas de audio y de subtítulos que ofrece el título y cuál suena ahora (menús propios del reproductor).
    struct TrackChoice: Identifiable, Equatable { var id: Int; var name: String; var detail: String; var selected: Bool }
    @Published var audioChoices: [TrackChoice] = []
    @Published var subtitleChoices: [TrackChoice] = []
    /// Lo que suena ahora: «Español · E-AC-3 5.1».
    @Published var audioInfo = ""
    private var subtitleLogged = false
    /// Si con la resolución mínima de Ajustes no abre, se vuelve a intentar sin ella (una sola vez).
    private var fellBack = false
    /// Tope de altura que se pone solo si ni la resolución mínima ni «sin mínima» abren (p. ej. 4K Dolby Vision que el aparato no decodifica): 1080.
    private var capHeight = 0
    /// Las pantallas lo activan cuando VLC ya falló con este título: a partir de ahí se usa el reproductor interno aunque VLC esté forzado.
    private(set) var preferInternal = false
    private var internalReason = ""
    func useInternalPlayer(_ why: String) { preferInternal = true; internalReason = why }
    /// Ya se probó VLC tras un fallo de AVPlayer en este título (no se repite).
    private var fellBackToVlc = false
    /// Aviso mientras se prueba con otra pista porque la elegida no abre («Probando con otra pista…»); se quita solo al arrancar bien.
    @Published var notice: String?
    /// Grupos de audio que ya se probaron y no abrieron, y los que ofrece la lista (para probar el siguiente)
    private var triedGroups = Set<String>()
    private var knownGroups: [String] = []
    /// Todas las pistas de audio del manifiesto, de todos los grupos de códec (el reproductor solo ofrece las de un grupo).
    struct AudioEntry: Identifiable, Equatable { var id: String; var group: String; var name: String; var lang: String; var isDescription: Bool; var selected: Bool }
    @Published var allAudio: [AudioEntry] = []
    /// Calidades de vídeo de la lista (etiquetadas como en Android: «2160p · VP9 · HDR10 (PQ) · 15.0 Mbps»)
    @Published var videoOptions: [VideoVariant] = []
    private var parsedAudio: [AudioEntry] = []
    private var chosenAudioGroup: String?          // grupo forzado en el relay al cambiar de idioma
    private var pendingAudioName: String?          // pista a marcar cuando arranque de nuevo
    private var currentAudioGroup: String?
    private var recoveredAt = 0.0
    private var recoveries = 0                    // veces que se recuperó una reproducción parada

    /// Elige una pista de audio de la lista completa: dentro del grupo en uso se cambia al momento; en otro grupo se reinicia.
    func chooseAudio(_ e: AudioEntry) {
        if e.group == currentAudioGroup || currentAudioGroup == nil, let i = choiceIndex(for: e) { selectAudio(i) }
        else { Task { await restartAudio(e) } }
    }

    private var plan: RelayManager.Plan?
    private var startGen = 0
    private var observer: NSKeyValueObservation?
    private var timeObserver: Any?
    private(set) var lastTime: Double = 0
    /// Comprobación de imagen: salida de vídeo que fuerza a decodificar y cuenta fotogramas recibidos.
    private var videoOutput: AVPlayerItemVideoOutput?
    private(set) var videoFrames = 0
    private(set) var videoSize = CGSize.zero
    private var tokens: [NSObjectProtocol] = []
    private var rateObserver: NSKeyValueObservation?

    /// Prepara y arranca. `headers` y `clearKeys` salen de la lista (User-Agent, Referer, claves).
    func start(url: URL, headers: [String: String], clearKeys: [String: String], fixedHeight: Int = 0, minHeight: Int? = nil, audioGroup: String? = nil) async {
        // Como en Android: un User-Agent «default» en la lista significa «el de la app», no el texto literal
        var headers = headers
        if headers["User-Agent"]?.lowercased() == "default" { headers["User-Agent"] = ServerUa.standard }
        // Vídeo de un servidor externo (Emby, Jellyfin, Plex, proxies .strm): lleva el user agent de Ajustes → Servidores
        if headers["User-Agent"] == nil, let ua = ServerUa.forUrl(url.absoluteString) { headers["User-Agent"] = ua }
        headers = RequestHeaders.merge(headers, ServerHeaders.forUrl(url.absoluteString))        // cabeceras propias de los servidores
        lastStart = (url, headers, clearKeys)
        PlayerModel.current = self
        if minHeight == nil, fixedHeight == 0 { fellBack = false; fellBackToVlc = false; capHeight = 0 }
        if minHeight == nil, fixedHeight == 0, audioGroup == nil { triedGroups = []; notice = nil }
        if audioGroup == nil, minHeight == nil, fixedHeight == 0 { chosenAudioGroup = nil }      // arranque nuevo: sin grupo forzado
        else if audioGroup != nil { chosenAudioGroup = audioGroup }
        stop()
        engineNote = nil; forcedFallback = false
        startGen += 1; let gen = startGen
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        // Motor: ajuste del usuario + lo que se sabe del título. Los contenedores que AVPlayer no abre (AVI, FLAC, WMV…) van directos a VLC;
        // con «Siempre VLC» y sin DRM también (VLC lee HLS, DASH y ficheros por sí mismo). Con claves hace falta el relay que descifra.
        let setting = preferInternal ? EngineSetting.avplayer : (EngineSetting(rawValue: AppSettings.engine) ?? .auto)
        if preferInternal {
            engineNote = internalReason
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if let self = self, self.startGen == gen { self.engineNote = nil }
            }
        }
        let ext = EngineChooser.fileExtension(of: url.absoluteString)
        if VlcEngine.isAvailable, clearKeys.isEmpty, engineFor(setting: setting, ext: ext) == .vlc, !VlcEngine.needsRelayForHeaders(headers) {
            startVlc(url: url, headers: headers, reason: setting == .vlc ? "motor VLC (ajuste)" : "VLC (formato .\(ext.isEmpty ? "?" : ext))")
            return
        }

        let plan = await RelayManager.shared.plan(url: url, headers: headers, clearKeys: clearKeys, fixedHeight: fixedHeight > 0 ? fixedHeight : capHeight, minHeight: minHeight, audioGroup: chosenAudioGroup)
        // Otro arranque (otro canal) se adelantó mientras se preparaba este: se descarta
        guard gen == startGen else { RelayManager.shared.end(plan); return }
        self.plan = plan
        if VlcEngine.isAvailable {
            // VLC no descifra ClearKey, SAMPLE-AES ni FairPlay: con claves (o un HLS cifrado) se usa el reproductor interno aunque se haya forzado VLC
            let isDrm = !clearKeys.isEmpty || plan.reason.contains("hlsEncrypted")
            if setting == .vlc && isDrm {
                engineNote = "VLC no abre contenido con claves (ClearKey/DRM): se usa el reproductor interno"
                Trace.shared.log("vlc", "forzado a VLC pero hay claves/DRM → reproductor interno")
                forcedFallback = true
                // El aviso se queda 6 s y se quita solo; entonces la pantalla se queda solo con el vídeo
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if let self = self, self.startGen == gen { self.engineNote = nil }
                }
            }
            let wantsVlc = (setting == .vlc && !isDrm) || (setting == .auto && !plan.viaRelay && plan.reason.hasPrefix("MKV directo"))
            if wantsVlc {
                // Con relay (descifrado, DASH→HLS…) VLC lee el HLS del relay; sin relay, la dirección original
                if plan.viaRelay { self.plan = plan } else { RelayManager.shared.end(plan); self.plan = nil }
                startVlc(url: plan.viaRelay ? plan.url : url, headers: plan.viaRelay ? [:] : headers, reason: "VLC · " + plan.reason)
                return
            }
        }
        if let sid = plan.sessionId, let m = RelayManager.shared.mkv(sid) { m.audioDelayMs = audioDelayMs }
        if plan.viaRelay { Task { await self.loadAllAudio(plan.url) } }
        status = "reproduciendo por: \(plan.reason)"

        // Con relay las cabeceras las pone el relay; sin él las lleva el propio AVPlayer
        // El User-Agent dentro de HTTPHeaderFields lo ignora a veces el sistema: se pasa también por su clave propia (iOS 16+)
        var opts: [String: Any]? = (plan.viaRelay || headers.isEmpty) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        if !plan.viaRelay, let ua = headers["User-Agent"], #available(iOS 16.0, *) { opts?[AVURLAssetHTTPUserAgentKey] = ua }
        let item = AVPlayerItem(asset: AVURLAsset(url: plan.url, options: opts))
        // Colchón de vídeo por delante: más segundos = menos microcortes en directo (ajustable en Ajustes → Reproductor)
        item.preferredForwardBufferDuration = AppSettings.bufferSeconds
        if AppSettings.maxHeight > 0 { item.preferredMaximumResolution = CGSize(width: CGFloat(AppSettings.maxHeight) * 16 / 9, height: CGFloat(AppSettings.maxHeight)) }
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out); videoOutput = out
        // Subtítulos como texto: la app los dibuja con su estilo (color, tamaño y posición) en lugar del sistema
        if AppSettings.ownSubtitles {
            let leg = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
            leg.suppressesPlayerRendering = true
            legibleBridge.onText = { [weak self] t in
                guard let self = self else { return }
                self.subtitleText = t
                if !t.isEmpty, !self.subtitleLogged { self.subtitleLogged = true; Trace.shared.log("avplayer", "primer subtítulo recibido: \(t.prefix(40))") }
            }
            leg.setDelegate(legibleBridge, queue: .main)
            item.add(leg)
        }
        let p = AVPlayer(playerItem: item)
        DownloadManager.shared.register(p)
        p.automaticallyWaitsToMinimizeStalling = true
        p.preventsDisplaySleepDuringVideoPlayback = true
        p.allowsExternalPlayback = true          // sin esto desaparece el botón de AirPlay
        observer = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in
                guard let self = self else { return }
                if it.status == .failed {
                    self.errorText = self.describe(it); Trace.shared.log("avplayer", "ERROR \(self.errorText ?? "")")
                    // La resolución mínima deja solo variantes grandes (p. ej. 4K HDR) que a veces no abren: se prueba sin ese filtro
                    if !self.fellBack, fixedHeight == 0, minHeight == nil, plan.viaRelay, AppSettings.minHeight > 0, let a = self.lastStart {
                        self.fellBack = true
                        Trace.shared.log("avplayer", "no abre con resolución mínima \(AppSettings.minHeight)p: se reintenta sin ella")
                        self.notice = "Probando con otra pista…"
                        await self.start(url: a.0, headers: a.1, clearKeys: a.2, fixedHeight: 0, minHeight: 0)
                    } else if plan.viaRelay, self.capHeight == 0, fixedHeight == 0, self.chosenHeight == 0, let a = self.lastStart {
                        // Aún con todas las variantes disponibles se elige la más alta (4K, Dolby Vision…) y no abre: se limita a 1080
                        self.capHeight = 1080
                        self.notice = "Probando con 1080p…"
                        Trace.shared.log("avplayer", "no abre en la resolución más alta: se limita a 1080p")
                        await self.start(url: a.0, headers: a.1, clearKeys: a.2, fixedHeight: 0, minHeight: 0)
                    } else if plan.viaRelay, let a = self.lastStart, let next = self.nextGroupToTry() {
                        // Como en Android: si la pista elegida no abre en este aparato (-11848 «el contenido no se puede usar»…), se prueba con otra
                        self.triedGroups.insert(next)
                        self.notice = "Probando con otra pista…"
                        Trace.shared.log("avplayer", "no abre: se prueba con el grupo de audio «\(next)»")
                        await self.start(url: a.0, headers: a.1, clearKeys: a.2, fixedHeight: self.chosenHeight, minHeight: 0, audioGroup: next)
                    } else if VlcEngine.isAvailable, EngineChooser.fallbackAfterFailure(setting: EngineSetting(rawValue: AppSettings.engine) ?? .auto, current: .avplayer) != nil,
                              !self.fellBackToVlc, let a = self.lastStart {
                        // Último recurso: VLC decodifica por software lo que AVPlayer no abre (solo en «Automático»)
                        self.fellBackToVlc = true
                        self.notice = "Probando con VLC…"
                        Trace.shared.log("avplayer", "no abre: se prueba con VLC")
                        self.player?.pause(); self.player = nil
                        self.startVlc(url: plan.viaRelay ? plan.url : a.0, headers: plan.viaRelay ? [:] : a.1, reason: "VLC (AVPlayer no pudo abrirlo)")
                    }
                }
                if it.status == .readyToPlay { self.notice = nil; self.triedGroups = []; self.refreshTracks(it); self.status = "listo (\(plan.reason))"; Trace.shared.log("avplayer", "listo · pistas=\(it.asset.tracks.count)") }
            }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self = self else { return }
            self.lastTime = t.seconds
            if self.recoveries > 0, t.seconds > self.recoveredAt + 90 { self.recoveries = 0 }      // lleva un rato bien: se olvidan los fallos
            self.tick += 1
            if self.tick % 20 == 0, let it = p.currentItem {          // cada 10 s: estado del colchón y de los fotogramas
                let ahead = it.loadedTimeRanges.compactMap { $0.timeRangeValue }.first { $0.containsTime(it.currentTime()) }.map { $0.end.seconds - it.currentTime().seconds } ?? 0
                let ev = it.accessLog()?.events.last
                Trace.shared.log("salud", "colchón \(String(format: "%.1f", ahead)) s · descartados \(ev?.numberOfDroppedVideoFrames ?? 0) · atascos \(ev?.numberOfStalls ?? 0) · observado \(Int((ev?.observedBitrate ?? 0) / 1000)) kbps · imagen \(self.videoFrames) fotogramas")
            }
            // Un fotograma nuevo = el vídeo se decodifica de verdad (el audio solo no lo prueba)
            if let out = self.videoOutput, let item = p.currentItem {
                let ts = item.currentTime()
                if out.hasNewPixelBuffer(forItemTime: ts), out.copyPixelBuffer(forItemTime: ts, itemTimeForDisplay: nil) != nil { self.videoFrames += 1; if self.videoFrames == 1 { Trace.shared.log("avplayer", "PRIMER FOTOGRAMA de vídeo decodificado") } }
                if self.videoSize != item.presentationSize { Trace.shared.log("avplayer", "tamaño de imagen \(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))") }
                self.videoSize = item.presentationSize
                let d = item.duration.seconds; if d.isFinite { self.duration = d }
                if let ev = item.accessLog()?.events.last, item.presentationSize.width > 0 {
                    self.qualityText = "\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) · \(String(format: "%.1f", ev.indicatedBitrate / 1_000_000)) Mbps"
                }
            }
        }
        // Todo lo que cuenta AVPlayer va al canal de trazas
        let nc = NotificationCenter.default
        tokens = [
            nc.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { _ in
                if let e = item.errorLog()?.events.last { Trace.shared.log("avplayer", "errorLog \(e.errorStatusCode) \(e.errorDomain) \(e.errorComment ?? "") \(e.uri ?? "")") }
            },
            nc.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main) { _ in
                if let e = item.accessLog()?.events.last { Trace.shared.log("avplayer", "acceso bitrate=\(Int(e.indicatedBitrate)) observado=\(Int(e.observedBitrate)) descartados=\(e.numberOfDroppedVideoFrames)") }
            },
            nc.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
                self?.refreshTracks(item)
                // Qué audio y subtítulo hay elegidos ahora (para diagnosticar cambios de pista)
                var d: [String] = []
                for ch in [AVMediaCharacteristic.audible, .legible] {
                    if let g = item.asset.mediaSelectionGroup(forMediaCharacteristic: ch) {
                        let o = item.currentMediaSelection.selectedMediaOption(in: g)
                        d.append("\(ch == .audible ? "audio" : "subtítulo")=\(o?.displayName ?? "ninguno")[\(o?.extendedLanguageTag ?? "?")] de \(g.options.count)")
                    }
                }
                Trace.shared.log("avplayer", "pista elegida: " + d.joined(separator: " · "))
            },
            nc.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { _ in
                Trace.shared.log("avplayer", "SALTO de tiempo en \(String(format: "%.2f", p.currentTime().seconds)) s")
            },
            nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
                Trace.shared.log("avplayer", "ATASCO: se quedó sin datos en \(String(format: "%.2f", p.currentTime().seconds)) s")
            },
            nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] n in
                Trace.shared.log("avplayer", "falló a mitad: \((n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription ?? "?")")
                // Un trozo que el servidor rechazó (403/502) deja la reproducción parada: se vuelve a preparar y se retoma donde estaba
                guard let self = self, self.recoveries < 3, self.duration > 0, self.duration.isFinite, let a = self.lastStart else { return }
                self.recoveries += 1
                let pos = p.currentTime().seconds
                self.recoveredAt = pos
                Trace.shared.log("avplayer", "recuperando en \(Int(pos)) s (intento \(self.recoveries)/3)")
                Task { @MainActor in
                    self.pendingAudioName = self.selectedEntryKey()
                    await self.start(url: a.0, headers: a.1, clearKeys: a.2, fixedHeight: self.chosenHeight, audioGroup: self.chosenAudioGroup)
                    try? await Task.sleep(nanoseconds: 800_000_000); self.seek(to: pos)
                }
            }
        ]
        rateObserver = p.observe(\.timeControlStatus, options: [.new]) { pl, _ in
            let st = pl.timeControlStatus == .playing ? "reproduciendo" : pl.timeControlStatus == .paused ? "pausado" : "esperando (\(pl.reasonForWaitingToPlay?.rawValue ?? "?"))"
            Task { @MainActor in Trace.shared.log("avplayer", st) }
        }
        Trace.shared.log("avplayer", "start \(plan.url.host ?? "?") · \(plan.reason)")
        player = p
        p.play()
    }

    /// Motor que corresponde al ajuste y a la extensión, sin mirar aún el contenido (eso lo hace el relay después).
    private func engineFor(setting: EngineSetting, ext: String) -> PlaybackEngine {
        switch setting {
        case .vlc: return ["mpd", "ism", "m3u8", "m3u"].contains(ext) ? .avplayer : .vlc      // manifiestos: antes pasan por el relay por si llevan DRM
        case .avplayer: return .avplayer
        case .auto: return EngineChooser.vlcOnlyExtensions.contains(ext) ? .vlc : .avplayer
        }
    }

    /// Arranca VLC con la dirección dada y enlaza su estado (posición, pistas, error) con el modelo.
    private func startVlc(url: URL, headers: [String: String], reason: String) {
        engine = .vlc
        player = nil
        vlcSinks.forEach { $0.cancel() }
        vlcSinks = [
            vlc.$positionSec.sink { [weak self] in self?.lastTime = $0 },
            vlc.$durationSec.sink { [weak self] in self?.duration = $0 },
            vlc.$videoSize.sink { [weak self] s in
                guard let self = self, s.width > 0 else { return }
                self.videoSize = s; self.qualityText = "\(Int(s.width))x\(Int(s.height)) · VLC"
            },
            vlc.$audioChoices.sink { [weak self] in self?.audioChoices = $0 },
            vlc.$subtitleChoices.sink { [weak self] in self?.subtitleChoices = $0 },
            vlc.$audioInfo.sink { [weak self] in self?.audioInfo = $0 },
            vlc.$isPlaying.sink { [weak self] playing in if playing { self?.notice = nil } },
            vlc.$errorText.sink { [weak self] in if let e = $0 { self?.errorText = e } },
        ]
        status = "reproduciendo por: \(reason)"
        notice = nil
        Trace.shared.log("vlc", reason)
        // En música no hay imagen que esperar
        let ext = EngineChooser.fileExtension(of: url.absoluteString)
        let audioOnly = ["mp3", "flac", "wav", "aac", "m4a", "ogg", "opus", "wma", "ac3", "dts"].contains(ext)
        vlc.play(url: url, headers: headers, bufferSeconds: AppSettings.bufferSeconds, expectsVideo: !audioOnly)
    }

    /// Vuelve a leer qué pistas hay y cuál está elegida (al abrir y cada vez que cambia la selección).
    func refreshTracks(_ item: AVPlayerItem) {
        let sel = item.currentMediaSelection
        func choices(_ ch: AVMediaCharacteristic) -> [TrackChoice] {
            guard let g = item.asset.mediaSelectionGroup(forMediaCharacteristic: ch) else { return [] }
            let cur = sel.selectedMediaOption(in: g)
            return g.options.enumerated().map { i, o in
                var d: [String] = []
                if let l = o.extendedLanguageTag ?? o.locale?.identifier { d.append(l) }
                if o.hasMediaCharacteristic(.describesVideoForAccessibility) { d.append("audiodescripción") }
                if o.hasMediaCharacteristic(.containsOnlyForcedSubtitles) { d.append("forzados") }
                if o.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) { d.append("CC") }
                return TrackChoice(id: i, name: o.displayName, detail: d.joined(separator: " · "), selected: o == cur)
            }
        }
        audioChoices = choices(.audible)
        subtitleChoices = choices(.legible)
        // Todas las pistas del manifiesto (de todos los grupos), con la que suena marcada
        if !parsedAudio.isEmpty {
            // Grupo en uso: el que tiene las mismas pistas, en el mismo orden (por idioma), que las que ofrece el reproductor
            let tags = audioChoices.map { Self.tag($0) }
            let groups = Dictionary(grouping: parsedAudio, by: { $0.group })
            func score(_ g: [AudioEntry]) -> Int { zip(g.map { $0.lang.lowercased().replacingOccurrences(of: "_", with: "-") }, tags).filter { $0 == $1 }.count - abs(g.count - tags.count) }
            // Si ya se sabe el códec que suena (E-AC-3, AAC…), pesa más que el resto: los grupos de códec tienen los mismos idiomas
            let codec = Self.playingAudioCodec(item)
            func codecBonus(_ g: [AudioEntry]) -> Int { codec != nil && g.first.map({ $0.name.contains(codec!) }) == true ? 1000 : 0 }
            let best = groups.max { score($0.value) + codecBonus($0.value) < score($1.value) + codecBonus($1.value) }
            currentAudioGroup = best?.key
            allAudio = mergeAudio(current: Set(best?.value.map { $0.id } ?? []), selectedName: selectedEntryKey())
        }
        // Tras reiniciar por un cambio de idioma: se marca la pista pedida
        if let want = pendingAudioName, let e = parsedAudio.first(where: { $0.group == currentAudioGroup && Self.baseName($0.name) == Self.baseName(want) }), let i = choiceIndex(for: e) {
            pendingAudioName = nil
            if !(audioChoices.first { $0.id == i }?.selected ?? true) { selectAudio(i) }
        }
        // Formato real que suena: códec y canales de la pista de audio activa
        // Nombre legible (en el idioma del aparato) de la pista que suena; el del sistema viene en inglés
        var info = (selectedEntryKey() ?? audioChoices.first { $0.selected }?.name).map { Self.baseName($0) } ?? ""
        if let t = item.tracks.first(where: { $0.isEnabled && $0.assetTrack?.mediaType == .audio }),
           let fd = t.assetTrack?.formatDescriptions.first {
            let desc = fd as! CMFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                let codec: String
                switch asbd.mFormatID {
                case kAudioFormatEnhancedAC3: codec = "E-AC-3"
                case kAudioFormatAC3: codec = "AC-3"
                case kAudioFormatMPEG4AAC: codec = "AAC"
                default: codec = "audio"
                }
                let ch = asbd.mChannelsPerFrame
                info += (info.isEmpty ? "" : " · ") + codec + " " + (ch == 6 ? "5.1" : ch == 8 ? "7.1" : ch == 2 ? "estéreo" : "\(ch) canales")
            }
        }
        if info != audioInfo { audioInfo = info; Trace.shared.log("avplayer", "audio activo: \(info)") }
    }

    /// ¿Puede este aparato decodificar esa pista? (H.264 siempre; HEVC, VP9 y AV1 según el hardware, como «no compatible» en Android)
    static func canDecode(_ v: VideoVariant) -> Bool {
        switch v.codec {
        case "HEVC", "Dolby Vision": return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        case "VP9": return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        case "AV1": if #available(iOS 17.0, *) { return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) } else { return false }
        default: return true
        }
    }

    /// Siguiente grupo de audio que probar tras un fallo: uno de la lista que aún no se haya intentado.
    private func nextGroupToTry() -> String? {
        let failed = chosenAudioGroup.map { triedGroups.union([$0]) } ?? triedGroups
        return knownGroups.first { !failed.contains($0) }
    }

    /// Código de idioma de una pista del reproductor (lo primero de su detalle: «es-ES», «en-US»…), en minúsculas.
    private static func tag(_ c: TrackChoice) -> String { (c.detail.components(separatedBy: " · ").first ?? "").lowercased().replacingOccurrences(of: "_", with: "-") }

    /// Códec («E-AC-3», «AC-3», «AAC») de la pista de audio que suena ahora, si ya se puede saber.
    private static func playingAudioCodec(_ item: AVPlayerItem) -> String? {
        guard let t = item.tracks.first(where: { $0.isEnabled && $0.assetTrack?.mediaType == .audio }),
              let fd = t.assetTrack?.formatDescriptions.first else { return nil }
        let desc = fd as! CMFormatDescription
        switch CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee.mFormatID {
        case kAudioFormatEnhancedAC3: return "E-AC-3"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatMPEG4AAC: return "AAC"
        default: return nil
        }
    }

    /// Pista del reproductor que corresponde a una entrada de la lista: la que ocupa su misma posición dentro del grupo en uso;
    /// si las listas no cuadran, la del mismo idioma (y misma audiodescripción). Los nombres no sirven: el sistema los escribe en inglés.
    private func choiceIndex(for e: AudioEntry) -> Int? {
        let ge = parsedAudio.filter { $0.group == currentAudioGroup }
        if ge.count == audioChoices.count, let i = ge.firstIndex(where: { Self.baseName($0.name) == Self.baseName(e.name) }) { return i }
        let t = e.lang.lowercased().replacingOccurrences(of: "_", with: "-")
        return audioChoices.first { Self.tag($0) == t && $0.detail.contains("audiodescripción") == e.isDescription }?.id
    }

    /// Nombre (legible) de la entrada que suena ahora, la inversa de `choiceIndex`.
    private func selectedEntryKey() -> String? {
        guard let s = audioChoices.first(where: { $0.selected }) else { return nil }
        let ge = parsedAudio.filter { $0.group == currentAudioGroup }
        if ge.count == audioChoices.count, s.id < ge.count { return ge[s.id].name }
        return parsedAudio.first { $0.group == currentAudioGroup && $0.lang.lowercased().replacingOccurrences(of: "_", with: "-") == Self.tag(s) && $0.isDescription == s.detail.contains("audiodescripción") }?.name
    }

    /// Nombre de la pista sin «· códec canales» (el relay lo añade al nombre; entre grupos de códec cambia, el idioma no)
    static func baseName(_ n: String) -> String { n.components(separatedBy: " · ").first ?? n }

    /// Elige una pista de audio (`index` del menú) o de subtítulos (`nil` = sin subtítulos).
    func selectAudio(_ index: Int) {
        if engine == .vlc { vlc.selectAudio(index); return }
        guard let item = player?.currentItem, let g = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible), index < g.options.count else { return }
        item.select(g.options[index], in: g)
    }
    func selectSubtitle(_ index: Int?) {
        if engine == .vlc { vlc.selectSubtitle(index); return }
        guard let item = player?.currentItem, let g = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if let i = index, i < g.options.count { item.select(g.options[i], in: g) } else { item.select(nil, in: g); subtitleText = "" }
    }

    /// Salta a una posición (para continuar donde se dejó).
    /// Dirección original del vídeo para abrirlo en otra app (nil si lleva claves DRM: una app externa no las tiene).
    var externalURL: String? { guard let a = lastStart, a.2.isEmpty else { return nil }; return a.0.absoluteString }

    /// Mueve el audio respecto a la imagen. Hoy vale para los MKV pasados a HLS en el dispositivo (se reinicia por donde iba);
    /// en descargas lo hace el reproductor de descargas. Devuelve un texto si este tipo de reproducción no lo admite.
    func setAudioDelay(_ ms: Int) async -> String? {
        if engine == .vlc { vlc.setAudioDelay(ms: ms); audioDelayMs = ms; return nil }       // VLC mueve el audio al vuelo
        guard let sid = plan?.sessionId, let m = RelayManager.shared.mkv(sid) else {
            return "Este tipo de reproducción no permite mover el audio. Funciona en MKV pasados a HLS en el iPad y en las descargas."
        }
        m.audioDelayMs = ms; audioDelayMs = ms
        guard let a = lastStart else { return nil }
        let t = lastTime
        await start(url: a.0, headers: a.1, clearKeys: a.2)
        seek(to: t)
        return nil
    }

    func seek(to seconds: Double) {
        if engine == .vlc { vlc.seek(to: seconds); return }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Fija la calidad: se vuelve a preparar la reproducción con solo la variante que corresponde (0 = automática)
    /// y se retoma por donde iba. Cambiar `preferredMaximumResolution` en marcha apenas se notaba.
    func setQuality(height: Int) async {
        guard let a = lastStart else { return }
        let pos = lastTime, vod = duration > 0 && duration.isFinite
        chosenHeight = height
        Trace.shared.log("avplayer", "calidad \(height > 0 ? "fija ≤\(height)p" : "automática") · reinicio en \(Int(pos)) s")
        pendingAudioName = selectedEntryKey()
        await start(url: a.0, headers: a.1, clearKeys: a.2, fixedHeight: height, audioGroup: chosenAudioGroup)
        if vod, pos > 5 { try? await Task.sleep(nanoseconds: 800_000_000); seek(to: pos) }
    }

    /// Cambia a una pista de audio de otro grupo de códec: se reinicia la reproducción con solo ese grupo y se retoma
    /// por donde iba (AVPlayer solo deja elegir entre las pistas del grupo que está usando).
    func restartAudio(_ entry: AudioEntry) async {
        guard let a = lastStart else { return }
        let pos = lastTime, vod = duration > 0 && duration.isFinite
        Trace.shared.log("avplayer", "audio «\(entry.name)» está en el grupo \(entry.group): se reinicia en \(Int(pos)) s")
        pendingAudioName = entry.name
        await start(url: a.0, headers: a.1, clearKeys: a.2, fixedHeight: chosenHeight, audioGroup: entry.group)
        if vod, pos > 5 { try? await Task.sleep(nanoseconds: 800_000_000); seek(to: pos) }
    }

    /// Lee del manifiesto (ya pasado por el relay) todas las pistas de audio de todos los grupos.
    private func loadAllAudio(_ url: URL) async {
        // Lista completa (todos los grupos de audio y calidades), no la recortada que ve el reproductor
        let full = URL(string: url.absoluteString + "&full=1") ?? url
        guard let data = try? await URLSessionFetcher().fetch(full, headers: [:]) else { return }
        var out: [AudioEntry] = []
        func attr(_ l: String, _ n: String) -> String? {
            guard let r = l.range(of: "\(n)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
            return String(l[r].dropFirst(n.count + 2).dropLast())
        }
        for l in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) where l.hasPrefix("#EXT-X-MEDIA") && l.contains("TYPE=AUDIO") {
            let name = attr(l, "NAME") ?? "", group = attr(l, "GROUP-ID") ?? ""
            let ad = l.contains("describes-video") || name.lowercased().contains("audio description")
            out.append(AudioEntry(id: group + "|" + name, group: group, name: name, lang: attr(l, "LANGUAGE") ?? "", isDescription: ad, selected: false))
        }
        parsedAudio = out
        knownGroups = Array(NSOrderedSet(array: out.map { $0.group })) as? [String] ?? []
        if chosenHeight == 0 || videoOptions.isEmpty { videoOptions = VideoLabels.variants(String(decoding: data, as: UTF8.self)) }
        if let it = player?.currentItem { refreshTracks(it) }
    }

    /// Entradas únicas por nombre (la del grupo en uso si existe, si no la primera) con la que suena marcada.
    private func mergeAudio(current: Set<String>, selectedName: String?) -> [AudioEntry] {
        var byName: [String: AudioEntry] = [:], order: [String] = []
        for e in parsedAudio {
            let k = Self.baseName(e.name)
            if let have = byName[k] {
                // Preferir la copia que está en el grupo actual (se elige sin reiniciar)
                if !current.contains(have.id), current.contains(e.id) { byName[k] = e }
            } else { byName[k] = e; order.append(k) }
        }
        let sel = selectedName.map { Self.baseName($0) }
        return order.compactMap { n in byName[n].map { var x = $0; x.selected = (n == sel); return x } }
    }

    /// Reproduce un canal de lista con sus cabeceras y claves.
    func play(_ channel: IptvChannel) async {
        guard let url = URL(string: channel.url) else { errorText = "dirección no válida"; return }
        var headers = channel.httpHeaders
        if let ua = channel.userAgent { headers["User-Agent"] = ua }
        if let ref = channel.referrer { headers["Referer"] = ref }
        await start(url: url, headers: headers, clearKeys: channel.clearKeys)
    }

    func stop() {
        if engine == .vlc { vlc.stop() }
        vlcSinks.forEach { $0.cancel() }; vlcSinks = []
        engine = .avplayer
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        observer = nil; rateObserver = nil
        tokens.forEach { NotificationCenter.default.removeObserver($0) }; tokens = []
        player?.pause(); player = nil
        if let p = plan { RelayManager.shared.end(p) }
        plan = nil; lastTime = 0; errorText = nil; subtitleText = ""; audioChoices = []; subtitleChoices = []; allAudio = []; videoOptions = []; parsedAudio = []; audioInfo = ""; subtitleLogged = false; videoOutput = nil; videoFrames = 0; videoSize = .zero
    }

    /// Error de AVPlayer con causa legible (más detalle que el mensaje genérico).
    private func describe(_ item: AVPlayerItem) -> String {
        var out = item.error?.localizedDescription ?? "error desconocido"
        if let ns = item.error as NSError? {
            out += " [\(ns.domain) \(ns.code)]"
            // Causa interna que da el sistema (suele decir qué pista o qué lista no le gusta)
            for (k, v) in ns.userInfo where k != NSLocalizedDescriptionKey { out += " · \(k)=\(String(describing: v).prefix(300))" }
        }
        for t in item.asset.tracks { out += " · pista \(t.mediaType.rawValue)" }
        if let ev = item.errorLog()?.events.last {
            out += " · \(ev.errorStatusCode) \(ev.errorComment ?? "") \(ev.uri ?? "")"
        }
        return out
    }
}
