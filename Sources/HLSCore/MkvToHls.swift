import Foundation

/// Quien contesta a AVPlayer cuando pide al relay local (RelayCore para DASH/HLS cifrado; MkvToHls para MKV).
public protocol RelayHandler: AnyObject {
    func handle(path: String) async -> RelayResponse
}
extension RelayCore: RelayHandler {}

/// Pasa un MKV a HLS fMP4 SIN recodificar, al vuelo: AVPlayer no abre el contenedor MKV, pero sí H.264/HEVC y AAC/AC-3/E-AC-3.
///  - la lista maestra enseña el vídeo y cada audio compatible como pista alternativa;
///  - cada segmento (un grupo de clusters del fichero) se pide al servidor con «Range», se reempaqueta en fMP4 y se entrega;
///  - los tiempos de las tramas de vídeo con reordenación (B-frames) se reconstruyen: MKV guarda solo la presentación.
/// No sirve para DTS, TrueHD, FLAC ni Opus (AVPlayer no los decodifica) ni para vídeo AV1/MPEG-4 ASP/VC-1.
public final class MkvToHls: RelayHandler {
    public let info: MkvInfo
    private let src: MkvSource
    private let video: MkvTrack
    private let audios: [MkvTrack]
    private let log: (String) -> Void

    /// Segmentos: posición absoluta de inicio y segundo de inicio de cada uno (el último termina en el fin del fichero).
    private struct Seg { var pos: Int64; var time: Double }
    private var segs: [Seg] = []
    private var segEndPos: Int64 = 0

    private struct Loaded { var blocks: [MkvBlock] }
    private let lock = NSLock()
    private var loading: [Int: Task<Loaded, Error>] = [:]
    private var initCache: [Int: [UInt8]] = [:]
    /// Retardo (ms) que el usuario pide para el audio: positivo = suena más tarde, negativo = antes.
    public var audioDelayMs = 0
    private var audioHeads: [Int: [UInt8]] = [:]          // primera trama de cada audio (para dac3 / dec3)

    /// Retraso (s) de toda la presentación para que los desfases de composición del vídeo con fotogramas B sean positivos.
    static let shift = 0.5

    /// Códecs que AVPlayer reproduce dentro de HLS fMP4.
    static func videoSupported(_ c: String) -> Bool { c == "V_MPEG4/ISO/AVC" || c == "V_MPEGH/ISO/HEVC" }
    static func audioSupported(_ c: String) -> Bool { c == "A_AAC" || c == "A_AC3" || c == "A_EAC3" }

    /// Abre el fichero y comprueba que se puede reproducir. Lanza el motivo si no.
    public static func open(source: MkvSource, log: @escaping (String) -> Void = { _ in }) async throws -> MkvToHls {
        let info = try await Matroska.open(source)
        guard let v = info.tracks.first(where: { $0.type == 1 }) else { throw MkvError.noVideo }
        guard videoSupported(v.codecId) else { throw MkvError.unsupported("vídeo \(v.codecId) que el iPad no decodifica") }
        guard !v.codecPrivate.isEmpty else { throw MkvError.unsupported("el MKV no trae la configuración del vídeo") }
        let all = info.tracks.filter { $0.type == 2 }
        let ok = all.filter { audioSupported($0.codecId) }
        if ok.isEmpty && !all.isEmpty { throw MkvError.unsupported("audio \(all.map { $0.codecId }.joined(separator: ", ")) que el iPad no decodifica") }
        let m = MkvToHls(info: info, src: source, video: v, audios: ok, log: log)
        try m.planSegments()
        // Primera trama de cada audio: hace falta para describir AC-3 y E-AC-3
        let first = try await m.segmentBlocks(0, prefetch: false)
        for a in ok { if let f = first.blocks.first(where: { $0.track == a.number })?.frames.first { m.audioHeads[a.number] = f } }
        log("MKV listo: \(v.codecId) \(v.width)x\(v.height) · audios \(ok.map { $0.codecId }) · \(m.segs.count) segmentos · \(Int(info.durationSec / 60)) min")
        return m
    }

    private init(info: MkvInfo, src: MkvSource, video: MkvTrack, audios: [MkvTrack], log: @escaping (String) -> Void) {
        self.info = info; self.src = src; self.video = video; self.audios = audios; self.log = log
    }

    // MARK: - Segmentos

    /// Los clusters se agrupan en segmentos de unos 6 s (o más si el fichero tiene pocos puntos de índice).
    private func planSegments() throws {
        let cues = info.cues
        guard !cues.isEmpty else { throw MkvError.truncated("sin índice de clusters") }
        var out: [Seg] = []
        for c in cues {
            let t = info.seconds(c.ticks)
            if let last = out.last, t - last.time < 6.0 { continue }
            out.append(Seg(pos: info.segmentStart + c.clusterPos, time: t))
        }
        segs = out
        segEndPos = info.segmentEnd == Int64.max ? (segs.last!.pos + 64 * 1024 * 1024) : info.segmentEnd
    }

    private func segDuration(_ i: Int) -> Double {
        let end = i + 1 < segs.count ? segs[i + 1].time : max(info.durationSec, segs[i].time + 1)
        return max(end - segs[i].time, 0.1)
    }

    /// Bloques del segmento `i` (se descargan una vez aunque pidan a la vez vídeo y audio) y se adelanta el siguiente.
    private func segmentBlocks(_ i: Int, prefetch: Bool = true) async throws -> Loaded {
        let task: Task<Loaded, Error> = {
            lock.lock(); defer { lock.unlock() }
            if let t = loading[i] { return t }
            let t = Task<Loaded, Error> { [self] in
                let from = segs[i].pos
                let to = i + 1 < segs.count ? segs[i + 1].pos : segEndPos
                let data = try await src.read(offset: from, length: Int(min(to - from, Int64(Int32.max))))
                return Loaded(blocks: Matroska.blocks(data, tracks: info.tracks))
            }
            loading[i] = t
            // Se conservan pocos segmentos en memoria
            for k in loading.keys where k < i - 2 || k > i + 3 { loading[k] = nil }
            return t
        }()
        let r = try await task.value
        // Se adelanta el siguiente (una sola vez: la petición adelantada no encadena más)
        if prefetch, i + 1 < segs.count { Task { [self] in _ = try? await segmentBlocks(i + 1, prefetch: false) } }
        return r
    }

    // MARK: - Respuestas

    public func handle(path: String) async -> RelayResponse {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        do {
            if p == "/master.m3u8" { return text(master(), "application/vnd.apple.mpegurl") }
            if p.hasPrefix("/t"), p.hasSuffix(".m3u8"), let n = Int(p.dropFirst(2).dropLast(5)) { return text(mediaPlaylist(track: n), "application/vnd.apple.mpegurl") }
            if p.hasPrefix("/init-"), p.hasSuffix(".mp4"), let n = Int(p.dropFirst(6).dropLast(4)) { return bin(try initSegment(track: n), "video/mp4") }
            if p.hasPrefix("/seg-"), p.hasSuffix(".m4s") {
                let parts = p.dropFirst(5).dropLast(4).split(separator: "-")
                if parts.count == 2, let n = Int(parts[0]), let i = Int(parts[1]), i >= 0, i < segs.count {
                    return bin(try await segment(track: n, index: i), "video/mp4")
                }
            }
            return RelayResponse(status: 404, contentType: "text/plain", body: Data("no existe".utf8))
        } catch {
            log("error en \(p): \(error.localizedDescription)")
            return RelayResponse(status: 500, contentType: "text/plain", body: Data(error.localizedDescription.utf8))
        }
    }

    private func text(_ s: String, _ type: String) -> RelayResponse { RelayResponse(status: 200, contentType: type, body: Data(s.utf8)) }
    private func bin(_ b: [UInt8], _ type: String) -> RelayResponse { RelayResponse(status: 200, contentType: type, body: Data(b)) }

    // MARK: - Listas

    private func audioCodecString(_ t: MkvTrack) -> String {
        switch t.codecId {
        case "A_AAC": return CodecStrings.aac(t.codecPrivate).codec
        case "A_AC3": return "ac-3"
        default: return "ec-3"
        }
    }

    private static let langCodes = ["spa": "es", "eng": "en", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it", "por": "pt", "cat": "ca",
                                    "jpn": "ja", "chi": "zh", "zho": "zh", "rus": "ru", "kor": "ko", "ara": "ar", "dut": "nl", "nld": "nl"]

    /// Idioma de 2 letras («spa» → «es»); vacío si no se conoce.
    public static func iso1(_ l: String) -> String { langCodes[l.lowercased()] ?? (l.count == 2 ? l.lowercased() : "") }

    private func master() -> String {
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        let vcodec = video.codecId == "V_MPEGH/ISO/HEVC" ? CodecStrings.hevc(video.codecPrivate) : CodecStrings.avc(video.codecPrivate)
        var acodecs: [String] = []
        let defaultIdx = audios.firstIndex { $0.isDefault } ?? 0
        for (k, a) in audios.enumerated() {
            let c = audioCodecString(a); if !acodecs.contains(c) { acodecs.append(c) }
            let lang = Self.langCodes[a.language.lowercased()] ?? (a.language.count == 2 ? a.language : "")
            var name = a.name.isEmpty ? (lang.isEmpty ? "Audio \(k + 1)" : (Locale(identifier: "es").localizedString(forLanguageCode: lang)?.capitalized ?? lang)) : a.name
            if a.channels > 0, !name.contains("\(a.channels)") { name += a.channels > 2 ? " \(a.channels - 1).1" : (a.channels == 1 ? " mono" : "") }
            if a.name.isEmpty { name += a.codecId == "A_EAC3" ? " · E-AC-3" : (a.codecId == "A_AC3" ? " · AC-3" : " · AAC") }
            s += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(name.replacingOccurrences(of: "\"", with: "'"))\"" + (lang.isEmpty ? "" : ",LANGUAGE=\"\(lang)\"")
                + ",DEFAULT=\(k == defaultIdx ? "YES" : "NO"),AUTOSELECT=YES" + (a.channels > 0 ? ",CHANNELS=\"\(a.channels)\"" : "") + ",URI=\"t\(a.number).m3u8\"\n"
        }
        let size = info.segmentEnd == Int64.max ? 0 : info.segmentEnd - info.segmentStart
        let bw = info.durationSec > 0 && size > 0 ? Int(Double(size) * 8 / info.durationSec) : 8_000_000
        var attrs = "BANDWIDTH=\(max(bw, 500_000)),CODECS=\"\(([vcodec] + acodecs).joined(separator: ","))\",RESOLUTION=\(video.width)x\(video.height)"
        if video.defaultDurationNs > 0 { attrs += ",FRAME-RATE=" + String(format: "%.3f", 1e9 / Double(video.defaultDurationNs)) }
        if video.colorTransfer == 16 { attrs += ",VIDEO-RANGE=PQ" } else if video.colorTransfer == 18 { attrs += ",VIDEO-RANGE=HLG" }
        if !audios.isEmpty { attrs += ",AUDIO=\"aud\"" }
        s += "#EXT-X-STREAM-INF:\(attrs)\nt\(video.number).m3u8\n"
        return s
    }

    private func mediaPlaylist(track: Int) -> String {
        var maxDur = 1.0
        var body = ""
        for i in 0..<segs.count { let d = segDuration(i); maxDur = max(maxDur, d); body += String(format: "#EXTINF:%.5f,\n", d) + "seg-\(track)-\(i).m4s\n" }
        return "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(maxDur.rounded(.up)))\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n"
            + "#EXT-X-MAP:URI=\"init-\(track).mp4\"\n" + body + "#EXT-X-ENDLIST\n"
    }

    // MARK: - Inicio de cada pista

    private func audioFrameSamples(_ t: MkvTrack) -> Int {
        switch t.codecId {
        case "A_AAC": return 1024
        case "A_AC3": return 1536
        default: return audioHeads[t.number].flatMap { CodecStrings.dec3(frame: $0)?.blocks }.map { $0 * 256 } ?? 1536
        }
    }
    private func audioRate(_ t: MkvTrack) -> Int {
        switch t.codecId {
        case "A_AAC": return CodecStrings.aac(t.codecPrivate).rate
        case "A_EAC3": return audioHeads[t.number].flatMap { CodecStrings.dec3(frame: $0)?.rate } ?? Int(t.sampleRate)
        default: return t.sampleRate > 0 ? Int(t.sampleRate) : 48000
        }
    }

    private func initSegment(track n: Int) throws -> [UInt8] {
        lock.lock(); if let c = initCache[n] { lock.unlock(); return c }; lock.unlock()
        let out: [UInt8]
        if n == video.number {
            let hevc = video.codecId == "V_MPEGH/ISO/HEVC"
            let colr: (p: Int, t: Int, m: Int, full: Bool)? = video.colorTransfer > 0 || video.colorPrimaries > 0
                ? (video.colorPrimaries == 0 ? 2 : video.colorPrimaries, video.colorTransfer == 0 ? 2 : video.colorTransfer, video.colorMatrix == 0 ? 2 : video.colorMatrix, video.colorRange == 2) : nil
            out = Mp4.initSegment(trackId: n, kind: .video(width: video.width, height: video.height), timescale: 90000, language: video.language,
                                  sampleEntry: Mp4.videoEntry(hevc: hevc, width: video.width, height: video.height, config: video.codecPrivate, colr: colr))
        } else if let a = audios.first(where: { $0.number == n }) {
            let rate = audioRate(a)
            let entry: [UInt8]
            switch a.codecId {
            case "A_AAC": entry = Mp4.audioEntry(type: "mp4a", channels: a.channels, sampleRate: rate, config: Mp4.esds(asc: a.codecPrivate))
            case "A_AC3":
                guard let h = audioHeads[n], let d = CodecStrings.dac3(frame: h) else { throw MkvError.unsupported("audio AC-3 ilegible") }
                entry = Mp4.audioEntry(type: "ac-3", channels: a.channels, sampleRate: rate, config: Mp4.box("dac3", d))
            default:
                guard let h = audioHeads[n], let d = CodecStrings.dec3(frame: h) else { throw MkvError.unsupported("audio E-AC-3 ilegible") }
                entry = Mp4.audioEntry(type: "ec-3", channels: a.channels, sampleRate: rate, config: Mp4.box("dec3", d.box))
            }
            out = Mp4.initSegment(trackId: n, kind: .audio, timescale: UInt32(rate), language: a.language, sampleEntry: entry)
        } else { throw MkvError.unsupported("pista \(n) desconocida") }
        lock.lock(); initCache[n] = out; lock.unlock()
        return out
    }

    // MARK: - Segmentos fMP4

    /// Segmento `index` de la pista `n`: moof + mdat.
    func segment(track n: Int, index: Int) async throws -> [UInt8] {
        let blocks = try await segmentBlocks(index).blocks.filter { $0.track == n }
        if n == video.number { return videoFragment(blocks, index: index) }
        guard let a = audios.first(where: { $0.number == n }) else { throw MkvError.unsupported("pista \(n) desconocida") }
        return audioFragment(a, blocks, index: index)
    }

    private func secs(_ ticks: Int64) -> Double { info.seconds(ticks) }

    private func videoFragment(_ blocks: [MkvBlock], index: Int) -> [UInt8] {
        // Desde el primer fotograma clave (lo anterior no se puede decodificar solo)
        var frames: [(pts: Double, key: Bool, data: [UInt8])] = []
        for b in blocks { for f in b.frames { frames.append((secs(b.ticks), b.keyframe, f)) } }
        if let k = frames.firstIndex(where: { $0.key }), k > 0 { frames.removeFirst(k) }
        guard !frames.isEmpty else { return Mp4.fragment(sequence: index + 1, trackId: video.number, baseTime: 0, samples: [], video: true) }
        let scale = 90000.0
        // Orden de decodificación = orden del fichero. DTS = tiempos de presentación ordenados (así quedan crecientes).
        // MKV solo guarda el instante de presentación, así que el desfase de composición saldría negativo en los fotogramas B.
        // Para que nunca lo sea, toda la presentación (vídeo y audio) se retrasa `Self.shift` segundos: cts = pts + shift − dts ≥ 0.
        let sorted = frames.map { $0.pts }.sorted()
        let dts = sorted.map { Int64(($0 * scale).rounded()) }
        var defaultDur = video.defaultDurationNs > 0 ? Int64(Double(video.defaultDurationNs) / 1e9 * scale) : 0
        if defaultDur == 0, sorted.count > 1 { defaultDur = max(dts[1] - dts[0], 1) }
        if defaultDur == 0 { defaultDur = 3750 }
        var samples: [Mp4Sample] = []
        for (i, f) in frames.enumerated() {
            let dur = i + 1 < dts.count ? max(dts[i + 1] - dts[i], 1) : defaultDur
            let cts = max(Int64(((f.pts + Self.shift) * scale).rounded()) - dts[i], 0)
            samples.append(Mp4Sample(data: f.data, duration: UInt32(min(dur, Int64(UInt32.max))), sync: f.key, compositionOffset: Int32(clamping: cts)))
        }
        return Mp4.fragment(sequence: index + 1, trackId: video.number, baseTime: UInt64(max(dts[0], 0)), samples: samples, video: true)
    }

    private func audioFragment(_ a: MkvTrack, _ blocks: [MkvBlock], index: Int) -> [UInt8] {
        let rate = Double(audioRate(a))
        let per = UInt32(audioFrameSamples(a))
        var samples: [Mp4Sample] = []
        var first: Double?
        for b in blocks {
            if first == nil { first = secs(b.ticks) }
            for f in b.frames { samples.append(Mp4Sample(data: f, duration: per, sync: true)) }
        }
        let base = UInt64(max(((first ?? segs[index].time) + Self.shift + Double(audioDelayMs) / 1000) * rate, 0).rounded())
        return Mp4.fragment(sequence: index + 1, trackId: a.number, baseTime: base, samples: samples, video: false)
    }

    // MARK: - Informe de pistas

    /// Una pista del fichero y si se puede pasar tal cual (verde) o habría que recodificarla (rojo).
    public struct TrackReport { public let kind: String, label: String, codec: String, lang: String; public let direct: Bool }

    /// Pistas de vídeo y audio con su compatibilidad directa. Subtítulos no se cuentan (no se pasan).
    public static func report(of info: MkvInfo) -> [TrackReport] {
        info.tracks.compactMap { t in
            switch t.type {
            case 1: return TrackReport(kind: "Vídeo", label: "\(t.width)x\(t.height)", codec: t.codecId.replacingOccurrences(of: "V_MPEGH/ISO/", with: "").replacingOccurrences(of: "V_MPEG4/ISO/", with: ""), lang: "", direct: videoSupported(t.codecId) && !t.codecPrivate.isEmpty)
            case 2:
                let lang = iso1(t.language), n = t.name.isEmpty ? (lang.isEmpty ? t.language : lang) : t.name
                return TrackReport(kind: "Audio", label: "\(n)" + (t.channels > 0 ? " \(t.channels)ch" : ""), codec: t.codecId.replacingOccurrences(of: "A_", with: ""), lang: lang, direct: audioSupported(t.codecId))
            default: return nil
            }
        }
    }

    /// Lee solo la cabecera del fichero y devuelve el informe de pistas (nil si no es MKV).
    public static func survey(source: MkvSource) async -> [TrackReport]? {
        guard let info = try? await Matroska.open(source) else { return nil }
        return report(of: info)
    }

    // MARK: - Para descargar

    /// Número de pista del vídeo y de cada audio compatible con su nombre, para elegir qué descargar.
    /// Tamaño aproximado del fichero (para calcular la velocidad de descarga).
    public var totalBytes: Int64 { info.segmentEnd == Int64.max ? 0 : info.segmentEnd - info.segmentStart }
    public var videoTrackNumber: Int { video.number }
    public var audioTracks: [(number: Int, language: String, name: String, isDefault: Bool)] { audios.map { ($0.number, Self.iso1($0.language), $0.name, $0.isDefault) } }

    /// Escribe varias pistas a la vez (inicio + todos los segmentos de cada una) como MP4 fragmentados, bajando el fichero UNA sola vez.
    /// `progress` entre 0 y 1.
    public func export(tracks: [(number: Int, url: URL)], progress: @escaping (Double) -> Void) async throws {
        var handles: [Int: FileHandle] = [:]
        defer { for h in handles.values { try? h.close() } }
        for t in tracks {
            FileManager.default.createFile(atPath: t.url.path, contents: nil)
            let h = try FileHandle(forWritingTo: t.url)
            handles[t.number] = h
            try h.write(contentsOf: Data(try initSegment(track: t.number)))
        }
        for i in 0..<segs.count {
            try Task.checkCancellation()
            for t in tracks { try handles[t.number]!.write(contentsOf: Data(try await segment(track: t.number, index: i))) }
            progress(Double(i + 1) / Double(segs.count))
        }
    }
}
