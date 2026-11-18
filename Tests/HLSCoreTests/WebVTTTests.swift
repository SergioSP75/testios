import XCTest
@testable import HLSCore

final class WebVTTTests: XCTestCase {
    func testLeeTiemposYQuitaEtiquetas() {
        let v = "WEBVTT\n\n1\n00:00:01.500 --> 00:00:03.000 align:center\n<i>Hola</i> &amp; adiós\n\n00:01:00.000 --> 00:01:02.250\nDos\nlíneas\n"
        let c = WebVTT.parse(v)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0], SubtitleCue(start: 1.5, end: 3.0, text: "Hola & adiós"))
        XCTAssertEqual(c[1].start, 60); XCTAssertEqual(c[1].text, "Dos\nlíneas")
    }
    func testTextoEnUnInstante() {
        let c = WebVTT.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nA\n")
        XCTAssertEqual(WebVTT.text(at: 1.5, in: c), "A"); XCTAssertEqual(WebVTT.text(at: 2.0, in: c), "")
    }
    func testUneTrozos() {
        let m = WebVTT.merge(["WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n00:00:01.000 --> 00:00:02.000\nA\n", "WEBVTT\n\n00:00:10.000 --> 00:00:11.000\nB\n"])
        XCTAssertEqual(WebVTT.parse(m).map { $0.text }, ["A", "B"])
        XCTAssertEqual(m.components(separatedBy: "WEBVTT").count - 1, 1)
    }
}
