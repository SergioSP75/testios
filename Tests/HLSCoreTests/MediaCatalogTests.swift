import XCTest
@testable import HLSCore

final class MediaCatalogTests: XCTestCase {
    func testListaEstiloDisneyYMax() {
        let json = """
        [{"name":"Peli A","video":"https://a/x.m3u8","drm":"clearkey",
          "drmkey":"{\\"fb122ff952b74377a69deb5883f2df2e\\":\\"3afe6cbc0a1d8c57692c3fcb57fb8a2f\\"}",
          "info":{"year":2020,"poster":"https://p/a.jpg","plot":"x"},"id":"1"},
         {"ID":"2","video":"https://m/y.mpd","category":{"name":"MAX"},"info":{"title":"Peli B","year":"1999"}},
         {"name":"sin video"}]
        """
        let items = MediaCatalog.parse(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].year, 2020)
        XCTAssertEqual(items[1].name, "Peli B")
        XCTAssertEqual(items[1].category, "MAX")
        XCTAssertEqual(items[1].year, 1999)
        let ch = items[0].asChannel
        XCTAssertEqual(ch.drmMode, .clearkey)
        XCTAssertEqual(ch.clearKeys["fb122ff952b74377a69deb5883f2df2e"], "3afe6cbc0a1d8c57692c3fcb57fb8a2f")
    }
}

final class MediaSeriesTests: XCTestCase {
    func testSerieConTemporadasYBiblioteca() {
        let json = """
        [{"name":"Serie X","category":"Series","info":{"year":"2023","genre":["Drama","Misterio"],"plot":"p","poster":"https://p/s.jpg","add":1681430460},
          "seasons":[{"season":1,"episodes":[
             {"episode":1,"name":"T1:E1 Piloto","video":"https://m/e1.mpd","drmkey":"{aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}","info":{"duration":3000}},
             {"episode":1,"name":"repetido","video":"https://m/e1b.mpd"},
             {"episode":2,"name":"Dos","video":"https://m/e2.mpd"}]},
            {"season":1,"episodes":[{"episode":3,"name":"Tres","video":"https://m/e3.mpd"}]}],},
         {"name":"Peli (2019)","category":"MAX","video":"https://m/p.mpd","info":{"genre":"Acción, Aventura","duration":4988442}}]
        """
        let items = MediaCatalog.parse(Data(json.utf8), sourceId: "L")      // con coma final: se repara
        XCTAssertEqual(items.count, 2)
        let s = items[0]
        XCTAssertTrue(s.isSeries)
        XCTAssertEqual(s.seasons.count, 1, "las temporadas con el mismo número se unen")
        XCTAssertEqual(s.seasons[0].episodes.map { $0.number }, [1, 2, 3])
        XCTAssertEqual(s.seasons[0].episodes[0].name, "Piloto")
        XCTAssertEqual(s.seasons[0].episodes[0].video, "https://m/e1.mpd", "se queda el primero de cada número")
        XCTAssertEqual(s.added, 1681430460)
        let ch = s.seasons[0].episodes[0].asChannel(series: s.name)
        XCTAssertEqual(ch.clearKeys["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let p = items[1]
        XCTAssertEqual(p.name, "Peli"); XCTAssertEqual(p.year, 2019); XCTAssertEqual(p.genres, ["Acción", "Aventura"])
        XCTAssertEqual(p.durationSec, 4988)
        let lib = MediaLibrary(items)
        XCTAssertEqual(lib.seriesCount, 1); XCTAssertEqual(lib.movieCount, 1)
        XCTAssertEqual(lib.filter(query: "accion").map { $0.name }, ["Peli"], "búsqueda sin tildes")
        XCTAssertEqual(lib.genres(series: false, platformKey: nil).map { $0.label }, ["Acción", "Aventura"])
    }
}
