import XCTest
@testable import HLSCore

/// Directo DASH (Orange/«abraham»): la lista de segmentos se desliza y MEDIA-SEQUENCE debe subir de forma coherente.
final class LiveMpdTests: XCTestCase {
    final class Fake: Fetcher {
        var xml = ""
        func fetch(_ url: URL, headers: [String: String]) async throws -> Data { Data(xml.utf8) }
    }

    /// MPD de directo con SegmentTimeline y duraciones desiguales (1,92 s y 2 s), como el de Orange.
    private func mpd(_ ts: [Int]) -> String {
        let s = ts.map { "<S t=\"\($0)\" d=\"180000\"/>" }.joined()
        return """
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic" availabilityStartTime="1970-01-01T00:00:00Z"><Period id="1" start="PT0S">
        <AdaptationSet contentType="video" mimeType="video/mp4"><SegmentTemplate timescale="90000" initialization="$RepresentationID$-init.m4s" media="$RepresentationID$-T-$Time$.m4s"><SegmentTimeline>\(s)</SegmentTimeline></SegmentTemplate>
        <Representation id="v1" bandwidth="800000" codecs="avc1.64001F" width="640" height="360"/></AdaptationSet></Period></MPD>
        """
    }

    private func seq(_ r: RelayResponse) -> Int {
        let t = String(decoding: r.body, as: UTF8.self)
        let l = t.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") } ?? ""
        return Int(l.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? -1
    }

    func testMediaSequenceSubeCoherente() async {
        let f = Fake()
        let relay = RelayCore(relayBase: "http://127.0.0.1:1/s", fetcher: f, headers: [:], clearKeys: [:])
        let path = "/mp?u=\(HlsRewriter.encode("http://cdn.example/x/dash.mpd"))&r=\(HlsRewriter.encode("v1"))"
        f.xml = mpd([1_000_000, 1_180_000, 1_360_000, 1_540_000])
        let a = await relay.handle(path: path)
        let text = String(decoding: a.body, as: UTF8.self)
        XCTAssertFalse(text.contains("#EXT-X-ENDLIST"), "un directo no termina")
        XCTAssertFalse(text.contains("PLAYLIST-TYPE:VOD"))
        let s0 = seq(a)
        // Se va el primer trozo y llega uno nuevo: el primero actual es el segundo de antes → +1
        f.xml = mpd([1_180_000, 1_360_000, 1_540_000, 1_720_000])
        let b = await relay.handle(path: path)
        XCTAssertEqual(seq(b), s0 + 1)
        // Se van dos y llegan dos
        f.xml = mpd([1_540_000, 1_720_000, 1_900_000, 2_080_000])
        let c = await relay.handle(path: path)
        XCTAssertEqual(seq(c), s0 + 3)
        // Misma lista otra vez: sin cambios
        let d = await relay.handle(path: path)
        XCTAssertEqual(seq(d), s0 + 3)
    }
}
