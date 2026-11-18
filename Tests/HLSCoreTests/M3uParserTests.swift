import XCTest
@testable import HLSCore

final class M3uParserTests: XCTestCase {

    func testCanalSimpleConAtributos() {
        let r = M3uParser.parse("""
        #EXTM3U url-tvg="https://epg.example/guia.xml.gz"
        #EXTINF:-1 tvg-id="la1" tvg-logo="https://x/l.png" group-title="TDT",La 1
        https://example.com/la1.m3u8
        """)
        XCTAssertEqual(r.epgUrl, "https://epg.example/guia.xml.gz")
        XCTAssertEqual(r.channels.count, 1)
        XCTAssertEqual(r.channels[0].name, "La 1")
        XCTAssertEqual(r.channels[0].group, "TDT")
        XCTAssertEqual(r.channels[0].tvgId, "la1")
        XCTAssertEqual(r.channels[0].drmMode, .none)
    }

    func testClearKeyYCabeceras() {
        let r = M3uParser.parse("""
        #EXTM3U
        #EXTINF:-1,Canal DRM
        #KODIPROP:inputstream.adaptive.license_type=org.w3.clearkey
        #KODIPROP:inputstream.adaptive.license_key={303ecdee303ecdee303ecdee303ecdee:07121d8a07121d8a07121d8a07121d8a}
        #EXTVLCOPT:http-user-agent="VO Player"
        #EXTVLCOPT:http-referrer=https://ref.example/
        https://example.com/live.mpd
        """)
        let c = r.channels[0]
        XCTAssertEqual(c.drmMode, .clearkey)
        XCTAssertEqual(c.clearKeys["303ecdee303ecdee303ecdee303ecdee"], "07121d8a07121d8a07121d8a07121d8a")
        XCTAssertEqual(c.userAgent, "VO Player")
        XCTAssertEqual(c.referrer, "https://ref.example/")
        XCTAssertNotNil(c.clearKeyJson)
    }

    func testSublista() {
        let r = M3uParser.parse("""
        #EXTM3U
        #EXTINF:-1 type="playlist" group-title="Deportes",Deportes
        https://example.com/dep.m3u?dl=0
        """)
        XCTAssertTrue(r.channels[0].isPlaylistGroup)
        XCTAssertEqual(r.channels[0].nestedUrl, "https://example.com/dep.m3u?dl=1")
    }

    func testVodLibrary() {
        let r = M3uParser.parse("#EXTM3U vod_library=\"https://a/x,https://a/y\"\n")
        XCTAssertEqual(r.vodLibraries, ["https://a/x", "https://a/y"])
    }

    func testHexABase64Url() {
        XCTAssertEqual(KodiPropParser.hexToBase64Url("00ff"), "AP8")
    }
}
