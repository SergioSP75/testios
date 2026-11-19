import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HLSCore

/// Serie de prueba de formatos (`TestSeries/serie_formatos.json`): cada capítulo declara qué tipo de contenido es (`kind`) y con qué
/// motor debe abrirse (`engine`).
///  - La parte estructural corre siempre (el JSON es válido, la Mediateca lo lee, no faltan formatos).
///  - La parte «en vivo» baja cabeceras y manifiestos reales y comprueba que el detector, el catálogo de pistas y el selector de motor
///    dicen lo esperado. Se activa con la variable de entorno LIVE_TESTS=1 (usa red).
final class FormatSeriesTests: XCTestCase {

    private var seriesDir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestSeries") }

    private struct Entry { let name: String; let url: String; let kind: String; let engine: String }

    private func entries() throws -> [Entry] {
        let data = try Data(contentsOf: seriesDir.appendingPathComponent("tests_formatos.json"))
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return arr.map { e in
            let ex = e["expect"] as? [String: String] ?? [:]
            return Entry(name: e["name"] as? String ?? "", url: e["url"] as? String ?? "", kind: ex["kind"] ?? "", engine: ex["engine"] ?? "")
        }
    }

    // Estructura ---------------------------------------------------------------------------------------------------

    func testLaMedioatecaLeeLaSerieDeFormatos() throws {
        let data = try Data(contentsOf: seriesDir.appendingPathComponent("serie_formatos.json"))
        let items = MediaCatalog.parse(data, sourceId: "pruebas")
        XCTAssertEqual(items.count, 1)
        let serie = items[0]
        XCTAssertTrue(serie.isSeries)
        XCTAssertEqual(serie.seasons.count, 3)
        XCTAssertEqual(serie.episodeCount, try entries().count)
        XCTAssertTrue(serie.seasons.flatMap { $0.episodes }.allSatisfy { !$0.video.isEmpty })
    }

    func testLaSerieCubreTodosLosFormatosVistos() throws {
        let urls = try entries().map { $0.url.lowercased() }
        let kinds = Set(try entries().map { $0.kind })
        XCTAssertEqual(kinds, ["hlsPlain", "dash", "smooth", "matroska", "other"])
        for ext in [".m3u8", ".mpd", "manifest", ".mkv", ".webm", ".avi", ".flac", ".mp3", ".wav", ".mp4"] {
            XCTAssertTrue(urls.contains { $0.contains(ext) }, "falta un caso con \(ext)")
        }
        XCTAssertTrue(try entries().contains { $0.engine == "vlc" } && entries().contains { $0.engine == "avplayer" })
    }

    func testElMotorEsperadoPorExtensionCoincideConElSelector() throws {
        // Para los ficheros sueltos (kind «other») el motor sale de la extensión
        for e in try entries() where e.kind == "other" && !e.name.contains("el contenido manda") {
            let ext = EngineChooser.fileExtension(of: e.url)
            let got = EngineChooser.choose(setting: .auto, facts: MediaFacts(kind: .other, fileExtension: ext))
            XCTAssertEqual(got.rawValue, e.engine, "\(e.name) (.\(ext))")
        }
    }

    func testLaSerieNoLlevaClavesNiTokens() throws {
        let raw = try String(contentsOf: seriesDir.appendingPathComponent("tests_formatos.json"), encoding: .utf8).lowercased()
        for bad in ["token=", "apikey", "password", "drmkey", "x-plex-token", "access_token"] { XCTAssertFalse(raw.contains(bad), bad) }
    }

    // En vivo -------------------------------------------------------------------------------------------------------

    private struct NetFetcher: Fetcher {
        func fetch(_ url: URL, headers: [String: String]) async throws -> Data { try await fetchResolved(url, headers: headers).0 }
        func fetchResolved(_ url: URL, headers: [String: String]) async throws -> (Data, URL) {
            var req = URLRequest(url: url, timeoutInterval: 60)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue("Mozilla/5.0 (iPad) mediakiller-sp75 MediaKillerSP75", forHTTPHeaderField: "User-Agent")
            return try await withCheckedThrowingContinuation { cont in
                URLSession.shared.dataTask(with: req) { data, resp, err in
                    if let err = err { cont.resume(throwing: err); return }
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code >= 400 { cont.resume(throwing: NSError(domain: "HTTP", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(url.absoluteString)"])); return }
                    cont.resume(returning: (data ?? Data(), resp?.url ?? url))
                }.resume()
            }
        }
    }

    /// Proveedores privados (Disney, Max…): solo si existe `TestSeries/tests_proveedores.local.json` (lo genera genera_privada.py y no se sube a git).
    /// Mira que el manifiesto se lee, que el catálogo de pistas sale con vídeo y audio, y que el tipo coincide.
    func testEnVivoProveedoresPrivados() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1", "pruebas con red: LIVE_TESTS=1")
        let file = seriesDir.appendingPathComponent("tests_proveedores.local.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "sin catálogo privado local")
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let net = NetFetcher()
        var report: [String] = []
        for e in arr {
            let name = e["name"] as? String ?? "?", urlS = e["url"] as? String ?? ""
            let want = ((e["expect"] as? [String: String]) ?? [:])["kind"] ?? ""
            guard let url = URL(string: urlS) else { XCTFail("URL mala \(name)"); continue }
            guard let data = try? await net.fetch(url, headers: ["User-Agent": "AppleCoreMedia/1.0.0 (iPad; U; CPU OS 17_0 like Mac OS X; es_es)"]) else {
                report.append("SIN RESPUESTA \(name) (enlace caducado o con token)"); continue
            }
            let text = String(decoding: data, as: UTF8.self)
            let kind = StreamSniffer.kind(ofManifest: text)
            let o: StreamOffer = kind == .dash ? StreamOffers.fromMpd(text) : kind == .smooth ? StreamOffers.fromSmooth(text) : StreamOffers.fromHls(text)
            let tipo = kind == .dash ? "dash" : kind == .smooth ? "smooth" : "hlsPlain"
            report.append("\(tipo == want || (want == "hlsPlain" && kind == .hlsEncrypted) ? "OK " : "MAL") \(name): \(kind) · \(o.videos.count) vídeos \(o.heights.prefix(3)), \(o.audios.count) audios \(o.audioLanguages.map { $0.code }.prefix(5)), \(o.subs.count) subs")
            XCTAssertFalse(o.videos.isEmpty, "\(name): sin vídeos en el catálogo")
            XCTAssertFalse(o.audios.isEmpty && !text.contains("mp4a"), "\(name): sin audios")
        }
        print("INFORME PROVEEDORES\n" + report.joined(separator: "\n"))
    }

    func testEnVivoCadaFormatoSeDetectaYTieneElMotorEsperado() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1", "pruebas con red: LIVE_TESTS=1")
        let net = NetFetcher()
        var report: [String] = []
        for e in try entries() {
            guard let url = URL(string: e.url) else { XCTFail("URL mala \(e.name)"); continue }
            // Las 64 KB primeras bastan para saber qué es; el manifiesto se baja entero
            let head = try await net.fetch(url, headers: ["Range": "bytes=0-65535"])
            var kind = StreamSniffer.isMatroska(head) ? "matroska" : { () -> String in
                switch StreamSniffer.kind(ofManifest: String(decoding: head, as: UTF8.self)) {
                case .hlsPlain, .hlsEncrypted: return "hlsPlain"
                case .dash: return "dash"
                case .smooth: return "smooth"
                case .matroska: return "matroska"
                case .other: return "other"
                }
            }()
            var engine = PlaybackEngine.avplayer
            var detail = ""
            switch kind {
            case "hlsPlain":
                let o = StreamOffers.fromHls(String(decoding: try await net.fetch(url, headers: [:]), as: UTF8.self))
                detail = "\(o.videos.count) vídeos, \(o.audios.count) audios, \(o.subs.count) subs"
                XCTAssertFalse(o.videos.isEmpty, e.name)
                engine = o.videos.contains { $0.engine == .avplayer } ? .avplayer : .vlc
            case "dash":
                let o = StreamOffers.fromMpd(String(decoding: try await net.fetch(url, headers: [:]), as: UTF8.self))
                detail = "\(o.videos.count) vídeos, \(o.audios.count) audios, \(o.subs.count) subs"
                XCTAssertFalse(o.videos.isEmpty, e.name); XCTAssertFalse(o.audios.isEmpty, e.name)
                engine = o.videos.contains { $0.engine == .avplayer } ? .avplayer : .vlc
            case "smooth":
                let o = StreamOffers.fromSmooth(String(decoding: try await net.fetch(url, headers: [:]), as: UTF8.self))
                detail = "\(o.videos.count) vídeos, \(o.audios.count) audios"
                XCTAssertFalse(o.videos.isEmpty, e.name)
                engine = o.videos.contains { $0.engine == .avplayer } ? .avplayer : .vlc
            case "matroska":
                let rep = await MkvToHls.survey(source: HttpRangeSource(fetcher: net, url: url, headers: [:]))
                XCTAssertNotNil(rep, "\(e.name): cabecera Matroska ilegible")
                let o = StreamOffers.fromMkv(rep ?? [])
                detail = (rep ?? []).map { "\($0.kind) \($0.codec)\($0.direct ? "✓" : "✗")" }.joined(separator: ", ")
                // MKV: AVPlayer solo si el vídeo y algún audio pasan directos al reempaquetar
                let vOk = o.videos.contains { $0.engine == .avplayer }, aOk = o.audios.isEmpty || o.audios.contains { $0.engine == .avplayer }
                engine = vOk && aOk ? .avplayer : .vlc
            default:
                // El contenido manda sobre la extensión de la dirección
                let ext = ContainerSniffer.extension(of: head) ?? EngineChooser.fileExtension(of: e.url)
                engine = EngineChooser.choose(setting: .auto, facts: MediaFacts(kind: .other, fileExtension: ext))
                detail = "extensión .\(ext)"
                // Un fichero sin manifiesto no debe parecer un manifiesto
                XCTAssertEqual(StreamSniffer.kind(ofManifest: String(decoding: head.prefix(2000), as: UTF8.self)), .other, e.name)
            }
            if kind == "other", StreamSniffer.isMatroska(head) { kind = "matroska" }
            report.append("\(kind == e.kind && engine.rawValue == e.engine ? "OK " : "MAL") \(e.name): \(kind)/\(engine.rawValue) · \(detail)")
            XCTAssertEqual(kind, e.kind, "\(e.name): tipo")
            XCTAssertEqual(engine.rawValue, e.engine, "\(e.name): motor (\(detail))")
        }
        print("INFORME FORMATOS\n" + report.joined(separator: "\n"))
    }
}
