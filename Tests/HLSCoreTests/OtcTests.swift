import XCTest
@testable import HLSCore

final class OtcTests: XCTestCase {
    func testListaOtcBasica() {
        let json = """
        {"provider":{"epg":"https://epg.example/g.xml","archive_type":"flussonic","archive_days":3},
         "categories":{"1":{"name":"Deportes"}},
         "channels":[
          {"name":"Canal A","url":"https://a/x.m3u8","category":"1","number":2,"epg_id":"a","user_agent":"UA1",
           "drm_type":"clearkey","drm_key":"303ecdee303ecdee303ecdee303ecdee:07121d8a07121d8a07121d8a07121d8a"},
          {"name":"Canal B","url":"https://b/x.m3u8","number":1,"epg_shift":2},
          {"name":"Peli","url":"https://c","type":"movie"}]}
        """
        XCTAssertTrue(OtcParser.looksLikeOtc(json))
        let r = M3uParser.parse(json)
        XCTAssertEqual(r.epgUrl, "https://epg.example/g.xml")
        XCTAssertEqual(r.channels.map { $0.name }, ["Canal B", "Canal A"], "ordenado por number; movie omitida")
        XCTAssertEqual(r.channels[1].group, "Deportes")
        XCTAssertEqual(r.channels[1].userAgent, "UA1")
        XCTAssertEqual(r.channels[1].drmMode, .clearkey)
        XCTAssertEqual(r.channels[0].otc?.epgShiftSec, 7200)
        XCTAssertEqual(r.channels[0].catchup, "flussonic")
        XCTAssertEqual(r.meta["vod_omitidos"], "1")
    }
}
