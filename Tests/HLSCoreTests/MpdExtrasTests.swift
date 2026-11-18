import XCTest
@testable import HLSCore

final class MpdExtrasTests: XCTestCase {
    func testFrameRateFraccionario() {
        XCTAssertEqual(MpdToHls.frameRateValue("24000/1001")!, 23.976, accuracy: 0.001)
        XCTAssertEqual(MpdToHls.frameRateValue("25")!, 25, accuracy: 0.001)
    }

    func testSubtitulosVttEnListaMaestra() throws {
        let mpd = """
        <MPD mediaPresentationDuration="PT762S" type="static"><Period>
        <AdaptationSet contentType="video"><Representation id="v0" codecs="avc1.64001e" width="640" height="360" bandwidth="500000" frameRate="24000/1001" mimeType="video/mp4"/></AdaptationSet>
        <AdaptationSet contentType="text" lang="es-ES"><Label>es-ES</Label>
          <Representation id="t1" bandwidth="29" mimeType="text/vtt"><SegmentTemplate media="t/t1/$Number$.vtt" startNumber="1" timescale="1000"><SegmentTimeline><S t="0" d="762428"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>
        </Period></MPD>
        """
        let base = URL(string: "https://x/y.mpd")!
        let master = try MpdToHls.convert(mpd, base: base, relay: "http://127.0.0.1:9/s1")
        XCTAssertTrue(master.contains("TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"es-ES\",LANGUAGE=\"es-ES\""))
        XCTAssertTrue(master.contains("SUBTITLES=\"subs\""))
        XCTAssertTrue(master.contains("FRAME-RATE=23.976"))
    }
}

final class MpdTrickModeTests: XCTestCase {
    func testPistaDeAvanceRapidoNoEntraComoVariante() throws {
        let mpd = """
        <MPD mediaPresentationDuration="PT60S" type="static"><Period>
        <AdaptationSet contentType="video" mimeType="video/mp4"><Representation id="v0" codecs="avc1.4d402a" width="1920" height="1080" bandwidth="8000000" frameRate="50"><SegmentTemplate media="$RepresentationID$-$Number$.m4s" initialization="$RepresentationID$-init.m4s" duration="360000" timescale="90000"/></Representation></AdaptationSet>
        <AdaptationSet contentType="video" mimeType="video/mp4"><SegmentTemplate timescale="90000" initialization="$RepresentationID$-initTrickMode.m4s" media="$RepresentationID$-i-TrickMode-$Number$.m4s" duration="540000"/><Representation id="v0_tm" codecs="avc1.4d402a" width="1920" height="1080" bandwidth="8000000" frameRate="1"/></AdaptationSet>
        </Period></MPD>
        """
        let out = try MpdToHls.convert(mpd, base: URL(string: "https://x/y.mpd")!, relay: "http://127.0.0.1:9/s1")
        XCTAssertEqual(out.components(separatedBy: "#EXT-X-STREAM-INF").count - 1, 1)
        XCTAssertFalse(out.contains("FRAME-RATE=1.000"))
    }
}
