import XCTest
@testable import HLSCore

final class CatchupTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // futuro lejano respecto a los programas

    private func canal(source: String?, url: String = "https://tv.example/live/canal.m3u8") -> IptvChannel {
        IptvChannel(id: "1", name: "Canal", url: url, tvgId: "c1", catchup: "default", catchupSource: source)
    }
    // 2026-11-17 20:00:00 UTC → 21:00:00 UTC
    private let programa = EpgProgram(channelId: "c1", title: "Noticias", start: "20261117200000 +0000", stop: "20261117210000 +0000")

    func testFechaXmltv() {
        XCTAssertEqual(EpgTime.parseMillis("20261117200000 +0000"), 1_794_945_600_000)
        XCTAssertEqual(EpgTime.parseMillis("20261117210000 +0100"), 1_794_945_600_000)
        XCTAssertNil(EpgTime.parseMillis("basura"))
    }

    func testEtiquetasBasicas() {
        let r = CatchupUrlBuilder.build(channel: canal(source: "?begin=${start}&end=${end}&d=${duration}"),
                                        program: programa, now: now, timeZone: utc)
        XCTAssertTrue(r.allowed)
        XCTAssertEqual(r.url, "https://tv.example/live/canal.m3u8?begin=1794945600&end=1794949200&d=3600")
        XCTAssertNil(r.channel?.catchupSource, "el canal de catchup no debe volver a pedir catchup")
    }

    func testEtiquetasPorPartesOtt() {
        let r = CatchupUrlBuilder.build(
            channel: canal(source: "http://x/y?from=${start-year}-${start-mon}-${start-day}T${start-hour}:${start-min}:${start-sec}"),
            program: programa, now: now, timeZone: utc)
        XCTAssertEqual(r.url, "http://x/y?from=2026-11-17T20:00:00")
    }

    func testProgramaFuturoNoPermitido() {
        let r = CatchupUrlBuilder.build(channel: canal(source: "?a=${start}"), program: programa,
                                        now: Date(timeIntervalSince1970: 1_000_000_000), timeZone: utc)
        XCTAssertFalse(r.allowed)
    }

    func testPlantillaInferidaFlussonic() {
        var c = canal(source: nil); c.catchup = "flussonic"
        let r = CatchupUrlBuilder.build(channel: c, program: programa, now: now, timeZone: utc)
        XCTAssertEqual(r.url, "https://tv.example/live/canal.m3u8/timeshift_abs-1794945600.m3u8")
    }
}
