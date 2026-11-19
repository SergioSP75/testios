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

/// Listas anidadas: se prueban con listas simuladas (sin red).
final class SublistsTests: XCTestCase {
    private func run(_ root: String, _ files: [String: String], maxDepth: Int = 2) async -> [IptvChannel] {
        await Sublists.expand(M3uParser.parse(root).channels, maxDepth: maxDepth, fetch: { url in
            guard let t = files[url] else { throw URLError(.fileDoesNotExist) }
            return t
        })
    }

    func testCargaLosCanalesDeLaSublista() async {
        let c = await run("""
        #EXTM3U
        #EXTINF:-1 group-title="TDT",La 1
        https://a/la1.m3u8
        #EXTINF:-1 type="playlist" group-title="DAZN" tvg-logo="https://x/l.png",DAZN
        https://d/dazn.m3u?dl=0
        """, ["https://d/dazn.m3u?dl=1": """
        #EXTM3U
        #EXTINF:-1 group-title="Deportes",Eurosport 1
        #KODIPROP:inputstream.adaptive.license_type=org.w3.clearkey
        #KODIPROP:inputstream.adaptive.license_key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        https://d/e1.m3u8
        #EXTINF:-1,Sin grupo
        https://d/e2.m3u8
        """])
        XCTAssertEqual(c.map { $0.name }, ["La 1", "Eurosport 1", "Sin grupo"])
        XCTAssertFalse(c.contains { $0.isPlaylistGroup })
        XCTAssertEqual(c[1].group, "DAZN - Deportes")
        XCTAssertEqual(c[2].group, "DAZN")
        XCTAssertEqual(c[1].drmMode, .clearkey)            // conserva la clave de cada canal
        XCTAssertEqual(c[0].group, "TDT")
    }

    func testSublistaQueFallaNoTumbaElResto() async {
        let c = await run("""
        #EXTM3U
        #EXTINF:-1 type="playlist",Rota
        https://no/existe.m3u
        #EXTINF:-1 type="playlist",Buena
        https://ok/b.m3u
        """, ["https://ok/b.m3u": "#EXTM3U\n#EXTINF:-1,Canal B\nhttps://b/1.m3u8\n"])
        XCTAssertEqual(c.map { $0.name }, ["Canal B"])
        XCTAssertEqual(c[0].group, "Buena")
    }

    func testAnidadoDeDosNivelesYLimite() async {
        let files = [
            "https://n/1.m3u": "#EXTM3U\n#EXTINF:-1 type=\"playlist\",Nivel2\nhttps://n/2.m3u\n#EXTINF:-1,Uno\nhttps://c/1.m3u8\n",
            "https://n/2.m3u": "#EXTM3U\n#EXTINF:-1 type=\"playlist\",Nivel3\nhttps://n/3.m3u\n#EXTINF:-1,Dos\nhttps://c/2.m3u8\n",
            "https://n/3.m3u": "#EXTM3U\n#EXTINF:-1,Tres\nhttps://c/3.m3u8\n",
        ]
        let root = "#EXTM3U\n#EXTINF:-1 type=\"playlist\",Nivel1\nhttps://n/1.m3u\n"
        let dos = await run(root, files, maxDepth: 2)
        XCTAssertEqual(Set(dos.map { $0.name }), ["Uno", "Dos"])          // el tercer nivel se corta
        XCTAssertEqual(dos.first { $0.name == "Dos" }?.group, "Nivel1 - Nivel2")
        let uno = await run(root, files, maxDepth: 1)
        XCTAssertEqual(uno.map { $0.name }, ["Uno"])
    }

    func testSinSublistasDevuelveLoMismo() async {
        let c = await run("#EXTM3U\n#EXTINF:-1,A\nhttps://a/1.m3u8\n", [:])
        XCTAssertEqual(c.map { $0.name }, ["A"])
    }
}
