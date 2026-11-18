import XCTest
@testable import HLSCore

final class VariantFilterTests: XCTestCase {
    let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=640x360
    a.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=3000,RESOLUTION=1280x720
    b.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=6000,RESOLUTION=1920x1080
    c.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=18000,RESOLUTION=3840x2160
    d.m3u8
    """
    func testMinimo() {
        let o = VariantFilter.apply(master, minHeight: 1000, fixedHeight: 0)
        XCTAssertFalse(o.contains("a.m3u8")); XCTAssertFalse(o.contains("b.m3u8"))
        XCTAssertTrue(o.contains("c.m3u8")); XCTAssertTrue(o.contains("d.m3u8"))
    }
    func testMinimoMayorQueTodo() {
        let o = VariantFilter.apply(master, minHeight: 4000, fixedHeight: 0)      // solo queda la mejor disponible
        XCTAssertTrue(o.contains("d.m3u8")); XCTAssertFalse(o.contains("c.m3u8"))
    }
    func testFija() {
        let o = VariantFilter.apply(master, minHeight: 0, fixedHeight: 1200)
        XCTAssertTrue(o.contains("c.m3u8")); XCTAssertFalse(o.contains("b.m3u8")); XCTAssertFalse(o.contains("d.m3u8"))
    }
    func testSinFiltro() { XCTAssertEqual(VariantFilter.apply(master, minHeight: 0, fixedHeight: 0), master) }
}

final class AudioGroupTests: XCTestCase {
    func testDejaSoloElGrupo() {
        let m = ["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"a\"", "v1.m3u8", "#EXT-X-STREAM-INF:BANDWIDTH=2,AUDIO=\"b\"", "v2.m3u8", ""].joined(separator: "\n")
        let o = VariantFilter.audioGroup(m, group: "b")
        XCTAssertTrue(o.contains("v2.m3u8")); XCTAssertFalse(o.contains("v1.m3u8"))
        XCTAssertEqual(VariantFilter.audioGroup(m, group: "zz"), m)
        XCTAssertEqual(VariantFilter.audioGroup(m, group: nil), m)
    }
}

final class AutoAudioTests: XCTestCase {
    func testElegirElGrupoConMasPistas() {
        let m = ["#EXTM3U",
                 "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\",NAME=\"es\",URI=\"a1.m3u8\"",
                 "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"ec3\",NAME=\"es\",URI=\"b1.m3u8\"",
                 "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"ec3\",NAME=\"en\",URI=\"b2.m3u8\"",
                 "#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"avc1,mp4a.40.2\",AUDIO=\"aac\"", "v1.m3u8",
                 "#EXT-X-STREAM-INF:BANDWIDTH=2,CODECS=\"avc1,ec-3\",AUDIO=\"ec3\"", "v2.m3u8", ""].joined(separator: "\n")
        XCTAssertEqual(VariantFilter.autoAudioGroup(m), "ec3")
        XCTAssertNil(VariantFilter.autoAudioGroup("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"x\"\n"))
    }
    func testMinimoNoDejaSoloHdr() {
        let m = ["#EXTM3U",
                 "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x1080,VIDEO-RANGE=SDR", "sdr.m3u8",
                 "#EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=3840x2160,VIDEO-RANGE=PQ", "hdr.m3u8", ""].joined(separator: "\n")
        let o = VariantFilter.apply(m, minHeight: 1327, fixedHeight: 0)
        XCTAssertTrue(o.contains("sdr.m3u8")); XCTAssertTrue(o.contains("hdr.m3u8"))
    }
}

final class AudioLabelsTests: XCTestCase {
    func testEtiquetaCodecYCanales() {
        let m = ["#EXTM3U",
                 "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"ec3\",NAME=\"Español\",LANGUAGE=\"es\",CHANNELS=\"6\",URI=\"b1.m3u8\"",
                 "#EXT-X-STREAM-INF:BANDWIDTH=2,CODECS=\"avc1,ec-3\",AUDIO=\"ec3\"", "v2.m3u8", ""].joined(separator: "\n")
        let o = AudioLabels.annotate(m, preferLang: "es")
        XCTAssertTrue(o.contains("NAME=\"Español · E-AC-3 5.1\""))
        XCTAssertTrue(o.contains("LANGUAGE=\"es\""))      // el idioma se conserva: el reproductor lo usa para su menú
        XCTAssertTrue(o.contains("DEFAULT=YES"))
    }
}

final class VideoLabelsTests: XCTestCase {
    func testEtiquetas() {
        let m = ["#EXTM3U",
                 "#EXT-X-STREAM-INF:BANDWIDTH=15000000,RESOLUTION=3840x2160,CODECS=\"vp09.02.51.10.01.09.16.09.00,mp4a.40.2\"", "a.m3u8",
                 "#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,ec-3\"", "b.m3u8", ""].joined(separator: "\n")
        let v = VideoLabels.variants(m)
        XCTAssertEqual(v.map { $0.label }, ["2160p · VP9 · HDR10 (PQ) · 15.0 Mbps", "1080p · H.264 · 4.0 Mbps"])
    }
}

final class LanguageNamesTests: XCTestCase {
    func testNombreInternoSeTraduce() {
        let m = ["#EXTM3U",
                 "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"g\",NAME=\"es-ES a7\",LANGUAGE=\"es-ES\",CHANNELS=\"2\",URI=\"b1.m3u8\"",
                 "#EXT-X-STREAM-INF:BANDWIDTH=2,CODECS=\"avc1,ec-3\",AUDIO=\"g\"", "v2.m3u8", ""].joined(separator: "\n")
        let o = AudioLabels.annotate(m, preferLang: "es")
        XCTAssertFalse(o.contains("a7"))
        XCTAssertTrue(o.contains("E-AC-3 estéreo"))
        XCTAssertTrue(LanguageNames.looksInternal("ca-ES SDH"))
        XCTAssertFalse(LanguageNames.looksInternal("English [Audio Description]"))
    }
}
