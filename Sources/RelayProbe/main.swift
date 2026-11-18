import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HLSCore

// Prueba de extremo a extremo del relay con una URL real (HLS o MPD) y sus claves.
// Uso: RelayProbe <url> <claves.txt>
// Recorre: lista maestra → variante de vídeo y audio → inicio + primeros segmentos → comprueba el vídeo descifrado.

struct NetFetcher: Fetcher {
    func fetch(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil { req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent") }
        return try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code >= 400 { cont.resume(throwing: NSError(domain: "HTTP", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])); return }
                cont.resume(returning: data ?? Data())
            }.resume()
        }
    }
}

func valid(_ b: [UInt8]) -> (ok: Int, bad: Int) {
    var ok = 0, bad = 0
    for box in Cenc.boxes(b, from: 0, to: b.count) where box.type == "mdat" {
        var p = box.bodyStart
        while p + 5 < box.end {
            let len = Cenc.u32(b, p)
            if len <= 0 || p + 4 + len > box.end || b[p + 4] & 0x80 != 0 { bad += 1; break }
            ok += 1; p += 4 + len
        }
    }
    return (ok, bad)
}

let args = CommandLine.arguments
guard args.count == 3, let url = URL(string: args[1]),
      let keyText = try? String(contentsOfFile: args[2], encoding: .utf8) else { print("Uso: RelayProbe <url> <claves.txt>"); exit(2) }
let relay = RelayCore(relayBase: "http://127.0.0.1:1/s", fetcher: NetFetcher(), headers: [:], clearKeys: parseClearKeysHexMap(keyText))
relay.labelLang = "es"; relay.minHeight = 1327; if let g = ProcessInfo.processInfo.environment["AGROUP"] { relay.audioGroup = g }

func get(_ route: String) async -> RelayResponse {
    // route = http://127.0.0.1:1/s/kind?u=…  → solo la ruta
    let path = route.replacingOccurrences(of: "http://127.0.0.1:1/s", with: "")
    return await relay.handle(path: path)
}
func lines(_ r: RelayResponse) -> [String] { String(decoding: r.body, as: UTF8.self).components(separatedBy: "\n") }
func uri(_ l: String) -> String? { l.components(separatedBy: "URI=\"").dropFirst().first?.components(separatedBy: "\"").first }

var failed = false
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "  OK   " : "  FALLO"), name, detail); if !cond { failed = true }
}

let master = await get("http://127.0.0.1:1/s/m3u8?u=\(HlsRewriter.encode(url.absoluteString))")
check("lista maestra", master.status == 200, "HTTP \(master.status) \(master.status != 200 ? String(decoding: master.body, as: UTF8.self) : "")")
if ProcessInfo.processInfo.environment["DUMP"] != nil { print(String(decoding: master.body, as: UTF8.self)) }
let ml = lines(master)
let variants = zip(ml, ml.dropFirst()).filter { $0.0.hasPrefix("#EXT-X-STREAM-INF") }.map { ($0.0, $0.1) }
let audios = ml.filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }.compactMap(uri)
print("  variantes de vídeo:", variants.count, "| audios:", audios.count)

// Vídeo (la variante más pequeña) y primer audio
var targets: [(String, String)] = []
let pickMax = ProcessInfo.processInfo.environment["PICK"] == "max"
let bw: (String) -> Int = { Int($0.components(separatedBy: "BANDWIDTH=").last?.components(separatedBy: ",").first ?? "") ?? 0 }
if let v = (pickMax ? variants.max(by: { bw($0.0) < bw($1.0) }) : variants.min(by: { bw($0.0) < bw($1.0) })) {
    print("  variante elegida:", v.0.prefix(160)); targets.append(("vídeo", v.1)) }
if false, let v = variants.min(by: { (Int($0.0.components(separatedBy: "BANDWIDTH=").last?.components(separatedBy: ",").first ?? "") ?? 0) < (Int($1.0.components(separatedBy: "BANDWIDTH=").last?.components(separatedBy: ",").first ?? "") ?? 0) }) { targets.append(("vídeo", v.1)) }
if let a = audios.first { targets.append(("audio", a)) }

for (name, link) in targets {
    let pl = await get(link)
    check("lista \(name)", pl.status == 200, "HTTP \(pl.status) \(pl.status != 200 ? String(decoding: pl.body, as: UTF8.self) : "")")
    guard pl.status == 200 else { continue }
    let l = lines(pl)
    if ProcessInfo.processInfo.environment["DUMP"] != nil { print(l.prefix(14).map { String($0.prefix(150)) }.joined(separator: "\n")) }
    if let m = l.first(where: { $0.hasPrefix("#EXT-X-MAP") }), let u = uri(m) {
        let i = await get(u)
        let b = [UInt8](i.body)
        // Limpio = ya no hay cajas de cifrado activas (encv/enca/sinf/pssh pasan a «free»)
        let s = String(decoding: b, as: UTF8.self)
        let clean = !["encv", "enca", "sinf", "pssh"].contains { s.contains($0) }
        check("inicio \(name) limpio", i.status == 200 && clean, "bytes=\(b.count) status=\(i.status) entradas=\(["hev1","hvc1","avc1","avc3","dvh1","dvhe","ec-3","mp4a","enca","encv","frma"].filter { s.contains($0) }) cabecera=\(b.prefix(16).map { String(format: "%02x", $0) }.joined())")
    }
    let segs = l.filter { !$0.hasPrefix("#") && !$0.isEmpty }
    check("segmentos \(name)", !segs.isEmpty, "\(segs.count)")
    for s in segs.prefix(3) {
        let r = await get(s)
        if r.status != 200 { check("segmento \(name)", false, "HTTP \(r.status) " + String(decoding: r.body, as: UTF8.self)); continue }
        let b = [UInt8](r.body)
        if name == "vídeo" { let v = valid(b); check("segmento vídeo", v.bad == 0 && v.ok > 0, "NAL=\(v.ok) mal=\(v.bad)") }
        else { check("segmento audio descifrado", Cenc.boxes(b, from: 0, to: b.count).contains { $0.type == "moof" }, "bytes=\(b.count)") }
    }
}

// Subtítulos: primera pista de texto (SUB=nombre para elegir otra): lista y primer trozo
if let want = ProcessInfo.processInfo.environment["SUB"] {
    let subs = ml.filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") && $0.contains(want) }
    print("  subtítulos que coinciden:", subs.count)
    if let first = subs.first, let link = uri(first) {
        let pl = await get(link)
        print("  lista de subtítulos HTTP", pl.status); print(String(decoding: pl.body, as: UTF8.self).prefix(700))
        if let segLine = lines(pl).first(where: { !$0.hasPrefix("#") && !$0.isEmpty }) {
            let r = await get(segLine)
            print("  trozo de subtítulos HTTP", r.status, r.body.count, "bytes"); print(String(decoding: r.body.prefix(400), as: UTF8.self))
        }
    }
}
exit(failed ? 1 : 0)
