import Foundation
import AVFoundation
import AVKit
import SwiftUI
import HLSCore

/// Lo que se elige al descargar (como la ventana de Android): calidad, idiomas de audio y de subtítulos.
struct DownloadOptions: Codable, Equatable {
    var height = 0                                  // 0 = la mejor
    var audioLangs: [String] = AppSettings.dlAudioLangs   // por defecto: idioma del dispositivo e inglés
    var subLangs: [String] = AppSettings.dlSubLangs       // por defecto: inglés

    static var defaults: DownloadOptions { DownloadOptions(height: UserDefaults.standard.integer(forKey: "set.dlQuality")) }
}

/// Un subtítulo ya bajado junto a la película.
struct SubFile: Codable, Equatable, Hashable { var lang: String; var name: String; var file: String }

/// Una pista de audio o de subtítulos que ofrece el manifiesto.
struct MediaTrack: Identifiable, Hashable {
    let lang: String
    let name: String
    let url: URL
    var id: String { url.absoluteString }
    /// Código de idioma sin región: «es-419» → «es».
    var base: String { String(lang.lowercased().split(separator: "-").first ?? "") }
}

/// Lo que se puede elegir de una película: alturas, audios y subtítulos disponibles.
struct DownloadProbe {
    var heights: [Int] = []
    var audios: [MediaTrack] = []
    var subs: [MediaTrack] = []
    var mkv: [MkvToHls.TrackReport] = []     // si es un MKV: sus pistas y si pasan directas
}

/// Una descarga de la mediateca (equivale a Downloads.kt de Android): se guarda como MP4 en Documents/Descargas.
struct DownloadJob: Identifiable, Codable, Equatable {
    var id: String                 // id del canal descargado
    var title: String
    var url: String
    var keys: [String: String]
    var headers: [String: String]
    var poster: String?
    var fileName: String?          // cuando termina
    var state: String = "esperando"   // esperando · descargando · uniendo · listo · error
    var progress: Double = 0
    var error: String?
    var options = DownloadOptions.defaults
    var subs: [SubFile] = []
    var bytes: Int64 = 0           // bajado hasta ahora
    var speed: Double = 0          // bytes por segundo
    var eta: Double = 0            // segundos que faltan
    var group: String = ""         // servidor: de servidores distintos se baja a la vez

    init(id: String, title: String, url: String, keys: [String: String], headers: [String: String], poster: String?, options: DownloadOptions) {
        self.id = id; self.title = title; self.url = url; self.keys = keys; self.headers = headers; self.poster = poster; self.options = options
        self.group = URL(string: url)?.host ?? ""
    }

    // Las descargas guardadas por versiones anteriores no tienen los campos nuevos
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title); url = try c.decode(String.self, forKey: .url)
        keys = try c.decodeIfPresent([String: String].self, forKey: .keys) ?? [:]; headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        poster = try c.decodeIfPresent(String.self, forKey: .poster); fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "esperando"; progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        options = try c.decodeIfPresent(DownloadOptions.self, forKey: .options) ?? DownloadOptions.defaults
        subs = try c.decodeIfPresent([SubFile].self, forKey: .subs) ?? []
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0; speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        eta = try c.decodeIfPresent(Double.self, forKey: .eta) ?? 0
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? (URL(string: url)?.host ?? "")
    }
}

/// Cola de descargas. Para DASH/HLS cifrados pasa por el relay local (que descifra), baja el vídeo y los audios
/// por separado y los une en un MP4 con AVFoundation; los subtítulos quedan al lado en ficheros .vtt.
/// Se pueden bajar varias a la vez si son de servidores distintos (Ajustes → Descargas).
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    @Published private(set) var jobs: [DownloadJob] = []
    private let key = "downloads.v1"
    /// Reproductores abiertos (referencias débiles). Las descargas esperan solo mientras alguno esté reproduciendo DE VERDAD:
    /// compiten por red y procesador y el directo daba saltos. Antes era un interruptor que ponían las pantallas al abrirse y
    /// cerrarse; si una no avisaba al cerrarse, todas las descargas quedaban paradas en el primer trozo (≈4 %).
    private let players = NSHashTable<AVPlayer>.weakObjects()
    func register(_ p: AVPlayer) { players.add(p) }
    var playbackActive: Bool {
        guard AppSettings.dlPauseWhilePlaying else { return false }
        return players.allObjects.contains { $0.timeControlStatus == .playing && $0.rate > 0 }
    }
    private var tasks: [String: Task<String, Error>] = [:]
    private var activeGroups = Set<String>()
    private var meters: [String: Meter] = [:]

    /// Medidor de velocidad de una descarga: tiempo realmente bajando (sin las pausas) y media móvil.
    private struct Meter { var active: TimeInterval = 0; var speed: Double = 0 }

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([DownloadJob].self, from: d) {
            jobs = l.map { var j = $0; if j.state != "listo" && j.state != "error" { j.state = "esperando"; j.speed = 0 }; return j }
        }
    }
    private func save() { if let d = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(d, forKey: key) } }
    /// Carpeta donde se guardan las descargas: la elegida en Ajustes (marcador de seguridad) o, si no, Documentos/Descargas de la app
    /// (visible en la app Archivos).
    static var folder: URL { DownloadFolder.current }
    func fileURL(_ j: DownloadJob) -> URL? { j.fileName.map { Self.folder.appendingPathComponent($0) } }
    func isQueued(_ id: String) -> Bool { jobs.contains { $0.id == id } }

    func enqueue(channel ch: IptvChannel, options: DownloadOptions = .defaults) {
        guard !isQueued(ch.id) else { return }
        var h = ch.httpHeaders
        if let ua = ch.userAgent { h["User-Agent"] = ua }
        if let r = ch.referrer { h["Referer"] = r }
        jobs.append(DownloadJob(id: ch.id, title: ch.name, url: ch.url, keys: ch.clearKeys, headers: h, poster: ch.m3uLogo, options: options))
        save(); pump()
    }
    func enqueue(_ channels: [IptvChannel], options: DownloadOptions) { for c in channels { enqueue(channel: c, options: options) } }

    /// Cancela (si está en marcha) y borra la descarga con su fichero, también el parcial y los subtítulos.
    func remove(_ j: DownloadJob) {
        tasks[j.id]?.cancel()
        jobs.removeAll { $0.id == j.id }; save()
        let base = safeName(j.title)
        if let f = fileURL(j) { try? FileManager.default.removeItem(at: f) }
        // Restos con el nombre del título (mp4, ts, mkv…) y sus subtítulos «título.idioma.vtt»
        if let list = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) {
            for f in list where f.deletingPathExtension().lastPathComponent == base || f.lastPathComponent.hasPrefix(base + ".") { try? FileManager.default.removeItem(at: f) }
        }
        Trace.shared.log("descarga", "borrada «\(j.title)»")
    }
    func removeAll() { for j in jobs { remove(j) } }
    func retry(_ j: DownloadJob) { update(j.id) { $0.state = "esperando"; $0.error = nil; $0.progress = 0 }; pump() }
    /// Retoma al abrir la app las que quedaron a medias.
    func resume() { pump() }

    private func update(_ id: String, save s: Bool = true, _ f: (inout DownloadJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { f(&jobs[i]); if s { save() } }
    }

    /// Arranca las que caben: hasta N a la vez y de un servidor distinto cada una.
    private func pump() {
        while tasks.count < AppSettings.dlParallel,
              let job = jobs.first(where: { $0.state == "esperando" && !activeGroups.contains($0.group) && tasks[$0.id] == nil }) {
            begin(job)
        }
    }

    private func begin(_ job: DownloadJob) {
        update(job.id) { $0.state = "descargando"; $0.speed = 0; $0.eta = 0; $0.bytes = 0 }
        Trace.shared.log("descarga", "empieza «\(job.title)» (\(job.group))")
        meters[job.id] = Meter()
        activeGroups.insert(job.group)
        let task = Task { try await self.download(job) }
        tasks[job.id] = task
        BackgroundKeeper.shared.acquire()                 // sigue aunque se bloquee o apague la pantalla
        Task {
            defer { BackgroundKeeper.shared.release() }
            do {
                let name = try await task.value
                update(job.id) { $0.state = "listo"; $0.progress = 1; $0.fileName = name; $0.speed = 0; $0.eta = 0 }
                Trace.shared.log("descarga", "«\(job.title)» lista: \(name)")
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if cancelled || !jobs.contains(where: { $0.id == job.id }) { Trace.shared.log("descarga", "cancelada «\(job.title)»") }
                else {
                    update(job.id) { $0.state = "error"; $0.error = error.localizedDescription; $0.speed = 0 }
                    Trace.shared.log("descarga", "ERROR «\(job.title)»: \(error.localizedDescription)")
                }
            }
            tasks[job.id] = nil; meters[job.id] = nil
            activeGroups.remove(job.group)
            pump()
        }
    }

    private func safeName(_ s: String) -> String { s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_") }

    // MARK: - Qué ofrece un título (para la ventana de opciones)

    /// Mira el manifiesto y devuelve alturas, audios y subtítulos disponibles. `nil` si es un fichero directo.
    func inspect(channel ch: IptvChannel) async -> DownloadProbe? {
        guard let url = URL(string: ch.url) else { return nil }
        var h = ch.httpHeaders
        if let ua = ch.userAgent { h["User-Agent"] = ua }
        if let r = ch.referrer { h["Referer"] = r }
        let head = (try? await URLSessionFetcher().fetch(url, headers: h.merging(["Range": "bytes=0-65535"]) { a, _ in a })) ?? Data()
        // MKV: se mira qué pistas pasan directas al reempaquetar en local y cuáles habría que recodificar
        if StreamSniffer.isMatroska(head), AppSettings.mkvMode == "local",
           let r = await MkvToHls.survey(source: HttpRangeSource(fetcher: URLSessionFetcher(attempts: 3), url: url, headers: h)) {
            var p = DownloadProbe(); p.mkv = r
            p.audios = r.enumerated().filter { $0.element.kind == "Audio" && $0.element.direct }
                .map { MediaTrack(lang: $0.element.lang, name: $0.element.label, url: URL(string: "mkv://pista/\($0.offset)")!) }
            return p
        }
        guard StreamSniffer.kind(ofManifest: String(decoding: head, as: UTF8.self)) != .other else { return nil }
        let plan = await RelayManager.shared.plan(url: url, headers: h, clearKeys: ch.clearKeys, fixedHeight: 0, minHeight: 0, labels: false)
        defer { RelayManager.shared.end(plan) }
        guard let data = try? await URLSessionFetcher().fetch(plan.url, headers: plan.viaRelay ? [:] : h) else { return nil }
        return Self.parseMaster(String(decoding: data, as: UTF8.self), base: plan.url)
    }

    /// Saca de una lista maestra las alturas, los audios y los subtítulos (sin los forzados ni la audiodescripción).
    nonisolated static func parseMaster(_ text: String, base: URL) -> DownloadProbe {
        var p = DownloadProbe()
        var heights = Set<Int>()
        let ui = AppSettings.deviceLang
        let shown = AudioLabels.displayNames(text, ui: ui)
        func attr(_ line: String, _ name: String) -> String? {
            guard let r = line.range(of: "\(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
            return String(line[r].dropFirst(name.count + 2).dropLast())
        }
        for l in text.components(separatedBy: .newlines) {
            if l.hasPrefix("#EXT-X-STREAM-INF") {
                if let r = l.range(of: "RESOLUTION=\\d+x\\d+", options: .regularExpression), let hh = Int(l[r].split(separator: "x").last ?? "") { heights.insert(hh) }
            } else if l.hasPrefix("#EXT-X-MEDIA"), let u = uriAttribute(l, base: base) {
                let lang = attr(l, "LANGUAGE") ?? "", name = attr(l, "NAME") ?? lang
                let low = l.lowercased()
                if l.contains("TYPE=AUDIO") {
                    if low.contains("describes-video") || name.lowercased().contains("audio description") || name.lowercased().contains("audiodescrip") { continue }
                    p.audios.append(MediaTrack(lang: lang, name: shown[(attr(l, "GROUP-ID") ?? "") + "|" + name] ?? name, url: u))
                } else if l.contains("TYPE=SUBTITLES") {
                    if l.contains("FORCED=YES") { continue }
                    p.subs.append(MediaTrack(lang: lang, name: LanguageNames.readable(name: name, lang: lang, ui: ui), url: u))
                }
            }
        }
        p.heights = heights.sorted(by: >)
        return p
    }

    /// De las pistas disponibles, la primera de cada idioma pedido (por código base: «es» vale para «es-ES» y «es-419»).
    nonisolated static func choose(_ tracks: [MediaTrack], langs: [String]) -> [MediaTrack] {
        var out: [MediaTrack] = []
        // «*» = todos: una pista de cada idioma (como «Todos» en Android)
        if langs.contains("*") {
            var seen = Set<String>()
            for t in tracks where seen.insert(t.base).inserted { out.append(t) }
            return out
        }
        for l in langs {
            let want = l.lowercased()
            if let t = tracks.first(where: { $0.base == want }), !out.contains(t) { out.append(t) }
        }
        return out
    }

    // MARK: - Descarga

    private func download(_ job: DownloadJob) async throws -> String {
        guard let url = URL(string: job.url) else { throw URLError(.badURL) }
        let base = safeName(job.title)
        let head = (try? await URLSessionFetcher().fetch(url, headers: job.headers.merging(["Range": "bytes=0-65535"]) { a, _ in a })) ?? Data()
        let kind = StreamSniffer.kind(ofManifest: String(decoding: head, as: UTF8.self))
        // MKV: se reempaqueta en el dispositivo (sin recodificar) a un MP4 que AVPlayer abre; si no se puede, se baja el original tal cual
        if StreamSniffer.isMatroska(head), AppSettings.mkvMode == "local" {
            if let name = try await downloadMkv(job, url: url, base: base) { return name }
        }
        // Archivo directo: se baja tal cual
        if kind == .other { return try await downloadDirect(job, url: url, base: base) }

        // Flujo DASH/HLS: por el relay, que descifra y reescribe
        let plan = await RelayManager.shared.plan(url: url, headers: job.headers, clearKeys: job.keys, fixedHeight: job.options.height, minHeight: 0, labels: false)
        defer { RelayManager.shared.end(plan) }
        let fetch = URLSessionFetcher()
        let hdr: [String: String] = plan.viaRelay ? [:] : job.headers
        let masterText = String(decoding: try await fetch.fetch(plan.url, headers: hdr), as: UTF8.self)
        let probe = Self.parseMaster(masterText, base: plan.url)
        guard let vpl = Self.pickVideo(masterText, base: plan.url) else { throw NSError(domain: "descarga", code: 1, userInfo: [NSLocalizedDescriptionKey: "no se encontró el vídeo en el manifiesto"]) }
        // Audios pedidos; si no hay ninguno en esos idiomas, el primero (mejor algo que ninguno)
        var audios = Self.choose(probe.audios, langs: job.options.audioLangs)
        if audios.isEmpty, let f = probe.audios.first { audios = [f] }
        let subs = Self.choose(probe.subs, langs: job.options.subLangs)
        Trace.shared.log("descarga", "«\(job.title)»: audios \(audios.map { $0.name }) · subtítulos \(subs.map { $0.name }) · calidad \(job.options.height > 0 ? "≤\(job.options.height)p" : "máxima")")

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let nAudio = Double(max(audios.count, 1))
        let vSpan = audios.isEmpty ? 0.9 : 0.55
        let aSpan = audios.isEmpty ? 0 : 0.35 / nAudio
        var vFile = tmpDir.appendingPathComponent("v.tmp")
        try await fetchTrack(vpl, to: vFile, jobId: job.id, headers: hdr, from: 0, span: vSpan)
        vFile = try Self.renamedByContent(vFile)
        var audioFiles: [(URL, String)] = []
        for (i, a) in audios.enumerated() {
            var f = tmpDir.appendingPathComponent("a\(i).tmp")
            try await fetchTrack(a.url, to: f, jobId: job.id, headers: hdr, from: vSpan + aSpan * Double(i), span: aSpan)
            f = try Self.renamedByContent(f)
            audioFiles.append((f, a.lang))
        }
        // Subtítulos (si falla uno no se pierde la película)
        var saved: [SubFile] = []
        for s in subs {
            try Task.checkCancellation()
            if let vtt = try? await fetchSubtitle(s.url, headers: hdr) {
                let name = "\(base).\(s.base).vtt"
                try? vtt.write(to: Self.folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                saved.append(SubFile(lang: s.base, name: s.name, file: name))
            } else { Trace.shared.log("descarga", "subtítulo «\(s.name)» no se pudo bajar") }
        }
        Trace.shared.log("descarga", "vídeo \(vFile.pathExtension) \((try? vFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) B · audios \(audioFiles.count) · subtítulos \(saved.count)")
        update(job.id) { $0.state = "uniendo"; $0.progress = 0.92; $0.speed = 0; $0.eta = 0; $0.subs = saved }
        let dest = Self.folder.appendingPathComponent("\(base).mp4")
        try await Self.mux(video: vFile, audios: audioFiles, to: dest)
        return dest.lastPathComponent
    }

    /// MKV con vídeo H.264/HEVC y audio AAC/AC-3/E-AC-3: se baja el vídeo y los audios elegidos reempaquetados en MP4 fragmentado
    /// y se unen en un MP4 (como las descargas HLS). Devuelve nil si el MKV no se puede reempaquetar (el llamador baja el original).
    private func downloadMkv(_ job: DownloadJob, url: URL, base: String) async throws -> String? {
        let mkv: MkvToHls
        do { mkv = try await MkvToHls.open(source: HttpRangeSource(fetcher: URLSessionFetcher(attempts: 4), url: url, headers: job.headers), log: { Trace.shared.log("mkv", $0) }) }
        catch { Trace.shared.log("descarga", "«\(job.title)»: MKV no reempaquetable (\(error.localizedDescription)); se baja el original"); return nil }
        // Audios pedidos (por idioma); si no hay ninguno, el marcado por defecto o el primero
        var chosen = mkv.audioTracks.filter { a in job.options.audioLangs.contains { $0 == a.language } }
        if chosen.isEmpty, let f = mkv.audioTracks.first(where: { $0.isDefault }) ?? mkv.audioTracks.first { chosen = [f] }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let tracks = [mkv.videoTrackNumber] + chosen.map { $0.number }
        Trace.shared.log("descarga", "«\(job.title)»: MKV → MP4 en el dispositivo · pistas \(tracks) (audios \(chosen.map { $0.language }))")
        let started = Date()
        let total = mkv.totalBytes
        let meter = MkvMeter()
        let dest = Self.folder.appendingPathComponent("\(base).mp4")
        // Una sola pasada por el fichero: se escribe directamente UN mp4 con vídeo y audios y listas de ediciones propias.
        // (Antes se unían pistas sueltas con AVFoundation y el audio podía quedar desplazado.)
        try? FileManager.default.removeItem(at: dest)
        try await mkv.exportMp4(tracks: tracks, to: dest) { p in
            let bytes = Int64(Double(total) * p)
            let sp = meter.speed(bytes: bytes)                     // bytes/s del fichero original, suavizada
            Task { @MainActor in
                let el = max(Date().timeIntervalSince(started), 0.5)
                self.update(job.id, save: false) { $0.progress = 0.99 * p; $0.bytes = bytes; $0.speed = sp; $0.eta = p > 0.01 ? el * (1 - p) / p : 0 }
            }
        }
        return dest.lastPathComponent
    }

    /// Fichero suelto (mp4, mkv…): se baja tal cual y se enseña el progreso y la velocidad.
    private func downloadDirect(_ job: DownloadJob, url: URL, base: String) async throws -> String {
        let known = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm"]
        var ext = known.contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : ""
        var req = URLRequest(url: url, timeoutInterval: 3600)
        for (k, v) in job.headers { req.setValue(v, forHTTPHeaderField: k) }
        let started = Date()
        let tmp = try await Self.downloadFile(req) { done, total in
            Task { @MainActor in
                let el = max(Date().timeIntervalSince(started), 0.5)
                let sp = Double(done) / el
                let p = total > 0 ? Double(done) / Double(total) : 0
                self.update(job.id, save: false) { $0.progress = p * 0.97; $0.bytes = done; $0.speed = sp; $0.eta = total > done && sp > 0 ? Double(total - done) / sp : 0 }
            }
        }
        // Los servidores sirven el original en una dirección sin extensión: se mira el contenido (un MKV guardado como .mp4 no se abría)
        if ext.isEmpty { ext = Self.containerExtension(tmp) }
        let dest = Self.folder.appendingPathComponent("\(base).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest.lastPathComponent
    }

    /// Extensión del contenedor según los primeros bytes: MKV/WebM (EBML), AVI (RIFF), MP4/MOV (ftyp), TS; si no, mp4.
    nonisolated static func containerExtension(_ file: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: file), let d = try? h.read(upToCount: 16) else { return "mp4" }
        try? h.close()
        let b = [UInt8](d)
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return "mkv" }
        if b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "AVI " { return "avi" }
        if b.first == 0x47 { return "ts" }
        return "mp4"
    }

    /// Descarga a un fichero con aviso del progreso y cancelación (la API nueva no da progreso).
    nonisolated static func downloadFile(_ req: URLRequest, progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: req) { tmp, resp, err in
                    if let err = err { c.resume(throwing: err); return }
                    if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { c.resume(throwing: NSError(domain: "HTTP", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(h.statusCode)"])); return }
                    guard let tmp = tmp else { c.resume(throwing: URLError(.badServerResponse)); return }
                    // El sistema borra el temporal al volver: se mueve ya
                    let keep = FileManager.default.temporaryDirectory.appendingPathComponent("dlf-\(UUID().uuidString)")
                    do { try FileManager.default.moveItem(at: tmp, to: keep); c.resume(returning: keep) } catch { c.resume(throwing: error) }
                }
                box.task = task
                box.observation = task.progress.observe(\.completedUnitCount) { p, _ in progress(p.completedUnitCount, p.totalUnitCount) }
                task.resume()
            }
        } onCancel: { box.task?.cancel() }
    }
    private final class TaskBox: @unchecked Sendable { var task: URLSessionDownloadTask?; var observation: NSKeyValueObservation? }

    /// La variante de más ancho de banda de una lista maestra (el relay ya recortó las que no valen).
    nonisolated static func pickVideo(_ text: String, base: URL) -> URL? {
        guard text.contains("#EXT-X-STREAM-INF") else { return base }       // ya es una lista de medios
        let lines = text.components(separatedBy: .newlines)
        var best: (bw: Int, url: URL)?
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
            var bw = 0
            if let r = l.range(of: "BANDWIDTH=\\d+", options: .regularExpression) { bw = Int(l[r].dropFirst(10)) ?? 0 }
            if let next = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }), let u = URL(string: next, relativeTo: base), bw >= (best?.bw ?? -1) { best = (bw, u.absoluteURL) }
        }
        return best?.url
    }

    nonisolated static func uriAttribute(_ line: String, base: URL) -> URL? {
        guard let r = line.range(of: "URI=\"[^\"]+\"", options: .regularExpression) else { return nil }
        return URL(string: String(line[r].dropFirst(5).dropLast()), relativeTo: base)?.absoluteURL
    }

    /// Lista de direcciones de una lista de medios: el trozo de inicio (si hay) y los segmentos.
    nonisolated static func parts(of playlistText: String, base: URL) -> [URL] {
        var parts: [URL] = []
        for l in playlistText.components(separatedBy: .newlines) {
            let s = l.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#EXT-X-MAP"), let u = uriAttribute(s, base: base) { parts.append(u) }
            else if !s.hasPrefix("#"), !s.isEmpty, let u = URL(string: s, relativeTo: base) { parts.append(u.absoluteURL) }
        }
        return parts
    }

    /// Baja una pista (init + segmentos ya descifrados por el relay) y la concatena en un fichero.
    /// Se piden varios trozos a la vez y se escriben en orden; así se aprovecha mejor la red.
    private func fetchTrack(_ playlist: URL, to file: URL, jobId: String, headers: [String: String], from: Double, span: Double) async throws {
        let fetch = URLSessionFetcher()
        let text = String(decoding: try await fetch.fetch(playlist, headers: headers), as: UTF8.self)
        let parts = Self.parts(of: text, base: playlist)
        guard !parts.isEmpty else { throw NSError(domain: "descarga", code: 2, userInfo: [NSLocalizedDescriptionKey: "la pista no tiene segmentos"]) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let h = try FileHandle(forWritingTo: file)
        defer { try? h.close() }
        let conn = AppSettings.dlConnections
        var i = 0
        while i < parts.count {
            try Task.checkCancellation()
            if playbackActive { Trace.shared.log("descarga", "«\(jobId)» en pausa mientras se reproduce (Ajustes → Descargas)") }
            while playbackActive { try await Task.sleep(nanoseconds: 1_000_000_000); try Task.checkCancellation() }
            let chunk = Array(parts[i..<min(i + conn, parts.count)])
            let t0 = Date()
            let got: [Data] = try await withThrowingTaskGroup(of: (Int, Data).self) { g in
                for (k, u) in chunk.enumerated() { g.addTask { (k, try await fetch.fetch(u, headers: headers)) } }
                var r = [Data](repeating: Data(), count: chunk.count)
                for try await (k, d) in g { r[k] = d }
                return r
            }
            var n = 0
            for d in got { try h.write(contentsOf: d); n += d.count }
            i += chunk.count
            let dt = max(Date().timeIntervalSince(t0), 0.001)
            let p = from + span * Double(i) / Double(parts.count)
            var m = meters[jobId] ?? Meter()
            m.active += dt
            m.speed = m.speed == 0 ? Double(n) / dt : m.speed * 0.7 + (Double(n) / dt) * 0.3     // media móvil para que no salte
            meters[jobId] = m
            let active = m.active, sp = m.speed
            update(jobId, save: false) {
                $0.progress = p; $0.bytes += Int64(n); $0.speed = sp
                $0.eta = p > 0.02 ? active * (1 - p) / p : 0
            }
            if (i / conn) % 15 == 0 { Trace.shared.log("descarga", "\(i)/\(parts.count) segmentos de «\(jobId)» · \(Int(sp / 1000)) kB/s") }
        }
        save()
    }

    /// Un subtítulo (lista con varios trozos WebVTT o un fichero suelto) en un solo WebVTT.
    private func fetchSubtitle(_ url: URL, headers: [String: String]) async throws -> String {
        let fetch = URLSessionFetcher()
        let text = String(decoding: try await fetch.fetch(url, headers: headers), as: UTF8.self)
        if text.contains("WEBVTT") && !text.contains("#EXTM3U") { return WebVTT.merge([text]) }
        var pieces: [String] = []
        for u in Self.parts(of: text, base: url) {
            try Task.checkCancellation()
            pieces.append(String(decoding: try await fetch.fetch(u, headers: headers), as: UTF8.self))
        }
        guard !pieces.isEmpty else { throw NSError(domain: "descarga", code: 4, userInfo: [NSLocalizedDescriptionKey: "subtítulo vacío"]) }
        return WebVTT.merge(pieces)
    }

    nonisolated static func renamedByContent(_ f: URL) throws -> URL {
        let n = f.deletingPathExtension().appendingPathExtension(sniffExtension(f))
        try FileManager.default.moveItem(at: f, to: n); return n
    }

    /// Extensión que corresponde a lo descargado según sus primeros bytes (AVFoundation decide el lector por ella).
    nonisolated static func sniffExtension(_ file: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: file), let d = try? h.read(upToCount: 12) else { return "mp4" }
        try? h.close()
        let b = [UInt8](d)
        if b.count >= 8, String(decoding: b[4..<8], as: UTF8.self) == "ftyp" || String(decoding: b[4..<8], as: UTF8.self) == "moof" || String(decoding: b[4..<8], as: UTF8.self) == "styp" { return "mp4" }
        if b.first == 0x47 { return "ts" }
        if b.count >= 3, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return "aac" }       // ID3 + AAC suelto
        if b.count >= 2, b[0] == 0xFF, b[1] & 0xF0 == 0xF0 { return "aac" }              // ADTS
        return "mp4"
    }

    /// Une vídeo y audios en un MP4 sin recodificar. Cada pista usa su propio rango de tiempo (en MP4 fragmentado la
    /// duración del conjunto puede salir en cero y entonces el vídeo se perdía y solo sonaba el audio).
    /// Todos los audios se conservan en el fichero (con un audio desactivado el export lo descartaba); se elige cuál suena en el reproductor.
    nonisolated static func mux(video: URL, audios: [(URL, String)], to dest: URL) async throws {
        let comp = AVMutableComposition()
        func fail(_ m: String) -> NSError { NSError(domain: "descarga", code: 3, userInfo: [NSLocalizedDescriptionKey: m]) }
        let va = AVURLAsset(url: video)
        guard let vt = try await va.loadTracks(withMediaType: .video).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw fail("el fichero de vídeo descargado no tiene imagen (\(video.pathExtension))")
        }
        var vr = try await vt.load(.timeRange)
        if !vr.duration.isValid || vr.duration.seconds <= 0 { vr = CMTimeRange(start: .zero, duration: try await va.load(.duration)) }
        try cv.insertTimeRange(vr, of: vt, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        // Audio: de las pistas aparte o, si el vídeo ya lo trae (TS), del propio fichero
        let sources: [(AVURLAsset, String)] = audios.isEmpty ? [(va, "")] : audios.map { (AVURLAsset(url: $0.0), $0.1) }
        var first = true
        for (aa, lang) in sources {
            guard let at = try await aa.loadTracks(withMediaType: .audio).first,
                  let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var ar = try await at.load(.timeRange)
            if !ar.duration.isValid || ar.duration.seconds <= 0 { ar = CMTimeRange(start: .zero, duration: try await aa.load(.duration)) }
            // El audio puede empezar más tarde que el vídeo (p. ej. +0,5 s en los MKV reempaquetados): se inserta en su sitio, no en 0,
            // porque si no sonaría adelantado respecto a la imagen.
            let rel = CMTimeSubtract(ar.start, vr.start)
            let at0 = CMTimeCompare(rel, .zero) > 0 && rel.seconds < 10 ? rel : CMTime.zero
            let len = CMTimeMinimum(ar.duration, CMTimeSubtract(vr.duration, at0))
            Trace.shared.log("descarga", "unión: vídeo empieza en \(String(format: "%.3f", vr.start.seconds)) s, audio en \(String(format: "%.3f", ar.start.seconds)) s → audio colocado en \(String(format: "%.3f", at0.seconds)) s")
            try ca.insertTimeRange(CMTimeRange(start: ar.start, duration: len), of: at, at: at0)
            if !lang.isEmpty { ca.extendedLanguageTag = lang }
            first = false
        }
        try? FileManager.default.removeItem(at: dest)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw fail("no se pudo preparar la unión") }
        ex.outputURL = dest
        ex.outputFileType = .mp4
        // API clásica (la nueva solo existe desde iOS 18)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        if ex.status != .completed { throw ex.error ?? fail("la unión falló (estado \(ex.status.rawValue))") }
        // Comprobación: el resultado debe tener vídeo
        let out = AVURLAsset(url: dest)
        guard try await out.loadTracks(withMediaType: .video).first != nil else { throw fail("la unión no produjo imagen") }
    }
}

// MARK: - Pantallas

/// Texto de velocidad y tiempo que falta: «8,4 MB/s · quedan 6 min».
func downloadSpeedText(_ j: DownloadJob) -> String {
    guard j.state == "descargando", j.speed > 0 else { return "" }
    let sp = ByteCountFormatter.string(fromByteCount: Int64(j.speed), countStyle: .file) + "/s"
    guard j.eta > 1 else { return sp }
    let m = Int(j.eta) / 60, s = Int(j.eta) % 60
    let left = m >= 60 ? "\(m / 60) h \(m % 60) min" : (m > 0 ? "\(m) min \(s) s" : "\(s) s")
    return "\(sp) · quedan \(left)"
}

/// Lista de descargas: progreso, velocidad, ver sin conexión, reintentar y borrar.
struct DownloadsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @EnvironmentObject var themes: ThemeStore

    var body: some View {
        let t = themes.theme
        List {
            if dm.jobs.isEmpty { Text("No hay descargas. Pulsa «Descargar» en la ficha de una película o capítulo.").foregroundStyle(t.c(t.dim)).themedRow() }
            ForEach(dm.jobs) { j in
                VStack(alignment: .leading, spacing: 6) {
                    Text(j.title).font(.subheadline)
                    if j.state == "listo", let f = dm.fileURL(j) {
                        HStack {
                            NavigationLink { OfflinePlayer(file: f, title: j.title, subs: j.subs) } label: { Label("Ver sin conexión", systemImage: "play.circle").font(.footnote) }
                            Spacer()
                            deleteButton(j)
                        }
                    } else if j.state == "error" {
                        Text(j.error ?? "error").font(.caption).foregroundStyle(t.c(t.danger))
                        HStack {
                            Button { dm.retry(j) } label: { Label("Reintentar", systemImage: "arrow.clockwise") }.buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                            deleteButton(j)
                        }
                    } else {
                        ProgressView(value: j.progress)
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(j.state) · \(Int(j.progress * 100)) %").font(.caption).foregroundStyle(t.c(t.dim))
                                let sp = downloadSpeedText(j)
                                if !sp.isEmpty { Text(sp).font(.caption2.monospacedDigit()).foregroundStyle(t.c(t.dim)) }
                            }
                            Spacer()
                            deleteButton(j, title: "Cancelar")
                        }
                    }
                }.themedRow()
            }
            .onDelete { for i in $0 { dm.remove(dm.jobs[i]) } }
        }
        .themedScreen().navigationTitle("Descargas")
        .toolbar { if !dm.jobs.isEmpty { ToolbarItem(placement: .topBarTrailing) { Button(role: .destructive) { dm.removeAll() } label: { Label("Borrar todas", systemImage: "trash") } } } }
    }

    /// Botón (no texto) para borrar o cancelar una descarga y su fichero.
    private func deleteButton(_ j: DownloadJob, title: String = "Borrar") -> some View {
        Button(role: .destructive) { dm.remove(j) } label: { Label(title, systemImage: "trash") }
            .buttonStyle(.bordered).controlSize(.small).tint(.red)
    }
}

/// Una pista de audio de un fichero descargado.
struct OfflineAudio: Identifiable { let id: Int; let trackID: CMPersistentTrackID; let tag: String; let name: String }

/// Reproduce un fichero descargado a pantalla completa, con sus subtítulos y el estilo de Ajustes.
struct OfflinePlayer: View {
    let file: URL, title: String
    var subs: [SubFile] = []
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var cues: [SubtitleCue] = []
    @State private var current = ""
    @State private var selected: SubFile?
    @State private var audios: [OfflineAudio] = []
    @State private var audioDelay = 0
    @State private var audioSel = 0
    @State private var observer: Any?
    @State private var showBar = true
    @State private var hide: Task<Void, Never>?
    private let full = AppSettings.fullscreen

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let p = player {
                FullscreenVideo(player: p, onTap: { withAnimation { showBar = true }; scheduleHide() }).ignoresSafeArea()
            } else { ProgressView().tint(.white) }
            SubtitleOverlay(text: current).ignoresSafeArea()
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.body.bold()).frame(width: 44, height: 44).background(.black.opacity(showBar ? 0.6 : 0.35), in: Circle())
                }
                if showBar {
                    Text(title).font(.subheadline.bold()).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule())
                    Spacer()
                    if !subs.isEmpty {
                        Menu {
                            Button { choose(nil) } label: { Label("Sin subtítulos", systemImage: selected == nil ? "checkmark" : "") }
                            ForEach(subs, id: \.self) { s in Button { choose(s) } label: { Label(s.name, systemImage: selected == s ? "checkmark" : "") } }
                        } label: { Image(systemName: "captions.bubble").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
                    }
                    if audios.count > 1 {
                        Menu {
                            ForEach(audios) { a in Button { chooseAudio(a.id) } label: { Label(a.name, systemImage: audioSel == a.id ? "checkmark" : "") } }
                        } label: { Image(systemName: "speaker.wave.2").frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle()) }
                    }
                    AudioDelayButton(applied: $audioDelay, apply: applyDelay)
                    SubtitleStyleMenu()
                } else { Spacer() }
            }
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.top, 76)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(full)
        .persistentSystemOverlays(full ? .hidden : .automatic)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = AVPlayer(url: file)
            DownloadManager.shared.register(p)
            player = p
            observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
                let s = WebVTT.text(at: t.seconds, in: cues)
                if s != current { current = s }
            }
            if let first = subs.first { choose(first) }
            Task { await loadAudios() }
            p.play(); scheduleHide()
        }
        .onDisappear {
            if let o = observer { player?.removeTimeObserver(o) }
            player?.pause(); player = nil
        }
    }

    /// Las pistas de audio del fichero (idioma, códec y canales). Si hay varias, suena una sola: la del idioma del aparato o la primera.
    private func loadAudios() async {
        guard let item = player?.currentItem else { return }
        guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio), tracks.count > 1 else { return }
        var list: [OfflineAudio] = []
        for (i, t) in tracks.enumerated() {
            var tag = (try? await t.load(.extendedLanguageTag)) ?? ""
            if tag.isEmpty { tag = (try? await t.load(.languageCode)) ?? "" }
            let lang = tag.isEmpty ? "Audio \(i + 1)" : (Locale.current.localizedString(forLanguageCode: tag) ?? tag).capitalized
            var extra = ""
            if let fd = try? await t.load(.formatDescriptions).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                let codec = asbd.mFormatID == kAudioFormatEnhancedAC3 ? "E-AC-3" : asbd.mFormatID == kAudioFormatAC3 ? "AC-3" : asbd.mFormatID == kAudioFormatMPEG4AAC ? "AAC" : "audio"
                let ch = asbd.mChannelsPerFrame
                extra = " · " + codec + " " + (ch == 6 ? "5.1" : ch == 8 ? "7.1" : ch == 2 ? "estéreo" : ch == 1 ? "mono" : "\(ch) canales")
            }
            list.append(OfflineAudio(id: i, trackID: t.trackID, tag: tag, name: lang + extra))
        }
        audios = list
        chooseAudio(list.first { $0.tag.lowercased().hasPrefix(AppSettings.deviceLang) }?.id ?? 0)
    }

    /// Desplaza el audio respecto a la imagen: se reconstruye el vídeo con el audio movido y se sigue por donde iba.
    private func applyDelay(_ ms: Int) async -> String? {
        guard let p = player else { return "No hay reproductor" }
        let t = p.currentTime(), playing = p.rate > 0, keep = audioSel
        do {
            let item = AVPlayerItem(asset: try await AudioDelayAsset.make(file: file, ms: ms))
            p.replaceCurrentItem(with: item)
            await p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            await loadAudios()
            if keep < audios.count { chooseAudio(keep) }
            if playing { p.play() }
            return nil
        } catch { return error.localizedDescription }
    }

    /// Activa solo la pista elegida (las demás quedan en silencio).
    private func chooseAudio(_ i: Int) {
        guard let item = player?.currentItem, i < audios.count else { return }
        audioSel = i
        for t in item.tracks where t.assetTrack?.mediaType == .audio { t.isEnabled = (t.assetTrack?.trackID == audios[i].trackID) }
    }

    private func choose(_ s: SubFile?) {
        selected = s; current = ""
        guard let s = s, let text = try? String(contentsOf: DownloadManager.folder.appendingPathComponent(s.file), encoding: .utf8) else { cues = []; return }
        cues = WebVTT.parse(text)
    }
    private func scheduleHide() {
        hide?.cancel()
        hide = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled { withAnimation { showBar = false } } }
    }
}

/// Ventana de opciones antes de descargar (como en Android): calidad, idiomas de audio y de subtítulos.
struct DownloadRequest: Identifiable { let id = UUID(); var title: String; var channels: [IptvChannel] }

struct DownloadOptionsSheet: View {
    let request: DownloadRequest
    var onStart: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themes: ThemeStore
    @State private var probe: DownloadProbe?
    @State private var loading = true
    @State private var opts = DownloadOptions.defaults

    /// Idiomas distintos (por código base) de una lista de pistas, con el nombre de la primera.
    private func languages(_ tracks: [MediaTrack]) -> [(code: String, name: String)] {
        var seen = Set<String>(), out: [(code: String, name: String)] = []
        for t in tracks where !t.base.isEmpty && seen.insert(t.base).inserted { out.append((code: t.base, name: t.name)) }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                Section { Text(request.title).font(.headline); if request.channels.count > 1 { Text("\(request.channels.count) capítulos").font(.caption) } }
                if loading {
                    Section { HStack { ProgressView(); Text("Mirando qué ofrece este título…").font(.footnote) } }
                } else if let p = probe {
                    if !p.mkv.isEmpty { MkvTracksSection(tracks: p.mkv) }
                    if p.mkv.isEmpty { Section("Calidad") {
                        Picker("Calidad", selection: $opts.height) {
                            Text("La mejor").tag(0)
                            ForEach(p.heights, id: \.self) { Text("Hasta \($0)p").tag($0) }
                        }
                    } }
                    if !p.audios.isEmpty {
                        Section("Audio") {
                            Toggle("Todos los idiomas", isOn: bind(\.audioLangs, "*"))
                            ForEach(languages(p.audios), id: \.code) { l in
                                Toggle(l.name, isOn: bind(\.audioLangs, l.code))
                            }
                        }
                    }
                    Section("Subtítulos") {
                        if p.subs.isEmpty { Text("Este título no trae subtítulos separados.").font(.footnote).foregroundStyle(.secondary) }
                        if !p.subs.isEmpty { Toggle("Todos los idiomas", isOn: bind(\.subLangs, "*")) }
                        ForEach(languages(p.subs), id: \.code) { l in Toggle(l.name, isOn: bind(\.subLangs, l.code)) }
                    }
                } else {
                    Section { Text("Fichero directo: se baja tal cual.").font(.footnote) }
                }
                Section {
                    Button {
                        DownloadManager.shared.enqueue(request.channels, options: opts); onStart(); dismiss()
                    } label: { Label("Descargar", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Opciones de descarga").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .task {
                if let first = request.channels.first { probe = await DownloadManager.shared.inspect(channel: first) }
                loading = false
            }
        }
    }

    /// Casilla ligada a una lista de códigos de idioma de las opciones.
    private func bind(_ kp: WritableKeyPath<DownloadOptions, [String]>, _ code: String) -> Binding<Bool> {
        Binding(get: { opts[keyPath: kp].contains(code) },
                set: { on in
                    if on { if !opts[keyPath: kp].contains(code) { opts[keyPath: kp].append(code) } }
                    else { opts[keyPath: kp].removeAll { $0 == code } }
                })
    }
}


/// Pistas de un MKV al pedir la descarga: en verde las que pasan directas al reempaquetar en el dispositivo, en rojo las que habría que recodificar.
struct MkvTracksSection: View {
    let tracks: [MkvToHls.TrackReport]
    var body: some View {
        Section {
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, t in
                HStack(spacing: 8) {
                    Image(systemName: t.direct ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    Text("\(t.kind) · \(t.label) · \(t.codec)").font(.footnote)
                    Spacer()
                    Text(t.direct ? "directa" : "recodificar").font(.caption2)
                }.foregroundStyle(t.direct ? Color.green : Color.red)
            }
        } header: { Text("Pistas del MKV") } footer: {
            Text(tracks.allSatisfy { $0.direct }
                 ? "Todas las pistas pasan directas: reempaquetar en el dispositivo es lo más rápido y sin pérdida de calidad."
                 : "Las rojas no las decodifica el iPad y se dejan fuera (haría falta que el servidor recodifique). Aconsejado: reempaquetar en local con las verdes, que no gasta servidor ni pierde calidad.")
        }
    }
}

/// Velocidad media móvil de una descarga cuyo avance llega como «bytes totales hasta ahora».
final class MkvMeter {
    private var last = Date(), lastBytes: Int64 = 0, value = 0.0
    private let lock = NSLock()
    func speed(bytes: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), dt = now.timeIntervalSince(last)
        guard dt >= 0.5 else { return value }
        let inst = Double(bytes - lastBytes) / dt
        value = value == 0 ? inst : value * 0.7 + inst * 0.3
        last = now; lastBytes = bytes
        return value
    }
}


/// Carpeta de destino de las descargas. Por defecto, Documentos/Descargas de la app (compartida con la app Archivos); el usuario puede
/// elegir otra (iCloud Drive, una unidad externa…): se guarda un marcador de seguridad y se abre el acceso una vez por ejecución.
enum DownloadFolder {
    private static let key = "set.dlFolderBookmark"
    private static var opened: URL?                                    // carpeta elegida con el acceso ya abierto

    static var appDefault: URL {
        let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Descargas")
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// ¿Se está usando una carpeta elegida por el usuario?
    static var isCustom: Bool { UserDefaults.standard.data(forKey: key) != nil }

    static var current: URL {
        if let o = opened { return o }
        guard let data = UserDefaults.standard.data(forKey: key) else { return appDefault }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return appDefault }       // no se puede abrir: se vuelve a la de la app
        if stale, let nuevo = try? url.bookmarkData() { UserDefaults.standard.set(nuevo, forKey: key) }
        opened = url
        return url
    }

    /// Nombre corto para enseñar en Ajustes.
    static var displayName: String { isCustom ? current.lastPathComponent : "HLS/Descargas (en la app Archivos)" }

    /// Guarda la carpeta que devuelve el selector de carpetas.
    @discardableResult static func choose(_ url: URL) -> Bool {
        let gotAccess = url.startAccessingSecurityScopedResource()
        guard let data = try? url.bookmarkData() else { if gotAccess { url.stopAccessingSecurityScopedResource() }; return false }
        if let o = opened { o.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.set(data, forKey: key)
        opened = gotAccess ? url : nil
        return true
    }

    /// Vuelve a la carpeta de la app.
    static func useAppFolder() {
        if let o = opened { o.stopAccessingSecurityScopedResource() }
        opened = nil
        UserDefaults.standard.removeObject(forKey: key)
    }
}
