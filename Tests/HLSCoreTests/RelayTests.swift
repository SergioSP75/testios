import XCTest
@testable import HLSCore

final class RelayTests: XCTestCase {

    func testCodificarYDecodificarUrl() {
        let u = "https://a.example/x/y.m3u8?token=a+b/c==&z=1"
        XCTAssertEqual(HlsRewriter.decode(HlsRewriter.encode(u)), u)
    }

    func testReescrituraDeListaDeSegmentos() {
        let base = URL(string: "https://cdn.example/v/index.m3u8")!
        let src = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES-CTR,KEYFORMAT="urn:uuid:x",URI="data:text/plain;base64,AAAA"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        seg1.m4s
        """
        let out = HlsRewriter.rewrite(src, base: base, relay: "http://127.0.0.1:9/s1")
        XCTAssertFalse(out.contains("SAMPLE-AES"), "la clave DRM debe quitarse")
        XCTAssertTrue(out.contains("http://127.0.0.1:9/s1/init?u="))
        XCTAssertTrue(out.contains("http://127.0.0.1:9/s1/seg?u="))
        // El segmento lleva la dirección absoluta de su inicio
        let initEnc = HlsRewriter.encode("https://cdn.example/v/init.mp4")
        XCTAssertTrue(out.contains("&i=\(initEnc)"))
    }

    func testReescrituraDeListaMaestra() {
        let base = URL(string: "https://cdn.example/m.m3u8")!
        let src = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"aud.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nv/720.m3u8\n"
        let out = HlsRewriter.rewrite(src, base: base, relay: "http://127.0.0.1:9/s1")
        XCTAssertEqual(out.components(separatedBy: "/s1/m3u8?u=").count - 1, 2)
    }

    func testSnifferPorContenido() {
        XCTAssertEqual(StreamSniffer.kind(ofManifest: "<?xml?><MPD xmlns=\"x\">"), .dash)
        XCTAssertEqual(StreamSniffer.kind(ofManifest: "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR"), .hlsEncrypted)
        XCTAssertEqual(StreamSniffer.kind(ofManifest: "#EXTM3U\n#EXTINF:4,\na.ts"), .hlsPlain)
        XCTAssertTrue(StreamSniffer.needsRelay(kind: .dash, hasClearKeys: false))
        XCTAssertFalse(StreamSniffer.needsRelay(kind: .hlsPlain, hasClearKeys: false))
    }

    func testMpdAListaMaestra() throws {
        let mpd = """
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT20S"><Period>
         <AdaptationSet contentType="audio" lang="es"><Representation id="a1" codecs="ec-3" bandwidth="128000"/></AdaptationSet>
         <AdaptationSet contentType="video"><Representation id="v1" codecs="avc1.64001f" bandwidth="900000" width="1280" height="720"/></AdaptationSet>
        </Period></MPD>
        """
        let out = try MpdToHls.convert(mpd, base: URL(string: "https://x/y.mpd")!, relay: "http://127.0.0.1:9/s1")
        XCTAssertTrue(out.contains("RESOLUTION=1280x720"))
        XCTAssertTrue(out.contains("CODECS=\"avc1.64001f,ec-3\""))
        XCTAssertTrue(out.contains("AUDIO=\"aud-ec3\""))
    }

    func testMpdPlantillaConTimeline() async throws {
        let mpd = """
        <MPD mediaPresentationDuration="PT12S"><Period><AdaptationSet contentType="video">
         <SegmentTemplate timescale="1000" initialization="$RepresentationID$/init.mp4" media="$RepresentationID$/$Time$.m4s">
          <SegmentTimeline><S t="0" d="4000" r="2"/></SegmentTimeline></SegmentTemplate>
         <Representation id="v1" bandwidth="1000"/></AdaptationSet></Period></MPD>
        """
        let out = try await MpdToHls.mediaPlaylist(mpd, base: URL(string: "https://x/base/y.mpd")!, repId: "v1",
                                                   relay: "http://127.0.0.1:9/s1") { _, _, _ in Data() }
        XCTAssertEqual(out.components(separatedBy: "#EXTINF").count - 1, 3)
        XCTAssertTrue(out.contains("#EXT-X-ENDLIST"))
        XCTAssertTrue(out.contains(HlsRewriter.encode("https://x/base/v1/4000.m4s")))
    }
}
