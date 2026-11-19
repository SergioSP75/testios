import XCTest
@testable import HLSCore

final class EpgTests: XCTestCase {
    private let xml = """
    <?xml version="1.0"?><tv>
     <channel id="La1.es"><display-name>La 1 HD</display-name><icon src="https://i/la1.png"/></channel>
     <channel id="Antena3.es"><display-name>Antena 3</display-name></channel>
     <programme start="20261117200000 +0000" stop="20261117210000 +0000" channel="La1.es">
       <title>Telediario</title><desc>Noticias del día</desc><icon src="https://i/td.jpg"/></programme>
     <programme start="20261117210000 +0000" stop="20261117220000 +0000" channel="La1.es"><title>Cine</title></programme>
     <programme start="20261117200000 +0000" stop="20261117210000 +0000" channel="Antena3.es"><title>Noticias</title></programme>
     <programme start="20200101000000 +0000" stop="20200101010000 +0000" channel="La1.es"><title>Antiguo</title></programme>
    </tv>
    """

    private let t0: Int64 = 1_794_945_600_000   // 2026-11-17 20:00 UTC

    func testLecturaConVentana() {
        let store = EpgStore()
        let st = store.load(xml: Data(xml.utf8), windowStartMs: t0 - 3_600_000, windowEndMs: t0 + 86_400_000)
        XCTAssertEqual(st.channels, 2)
        XCTAssertEqual(st.accepted, 3)
        XCTAssertEqual(st.skippedByDate, 1, "el programa de 2020 queda fuera de la ventana")
        XCTAssertEqual(store.channels["La1.es"]?.icon, "https://i/la1.png")
    }

    func testEmparejadoPorNombreYDifuso() {
        let store = EpgStore()
        store.load(xml: Data(xml.utf8), windowStartMs: 0, windowEndMs: .max)
        XCTAssertEqual(store.resolve(IptvChannel(id: "1", name: "x", url: "u", tvgId: "La1.es")), "La1.es")
        XCTAssertEqual(store.resolve(IptvChannel(id: "2", name: "La 1", url: "u")), "La1.es", "por nombre normalizado (HD fuera)")
        XCTAssertEqual(store.resolve(IptvChannel(id: "3", name: "ANTENA 3 HD", url: "u")), "Antena3.es")
        XCTAssertNil(store.resolve(IptvChannel(id: "4", name: "Canal Inexistente XYZ", url: "u")))
    }

    func testProgramaActualYRango() {
        let store = EpgStore()
        store.load(xml: Data(xml.utf8), windowStartMs: 0, windowEndMs: .max)
        let ch = IptvChannel(id: "1", name: "La 1", url: "u", tvgId: "La1.es")
        XCTAssertEqual(store.current(for: ch, now: t0 + 60_000)?.title, "Telediario")
        XCTAssertEqual(store.current(for: ch, now: t0 + 3_700_000)?.title, "Cine")
        XCTAssertEqual(store.programs(for: ch, from: t0, to: t0 + 7_200_000).map { $0.title }, ["Telediario", "Cine"])
        XCTAssertEqual(store.search("noticias").count, 1 + 0, "solo coincide el título «Noticias» (la descripción no cuenta)")
    }

    func testSlotsYCanalesConGuia() {
        let store = EpgStore()
        store.load(xml: Data(xml.utf8), windowStartMs: 0, windowEndMs: .max)
        let ch = IptvChannel(id: "1", name: "La 1", url: "u", tvgId: "La1.es")
        let s = store.slots(for: ch, from: t0, to: t0 + 7_200_000)
        XCTAssertEqual(s.map { $0.program.title }, ["Telediario", "Cine"])
        XCTAssertEqual(s[0].start, t0); XCTAssertEqual(s[0].stop, t0 + 3_600_000)
        XCTAssertTrue(store.hasPrograms(for: ch))
        XCTAssertFalse(store.hasPrograms(for: IptvChannel(id: "9", name: "Nada XYZ", url: "u")))
        // El desfase de la lista (epg_shift) mueve los programas
        var shifted = ch; shifted.otc = OtcChannelOpts(); shifted.otc?.epgShiftSec = 3600
        XCTAssertEqual(store.slots(for: shifted, from: t0, to: t0 + 1_000).count, 0, "con +1 h el Telediario empieza a las 21:00")
    }

    func testFuzzyNormaliza() {
        XCTAssertEqual(FuzzyMatcher.normalize("Antena 3 HD"), "antena 3")
        XCTAssertEqual(FuzzyMatcher.score("antena 3", "antena 3"), 1.0)
        XCTAssertEqual(FuzzyMatcher.score(FuzzyMatcher.normalize("Cuatro TV"), FuzzyMatcher.normalize("cuatro")), 1.0)
        XCTAssertGreaterThan(FuzzyMatcher.score("telecinco 2", "telecinco"), 0.9)
    }

    // MARK: - Caché en disco

    func testCopiaGuardadaYRestauradaDaLoMismo() throws {
        let a = EpgStore()
        a.load(xml: Data(xml.utf8), windowStartMs: 0, windowEndMs: .max)
        let data = try XCTUnwrap(a.snapshot(signature: "3|7", windowStartMs: 0, windowEndMs: 99, nowMs: 1234))
        let b = EpgStore()
        let meta = try XCTUnwrap(b.restore(data))
        XCTAssertEqual(meta, EpgStore.SnapshotMeta(savedAtMs: 1234, signature: "3|7", windowStartMs: 0, windowEndMs: 99))
        let ch = IptvChannel(id: "1", name: "La 1", url: "u", tvgId: "La1.es")
        XCTAssertEqual(b.current(for: ch, now: t0 + 60_000)?.title, "Telediario")
        XCTAssertEqual(b.current(for: ch, now: t0 + 60_000)?.icon, "https://i/td.jpg", "el póster viaja en la copia")
        XCTAssertEqual(b.programs(for: ch, from: t0, to: t0 + 7_200_000).map { $0.title }, ["Telediario", "Cine"])
        XCTAssertEqual(b.icon(for: ch), "https://i/la1.png")
        XCTAssertEqual(b.resolve(IptvChannel(id: "3", name: "ANTENA 3 HD", url: "u")), "Antena3.es", "el emparejado por nombre sigue funcionando")
        XCTAssertEqual(b.search("noticias").count, 1)
    }

    func testCopiaEstropeadaONuevaVersionNoToca() throws {
        let a = EpgStore()
        a.load(xml: Data(xml.utf8), windowStartMs: 0, windowEndMs: .max)
        let b = EpgStore()
        XCTAssertNil(b.restore(Data("esto no es json".utf8)))
        XCTAssertNil(b.restore(Data(#"{"version":99,"meta":{"savedAtMs":0,"signature":"","windowStartMs":0,"windowEndMs":0},"channels":[],"programs":{}}"#.utf8)))
        XCTAssertTrue(b.channels.isEmpty, "una copia mala no deja la guía a medias")
        // y una restauración correcta sobre una guía ya cargada la sustituye entera
        let data = try XCTUnwrap(a.snapshot(signature: "x", windowStartMs: 0, windowEndMs: 1))
        let c = EpgStore()
        c.load(xml: Data("<tv><channel id=\"Otro\"/></tv>".utf8), windowStartMs: 0, windowEndMs: .max)
        XCTAssertNotNil(c.restore(data))
        XCTAssertNotNil(c.channels["La1.es"]); XCTAssertNil(c.channels["Otro"])
    }

    func testCopiaVaciaEsValida() throws {
        let a = EpgStore()
        let data = try XCTUnwrap(a.snapshot(signature: "0", windowStartMs: 0, windowEndMs: 0))
        XCTAssertNotNil(EpgStore().restore(data))
    }
}
