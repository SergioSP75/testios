import XCTest
@testable import HLSCore

/// Canales HLS con SAMPLE-AES declarado como FairPlay (skd://?contentId=…&keyId=…) que solo sirve a «AppleCoreMedia».
final class FairPlayUaTests: XCTestCase {
    private let kid = "dc4acc96-a938-51e8-8aa2-a4ffd45b43e3"
    private var media: String {
        "#EXTM3U\n#EXT-X-VERSION:5\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:7\n"
        + "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://?contentId=247Channel213_catchup&keyId=\(kid)\",KEYFORMAT=\"com.apple.streamingkeydelivery\",KEYFORMATVERSIONS=\"1\",IV=0xF8E75F3142340A039AD5F3EC824223B8\n"
        + "#EXTINF:2.0,\nv5_121_a.ts\n#EXTINF:2.0,\nv5_121_b.ts\n"
    }

    func testSkdEnFormaDeConsultaDaKeyId() {
        let i = HlsRewriter.skdInfo("skd://?contentId=abc&keyId=\(kid)")
        XCTAssertEqual(i?.kid, "dc4acc96a93851e88aa2a4ffd45b43e3")
        XCTAssertNil(i?.iv)                                              // el IV va en la etiqueta
    }

    func testReescrituraLlevaKidEIvDeLaEtiqueta() {
        let out = HlsRewriter.rewrite(media, base: URL(string: "https://cdn.example/hls/ch/v5-121.m3u8")!, relay: "http://127.0.0.1:1/s")
        XCTAssertFalse(out.contains("#EXT-X-KEY"), out)                  // la etiqueta DRM no llega al reproductor
        XCTAssertEqual(out.components(separatedBy: "&kid=dc4acc96a93851e88aa2a4ffd45b43e3&v=f8e75f3142340a039ad5f3ec824223b8").count - 1, 2, out)
    }

    func testSkdBase64SigueFuncionando() {
        let json = #"{"ContentId":"x","KeyId":"5720bb05-26b7-42ef-80a0-d3d0d6e3fcdd","IV":"klfJay9PhVyZ+FDvbIOmEw=="}"#
        let skd = "skd://" + Data(json.utf8).base64EncodedString()
        XCTAssertEqual(HlsRewriter.skdInfo(skd)?.kid, "5720bb0526b742ef80a0d3d0d6e3fcdd")
        XCTAssertEqual(HlsRewriter.skdInfo(skd)?.iv, "9257c96b2f4f855c99f850ef6c83a613")
    }

    /// La lista real de DAZN: user agent con espacio delante, manifest_type=fairplay y clave ClearKey kid:clave.
    func testListaDaznLeeUserAgentYClave() {
        let r = M3uParser.parse("""
        #EXTM3U

        #EXTINF:-1 tvg-id="Eurosport 1" tvg-name="Eurosport 1" group-title="DAZN",Eurosport 1
        #KODIPROP:inputstream.adaptive.manifest_type=fairplay
        #KODIPROP:inputstream.adaptive.license_type=org.w3.clearkey
        #EXTVLCOPT:http-user-agent= AppleCoreMedia
        #KODIPROP:inputstream.adaptive.license_key=dc4acc96a93851e88aa2a4ffd45b43e3:f075d98499594bbc72b675eecf6833b7
        https://dct-ak-livedazn.akamaized.net/hls/dazn-linear-213/stream.m3u8?p=web
        """)
        XCTAssertEqual(r.channels.count, 1)
        let c = r.channels[0]
        XCTAssertEqual(c.userAgent?.trimmingCharacters(in: .whitespaces), "AppleCoreMedia")
        XCTAssertEqual(c.clearKeys["dc4acc96a93851e88aa2a4ffd45b43e3"], "f075d98499594bbc72b675eecf6833b7")
        XCTAssertEqual(c.url, "https://dct-ak-livedazn.akamaized.net/hls/dazn-linear-213/stream.m3u8?p=web")
    }

    func testUaNativoSoloSiLaListaNoLoFija() {
        XCTAssertTrue(PlayerUa.applying(to: [:])["User-Agent"]!.hasPrefix("AppleCoreMedia"))
        XCTAssertEqual(PlayerUa.applying(to: ["User-Agent": "VO Player"])["User-Agent"], "VO Player")
        XCTAssertEqual(PlayerUa.applying(to: ["user-agent": "VO Player"])["user-agent"], "VO Player")
        XCTAssertTrue(PlayerUa.applying(to: ["User-Agent": "  "])["User-Agent"]!.hasPrefix("AppleCoreMedia"))
        XCTAssertEqual(PlayerUa.applying(to: ["Referer": "https://r/"])["Referer"], "https://r/")
    }

    /// Origen simulado como el CDN real: 401 «Forbidden-667» salvo que el cliente se anuncie como AppleCoreMedia.
    private final class StrictCdn: Fetcher, @unchecked Sendable {
        var seen: [String] = []
        let playlist: String
        init(_ playlist: String) { self.playlist = playlist }
        func fetch(_ url: URL, headers: [String: String]) async throws -> Data {
            let ua = headers["User-Agent"] ?? "(ninguno)"
            seen.append(ua)
            guard ua.hasPrefix("AppleCoreMedia") else { throw NSError(domain: "HTTP", code: 401, userInfo: [NSLocalizedDescriptionKey: "HTTP 401 Forbidden-667"]) }
            return url.pathExtension == "m3u8" ? Data(playlist.utf8) : Data(repeating: 0x47, count: 188)
        }
    }

    func testRelayPideListaYSegmentosConUaNativo() async {
        let cdn = StrictCdn(media)
        let relay = RelayCore(relayBase: "http://127.0.0.1:1/s", fetcher: cdn, headers: [:], clearKeys: ["dc4acc96a93851e88aa2a4ffd45b43e3": "f075d98499594bbc72b675eecf6833b7"])
        let pl = await relay.handle(path: "/m3u8?u=\(HlsRewriter.encode("https://cdn.example/hls/ch/v5-121.m3u8"))")
        XCTAssertEqual(pl.status, 200, String(decoding: pl.body, as: UTF8.self))
        XCTAssertTrue(cdn.seen.allSatisfy { $0.hasPrefix("AppleCoreMedia") }, "\(cdn.seen)")
        // Y un User-Agent propio de la lista se respeta
        let cdn2 = StrictCdn(media)
        let r2 = RelayCore(relayBase: "http://127.0.0.1:1/s", fetcher: cdn2, headers: ["User-Agent": "VO Player"], clearKeys: [:])
        let bad = await r2.handle(path: "/m3u8?u=\(HlsRewriter.encode("https://cdn.example/hls/ch/v5-121.m3u8"))")
        XCTAssertEqual(cdn2.seen.first, "VO Player")
        XCTAssertGreaterThanOrEqual(bad.status, 400)                     // el CDN simulado lo rechaza: el relay no lo disfraza
    }
}
