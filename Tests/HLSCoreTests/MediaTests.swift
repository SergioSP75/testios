import XCTest
@testable import HLSCore

/// Orden de la mediateca por varios criterios y línea de datos de cada ficha.
final class MediaSortTests: XCTestCase {
    private func library() -> MediaLibrary {
        let json = """
        [{"name":"Beta","video":"https://a/1.m3u8","info":{"year":2010,"rating":"7.5","duration":6000,"add":300}},
         {"name":"Alfa","video":"https://a/2.m3u8","info":{"year":2022,"rating":"9","duration":9000,"add":100}},
         {"name":"Gamma","video":"https://a/3.m3u8","info":{"rating":"5","duration":3000,"add":200}}]
        """
        return MediaLibrary(MediaCatalog.parse(Data(json.utf8)))
    }

    func testOrdenes() {
        let lib = library()
        XCTAssertEqual(lib.filter(sort: .name).map { $0.name }, ["Alfa", "Beta", "Gamma"])
        XCTAssertEqual(lib.filter(sort: .nameDesc).map { $0.name }, ["Gamma", "Beta", "Alfa"])
        XCTAssertEqual(lib.filter(sort: .year).map { $0.name }, ["Alfa", "Beta", "Gamma"])
        XCTAssertEqual(lib.filter(sort: .yearOldest).map { $0.name }, ["Beta", "Alfa", "Gamma"])   // sin año, al final
        XCTAssertEqual(lib.filter(sort: .rating).map { $0.name }, ["Alfa", "Beta", "Gamma"])
        XCTAssertEqual(lib.filter(sort: .duration).map { $0.name }, ["Alfa", "Beta", "Gamma"])
        XCTAssertEqual(lib.filter(sort: .added).map { $0.name }, ["Beta", "Gamma", "Alfa"])
        XCTAssertEqual(lib.filter(sort: .addedOldest).map { $0.name }, ["Alfa", "Gamma", "Beta"])
    }

    func testLineaDeDatos() {
        let it = library().filter(sort: .name)[0]
        XCTAssertTrue(MediaText.summary(it).hasPrefix("2022 · ★ 9"))
    }
}
