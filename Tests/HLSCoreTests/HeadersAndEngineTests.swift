import XCTest
@testable import HLSCore

/// Cabeceras propias de listas y servidores, y elección del reproductor (AVPlayer o VLC).
final class RequestHeadersTests: XCTestCase {

    func testParseIgnoraBasuraYLaUltimaGana() {
        let h = RequestHeaders.parse("""
        # comentario
        User-Agent: AppleCoreMedia
        Referer:  https://x.tv/a:b

        sin dos puntos
        :sin nombre
        user-agent: Otro
        """)
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h["user-agent"], "Otro", "el repetido sin mirar mayúsculas deja el último")
        XCTAssertNil(h["User-Agent"])
        XCTAssertEqual(h["Referer"], "https://x.tv/a:b", "los dos puntos del valor se respetan")
    }

    func testFormatYParseSonInversos() {
        let h = ["X-Token": "abc", "User-Agent": "UA/1 (x:y)"]
        XCTAssertEqual(RequestHeaders.parse(RequestHeaders.format(h)), h)
    }

    func testMergePisaSinMirarMayusculas() {
        let m = RequestHeaders.merge(["User-Agent": "lista", "Accept": "*/*"], ["user-agent": "propio"])
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(RequestHeaders.value(m, "User-Agent"), "propio")
        XCTAssertEqual(m["Accept"], "*/*")
    }

    func testApplyDaPrioridadSobreElFicheroYRellenaCamposDelCanal() {
        var ch = IptvChannel(id: "1", name: "C", url: "http://a/b.m3u8", userAgent: "del-fichero", referrer: "http://viejo", httpHeaders: ["X-A": "1", "user-agent": "del-fichero"])
        ch = RequestHeaders.apply(ch, extra: ["User-Agent": "mio", "Referrer": "http://nuevo", "X-B": "2"])
        XCTAssertEqual(ch.userAgent, "mio")
        XCTAssertEqual(ch.referrer, "http://nuevo")
        XCTAssertEqual(RequestHeaders.value(ch.httpHeaders, "User-Agent"), "mio")
        XCTAssertEqual(ch.httpHeaders.keys.filter { $0.lowercased() == "user-agent" }.count, 1, "no quedan dos User-Agent")
        XCTAssertEqual(ch.httpHeaders["X-A"], "1")
        XCTAssertEqual(ch.httpHeaders["X-B"], "2")
    }

    func testApplyVacioNoCambiaNada() {
        let ch = IptvChannel(id: "1", name: "C", url: "http://a", userAgent: "ua")
        XCTAssertEqual(RequestHeaders.apply(ch, extra: [:]), ch)
    }

    func testEffectiveJuntaCamposYCabecerasPropias() {
        let ch = IptvChannel(id: "1", name: "C", url: "http://a", userAgent: "ua", referrer: "http://r", httpHeaders: ["X-A": "1"])
        let h = RequestHeaders.effective(channel: ch, extra: ["referer": "http://otro"])
        XCTAssertEqual(RequestHeaders.value(h, "User-Agent"), "ua")
        XCTAssertEqual(RequestHeaders.value(h, "Referer"), "http://otro", "la de la lista/servidor manda")
        XCTAssertEqual(h["X-A"], "1")
    }

    func testFromJsonDescartaLoQueNoEsTexto() {
        let h = RequestHeaders.fromJSON(["User-Agent": "x", "N": 5, " ": "vacío", "Ok": "1"] as [String: Any])
        XCTAssertEqual(h, ["User-Agent": "x", "Ok": "1"])
        XCTAssertTrue(RequestHeaders.fromJSON(nil).isEmpty)
        XCTAssertTrue(RequestHeaders.fromJSON("texto").isEmpty)
    }
}

final class EngineChooserTests: XCTestCase {
    private func pick(_ s: EngineSetting = .auto, kind: StreamKind = .other, ext: String = "", v: [String] = [], a: [String] = [], hevc: Bool = true, vp9: Bool = false, av1: Bool = false) -> PlaybackEngine {
        EngineChooser.choose(setting: s, facts: MediaFacts(kind: kind, fileExtension: ext, videoCodecs: v, audioCodecs: a, hardwareHevc: hevc, hardwareVp9: vp9, hardwareAv1: av1))
    }

    func testAjustesFuerzan() {
        XCTAssertEqual(pick(.vlc, kind: .hlsPlain, v: ["avc1.64002a"]), .vlc)
        XCTAssertEqual(pick(.avplayer, ext: "avi"), .avplayer)
    }

    func testManifiestosNormalesVanPorAVPlayer() {
        XCTAssertEqual(pick(kind: .hlsPlain, v: ["avc1.640020"], a: ["mp4a.40.2"]), .avplayer)
        XCTAssertEqual(pick(kind: .hlsEncrypted, v: ["avc1.64002a"], a: ["ec-3"]), .avplayer)
        XCTAssertEqual(pick(kind: .dash, v: ["hvc1.2.4.L150.90"], a: ["ec-3", "mp4a.40.2"]), .avplayer)
        XCTAssertEqual(pick(kind: .smooth, v: ["H264"], a: ["AACL"]), .avplayer)
    }

    func testCodecsSinHardwareVanPorVlc() {
        XCTAssertEqual(pick(kind: .dash, v: ["vp09.00.40.08"]), .vlc, "VP9 sin hardware")
        XCTAssertEqual(pick(kind: .dash, v: ["vp09.00.40.08"], vp9: true), .avplayer)
        XCTAssertEqual(pick(kind: .dash, v: ["av01.0.08M.08"]), .vlc)
        XCTAssertEqual(pick(kind: .dash, v: ["av01.0.08M.08"], av1: true), .avplayer)
        XCTAssertEqual(pick(kind: .hlsPlain, v: ["hvc1.1.6.L93.B0"], hevc: false), .vlc)
        XCTAssertEqual(pick(kind: .matroska, v: ["V_MPEG2"]), .vlc)
    }

    func testAudioSoloVlcSiNingunaPistaLaSuenaAVPlayer() {
        XCTAssertEqual(pick(kind: .hlsPlain, v: ["avc1.64002a"], a: ["dts", "ec-3"]), .avplayer, "con una pista válida basta")
        XCTAssertEqual(pick(kind: .matroska, ext: "mkv", v: ["V_MPEG4/ISO/AVC"], a: ["A_DTS"]), .vlc)
        XCTAssertEqual(pick(kind: .matroska, v: ["V_MPEG4/ISO/AVC"], a: ["A_TRUEHD"]), .vlc)
    }

    func testFicherosPorExtension() {
        for e in ["avi", "wmv", "flv", "ogv", "mpg", "vob", "rmvb", "divx", "mka", "flac", "opus", "wma", "m2ts"] { XCTAssertEqual(pick(ext: e), .vlc, e) }
        for e in ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "ts"] { XCTAssertEqual(pick(ext: e), .avplayer, e) }
        XCTAssertEqual(pick(ext: "xyz"), .vlc, "desconocida: VLC lo intenta")
        XCTAssertEqual(pick(ext: ""), .avplayer, "sin extensión (flujo sin nombre) se prueba AVPlayer")
        XCTAssertEqual(pick(ext: "mp4", v: ["avc1.64002a"], a: ["mp4a.40.2"]), .avplayer)
        XCTAssertEqual(pick(ext: "mp4", v: ["mp4v-20"]), .vlc, "MPEG-4 parte 2")
    }

    func testMkvH264ConAudioAacNoPideVlc() {
        XCTAssertFalse(EngineChooser.videoNeedsVlc("V_MPEG4/ISO/AVC", MediaFacts()))
        XCTAssertFalse(EngineChooser.videoNeedsVlc("V_MPEGH/ISO/HEVC", MediaFacts(hardwareHevc: true)))
        XCTAssertFalse(EngineChooser.videoNeedsVlc("V_MS/VFW/FOURCC", MediaFacts()), "desconocido: no se asume que falle")
        XCTAssertTrue(EngineChooser.videoNeedsVlc("V_MPEG4/ISO/ASP", MediaFacts()), "Xvid/DivX")
        XCTAssertFalse(EngineChooser.audioNeedsVlc("A_AAC"))
        XCTAssertFalse(EngineChooser.audioNeedsVlc("A_EAC3"))
        XCTAssertTrue(EngineChooser.audioNeedsVlc("A_OPUS"))
        XCTAssertTrue(EngineChooser.audioNeedsVlc("A_VORBIS"))
        XCTAssertTrue(EngineChooser.audioNeedsVlc("A_FLAC"))
    }

    func testFallbackSoloEnAutomatico() {
        XCTAssertEqual(EngineChooser.fallbackAfterFailure(setting: .auto, current: .avplayer), .vlc)
        XCTAssertNil(EngineChooser.fallbackAfterFailure(setting: .auto, current: .vlc))
        XCTAssertNil(EngineChooser.fallbackAfterFailure(setting: .avplayer, current: .avplayer))
        XCTAssertNil(EngineChooser.fallbackAfterFailure(setting: .vlc, current: .avplayer))
    }

    func testExtensionDeUrl() {
        XCTAssertEqual(EngineChooser.fileExtension(of: "https://h/p/Peli.AVI?token=a.b#x"), "avi")
        XCTAssertEqual(EngineChooser.fileExtension(of: "https://h/p/manifest"), "")
        XCTAssertEqual(EngineChooser.fileExtension(of: "https://h/p/video.m3u8"), "m3u8")
        XCTAssertEqual(EngineChooser.fileExtension(of: "https://h.com/stream"), "", "el dominio no es una extensión")
    }
}

/// Cabeceras de listas guardadas (compatibilidad con lo guardado antes) y de servidores externos.
final class StoredHeadersTests: XCTestCase {
    func testListaGuardadaAntesSinCabecerasSigueLeyendose() throws {
        let old = #"[{"id":"a","name":"Principal","url":"http://x/l.m3u","enabled":true}]"#
        let l = try JSONDecoder().decode([PlaylistConfig].self, from: Data(old.utf8))
        XCTAssertEqual(l.first?.extraHeaders, [:])
        XCTAssertEqual(l.first?.name, "Principal")
    }

    func testListaConCabecerasSeGuardaYSeLee() throws {
        let p = PlaylistConfig(name: "N", url: "http://x", extraHeaders: ["User-Agent": "AppleCoreMedia", "X-T": "1"])
        let back = try JSONDecoder().decode(PlaylistConfig.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    func testListaSinCampoEnabledQuedaActivada() throws {
        let l = try JSONDecoder().decode(PlaylistConfig.self, from: Data(#"{"id":"a","name":"n","url":"u"}"#.utf8))
        XCTAssertTrue(l.enabled)
    }

    func testCabecerasDeServidorSoloParaServidoresConocidos() {
        let d = UserDefaults.standard
        let saved = d.string(forKey: "set.serverHeaders"); defer { if let s = saved { d.set(s, forKey: "set.serverHeaders") } else { d.removeObject(forKey: "set.serverHeaders") } }
        ServerHeaders.text = "X-Proxy: abc\nUser-Agent: Mozilla/5.0 propio"
        XCTAssertEqual(ServerHeaders.extra.count, 2)
        XCTAssertTrue(ServerHeaders.forUrl("http://desconocido.example:9/v.mkv").isEmpty)
        ServerUa.remember("http://mi-emby.example:8096/emby")
        XCTAssertEqual(ServerHeaders.forUrl("http://mi-emby.example:8096/Videos/1/stream")["X-Proxy"], "abc")
        // Las propias mandan sobre el user agent que pone el cliente
        let h = ServerHeaders.applied(to: ["User-Agent": "cliente", "Accept": "application/json"])
        XCTAssertEqual(RequestHeaders.value(h, "User-Agent"), "Mozilla/5.0 propio")
        XCTAssertEqual(h["Accept"], "application/json")
        ServerHeaders.text = ""
        XCTAssertTrue(ServerHeaders.extra.isEmpty)
    }
}
