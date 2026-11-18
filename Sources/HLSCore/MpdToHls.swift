import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// AVPlayer no reproduce DASH (MPD). Este conversor lo presenta como HLS al relay local:
///  - `convert` → lista maestra HLS (vídeo, audios, variantes) a partir del MPD.
///  - `mediaPlaylist` → lista de segmentos de una Representation (necesita leer el `sidx` si el MPD usa SegmentBase).
/// Se decide por la estructura del MPD, nunca por el nombre del proveedor.
public enum MpdToHls {

    // MARK: - Árbol XML mínimo

    final class Node {
        let name: String                    // sin prefijo de espacio de nombres (cenc:pssh → pssh)
        var attrs: [String: String] = [:]
        var children: [Node] = []
        var text = ""
        weak var parent: Node?
        init(name: String) { self.name = name }
        func child(_ n: String) -> Node? { children.first { $0.name == n } }
        func all(_ n: String) -> [Node] { children.filter { $0.name == n } }
        /// Atributo propio o, si falta, del padre (Representation → AdaptationSet → Period).
        func inherited(_ k: String) -> String? { attrs[k] ?? parent?.inherited(k) }
        /// Primer hijo con ese nombre, subiendo por los padres.
        func inheritedChild(_ n: String) -> Node? { child(n) ?? parent?.inheritedChild(n) }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            let n = Node(name: name.split(separator: ":").last.map(String.init) ?? name)
            for (k, v) in a { n.attrs[k.split(separator: ":").last.map(String.init) ?? k] = v }
            if let top = stack.last { n.parent = top; top.children.append(n) } else { root = n }
            stack.append(n)
        }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
        func parser(_ p: XMLParser, foundCharacters s: String) { stack.last?.text += s }
    }

    static func parse(_ xml: String) throws -> Node {
        let p = XMLParser(data: Data(xml.utf8)); let b = Builder(); p.delegate = b
        guard p.parse(), let r = b.root else {
            throw NSError(domain: "MpdToHls", code: 1, userInfo: [NSLocalizedDescriptionKey: "MPD no válido"])
        }
        return r
    }

    // MARK: - Utilidades

    /// Duración ISO-8601 («PT1H2M3.5S») → segundos.
    static func seconds(_ iso: String?) -> Double {
        guard let s = iso, s.hasPrefix("P") else { return 0 }
        var total = 0.0, num = "", inTime = false
        for c in s.dropFirst() {
            if c == "T" { inTime = true; continue }
            if c.isNumber || c == "." { num.append(c); continue }
            let v = Double(num) ?? 0; num = ""
            switch (c, inTime) {
            case ("D", _): total += v * 86400
            case ("H", true): total += v * 3600
            case ("M", true): total += v * 60
            case ("S", true): total += v
            default: break
            }
        }
        return total
    }

    /// «24000/1001» → 23.976; «25» → 25. (Antes «24000/1001» salía como 24000001 y AVPlayer rechazaba la lista: error -12927.)
    static func frameRateValue(_ s: String) -> Double? {
        let p = s.split(separator: "/").compactMap { Double($0) }
        if p.count == 2, p[1] > 0 { return p[0] / p[1] }
        return p.count == 1 ? p[0] : nil
    }

    /// Pistas de avance rápido («trick mode»: solo fotogramas clave, 1 imagen por segundo). No son vídeo normal:
    /// si entran como variantes, AVPlayer las elige por tener poco ancho de banda y la película va a saltos o falla.
    static func isTrickMode(_ set: Node) -> Bool {
        for p in set.children where p.name == "EssentialProperty" || p.name == "SupplementalProperty" {
            if (p.attrs["schemeIdUri"] ?? "").lowercased().contains("trickmode") { return true }
        }
        if let st = set.child("SegmentTemplate") ?? set.child("Representation")?.child("SegmentTemplate") {
            if ((st.attrs["media"] ?? "") + (st.attrs["initialization"] ?? "")).lowercased().contains("trickmode") { return true }
        }
        if let id = set.child("Representation")?.attrs["id"], id.hasSuffix("_tm") { return true }
        return false
    }

    static func kind(_ set: Node, _ rep: Node?) -> String {
        let ct = set.attrs["contentType"] ?? ""
        if !ct.isEmpty { return ct }
        let mime = rep?.attrs["mimeType"] ?? set.attrs["mimeType"] ?? ""
        return String(mime.split(separator: "/").first ?? "")
    }

    static func baseUrl(_ n: Node, _ base: URL) -> URL {
        var url = base
        var chain: [Node] = []; var c: Node? = n
        while let x = c { chain.insert(x, at: 0); c = x.parent }
        for x in chain { if let b = x.child("BaseURL")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty,
                            let u = URL(string: b, relativeTo: url) { url = u.absoluteURL } }
        return url
    }

    // MARK: - Lista maestra

    public static func convert(_ xml: String, base: URL, relay: String) throws -> String {
        let mpd = try parse(xml)
        guard let period = mpd.child("Period") else { throw NSError(domain: "MpdToHls", code: 2, userInfo: [NSLocalizedDescriptionKey: "MPD sin Period"]) }
        func playlistUrl(_ rep: Node) -> String {
            "\(relay)/mp?u=\(HlsRewriter.encode(base.absoluteString))&r=\(HlsRewriter.encode(rep.attrs["id"] ?? ""))"
        }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-INDEPENDENT-SEGMENTS"]
        // Audios: uno por AdaptationSet (la Representation de mayor ancho de banda).
        // AVPlayer exige un solo códec por grupo: se hace un grupo por familia (aac, ec-3…) y cada vídeo se ofrece con cada uno.
        struct AudioEntry { var line: String; var group: String; var codec: String }
        var audios: [AudioEntry] = []
        var firstOfGroup = Set<String>()
        func family(_ c: String) -> String {
            let l = c.lowercased()
            return l.hasPrefix("ec-3") ? "ec3" : l.hasPrefix("ac-3") ? "ac3" : l.hasPrefix("mp4a") ? "aac" : l.hasPrefix("opus") ? "opus" : "otro"
        }
        for set in period.all("AdaptationSet") where kind(set, set.child("Representation")) == "audio" {
            let reps = set.all("Representation")
            guard let rep = reps.max(by: { (Int($0.attrs["bandwidth"] ?? "") ?? 0) < (Int($1.attrs["bandwidth"] ?? "") ?? 0) }) else { continue }
            let lang = set.attrs["lang"] ?? "und"
            let codec = rep.inherited("codecs") ?? ""
            let group = "aud-" + family(codec)
            let ch = rep.child("AudioChannelConfiguration")?.attrs["value"] ?? set.child("AudioChannelConfiguration")?.attrs["value"]
            var l = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"\(group)\",NAME=\"\(lang) \(rep.attrs["id"] ?? "")\",LANGUAGE=\"\(lang)\""
            l += ",DEFAULT=\(firstOfGroup.insert(group).inserted ? "YES" : "NO"),AUTOSELECT=YES"
            if let c = ch, Int(c) != nil { l += ",CHANNELS=\"\(c)\"" }
            l += ",URI=\"\(playlistUrl(rep))\""
            audios.append(AudioEntry(line: l, group: group, codec: codec))
        }
        lines += audios.map { $0.line }

        // Subtítulos: un EXT-X-MEDIA por idioma (VTT o TTML sueltos)
        var subCount = 0
        var usedNames = Set<String>()
        for set in period.all("AdaptationSet") where kind(set, set.child("Representation")) == "text" {
            guard let rep = set.child("Representation") else { continue }
            let mime = rep.attrs["mimeType"] ?? set.attrs["mimeType"] ?? ""
            guard mime.contains("vtt") || mime.contains("ttml") || mime.contains("xml") else { continue }
            let lang = set.attrs["lang"] ?? "und"
            var name = set.child("Label")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? lang
            if name.isEmpty { name = lang }
            if !usedNames.insert(name).inserted { name += " (\(rep.attrs["id"] ?? "\(subCount)"))" }
            usedNames.insert(name)
            lines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(name)\",LANGUAGE=\"\(lang)\",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI=\"\(playlistUrl(rep))\"")
            subCount += 1
        }
        // Un grupo por familia, con el códec que lo representa
        var groups: [(id: String, codec: String)] = []
        for a in audios where !groups.contains(where: { $0.id == a.group }) { groups.append((a.group, a.codec)) }

        // Vídeo: una variante por Representation (y por grupo de audio)
        for set in period.all("AdaptationSet") where kind(set, set.child("Representation")) == "video" && !isTrickMode(set) {
            for rep in set.all("Representation") {
                var l = "#EXT-X-STREAM-INF:BANDWIDTH=\(rep.attrs["bandwidth"] ?? "1000000")"
                if let w = rep.attrs["width"] ?? set.attrs["width"], let h = rep.attrs["height"] ?? set.attrs["height"] {
                    l += ",RESOLUTION=\(w)x\(h)"
                }
                if let fr = rep.attrs["frameRate"] ?? set.attrs["frameRate"], let d = frameRateValue(fr) {
                    l += ",FRAME-RATE=\(String(format: "%.3f", d))"
                }
                for g in (groups.isEmpty ? [nil] : groups.map { Optional($0) }) {
                    var codecs = [rep.inherited("codecs")].compactMap { $0 }
                    if let g = g, !g.codec.isEmpty { codecs.append(g.codec) }
                    var v = l
                    if !codecs.isEmpty { v += ",CODECS=\"\(codecs.joined(separator: ","))\"" }
                    if let g = g { v += ",AUDIO=\"\(g.id)\"" }
                    if subCount > 0 { v += ",SUBTITLES=\"subs\"" }
                    lines.append(v); lines.append(playlistUrl(rep))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Lista de una Representation

    /// Lo que necesita saber el relay para pedir los datos: lectura de un rango de un fichero.
    public typealias RangeFetch = (_ url: URL, _ start: Int, _ end: Int) async throws -> Data

    public static func mediaPlaylist(_ xml: String, base: URL, repId: String, relay: String,
                                     liveSequence: (([Int]) -> Int)? = nil,
                                     readRange: RangeFetch) async throws -> String {
        let mpd = try parse(xml)
        guard let period = mpd.child("Period") else { throw NSError(domain: "MpdToHls", code: 2) }
        var found: (Node, Node)?
        for set in period.all("AdaptationSet") {
            if let r = set.all("Representation").first(where: { $0.attrs["id"] == repId }) { found = (set, r); break }
        }
        guard let (set, rep) = found else {
            throw NSError(domain: "MpdToHls", code: 3, userInfo: [NSLocalizedDescriptionKey: "Representation \(repId) no existe"])
        }
        let totalDur = seconds(period.attrs["duration"]) > 0 ? seconds(period.attrs["duration"]) : seconds(mpd.attrs["mediaPresentationDuration"])
        let bu = baseUrl(rep, base)
        func enc(_ s: String) -> String { HlsRewriter.encode(s) }
        func initRoute(_ u: URL, _ range: (Int, Int)?) -> String {
            "\(relay)/init?u=\(enc(u.absoluteString))" + (range.map { "&r=\($0.0)-\($0.1)" } ?? "")
        }
        func segRoute(_ u: URL, _ range: (Int, Int)?, initUrl: String) -> String {
            "\(relay)/seg?u=\(enc(u.absoluteString))" + (range.map { "&r=\($0.0)-\($0.1)" } ?? "") + "&i=\(enc(initUrl))"
        }
        func rangeOf(_ s: String?) -> (Int, Int)? {
            guard let p = s?.split(separator: "-"), p.count == 2, let a = Int(p[0]), let b = Int(p[1]) else { return nil }
            return (a, b)
        }

        var entries: [(dur: Double, url: String)] = []
        var mapLine = ""

        if let sb = rep.inheritedChild("SegmentBase"), let idx = rangeOf(sb.attrs["indexRange"]) {
            // MPD «on-demand»: un solo fichero con índice sidx; cada segmento es un rango de bytes
            let initRange = rangeOf(sb.child("Initialization")?.attrs["range"])
            let initKey = bu.absoluteString + (initRange.map { "|\($0.0)-\($0.1)" } ?? "")
            mapLine = "#EXT-X-MAP:URI=\"\(initRoute(bu, initRange))\""
            let sidxBytes = [UInt8](try await readRange(bu, idx.0, idx.1))
            let refs = try parseSidx(sidxBytes)
            var offset = idx.1 + 1 + refs.firstOffset
            for r in refs.items {
                entries.append((Double(r.duration) / Double(refs.timescale),
                                segRoute(bu, (offset, offset + r.size - 1), initUrl: initKey)))
                offset += r.size
            }
            // La clave se busca por el inicio: se identifica con la misma URL+rango
            return playlist(mapLine, entries, vodEnd: true)
        }

        if let st = rep.inheritedChild("SegmentTemplate") {
            // Plantilla (con SegmentTimeline o con duración fija)
            let timescale = Double(st.attrs["timescale"] ?? "1") ?? 1
            func fill(_ t: String, number: Int, time: Int) -> String {
                var s = t.replacingOccurrences(of: "$RepresentationID$", with: repId)
                    .replacingOccurrences(of: "$Bandwidth$", with: rep.attrs["bandwidth"] ?? "")
                for (tag, v) in [("Number", number), ("Time", time)] {
                    if let re = try? NSRegularExpression(pattern: "\\$\(tag)(%0(\\d+)d)?\\$") {
                        let ns = s as NSString
                        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                            let w = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 0
                            s = (s as NSString).replacingCharacters(in: m.range, with: String(format: "%0\(w)lld", Int64(v)))     // 64 bits: los $Time$ con timescale 90000 pasan de 2^31 (Tivify)
                        }
                    }
                }
                return s.replacingOccurrences(of: "$$", with: "$")
            }
            // Subtítulos de texto (VTT/TTML sueltos): sin inicio, cada trozo se sirve ya como WebVTT
            let mime = rep.attrs["mimeType"] ?? set.attrs["mimeType"] ?? ""
            if (mime.hasPrefix("text") || kind(set, rep) == "text"), let mediaT = st.attrs["media"] {
                let route = mime.contains("vtt") ? "vtt" : "sub"
                var number = Int(st.attrs["startNumber"] ?? "1") ?? 1
                var time = 0
                var subs: [(dur: Double, url: String)] = []
                var lastD = 0
                var tl = st.child("SegmentTimeline")?.all("S") ?? []
                if tl.isEmpty {                                  // duración fija: se inventa una entrada «d, r»
                    let d = Double(st.attrs["duration"] ?? "0") ?? 0
                    guard d > 0, totalDur > 0 else { throw NSError(domain: "MpdToHls", code: 5, userInfo: [NSLocalizedDescriptionKey: "subtítulos sin duración"]) }
                    let n = Node(name: "S"); n.attrs["d"] = String(Int(d)); n.attrs["r"] = String(max(Int((totalDur / (d / timescale)).rounded(.up)) - 1, 0))
                    tl = [n]
                }
                for sNode in tl {
                    if let t = sNode.attrs["t"], let tv = Int(t) { time = tv }
                    let d = Int(sNode.attrs["d"] ?? "0") ?? 0
                    for _ in 0...(Int(sNode.attrs["r"] ?? "0") ?? 0) {
                        if let u = URL(string: fill(mediaT, number: number, time: time), relativeTo: bu)?.absoluteURL {
                            subs.append((Double(d) / timescale, "\(relay)/\(route)?u=\(enc(u.absoluteString))"))
                        }
                        time += d; number += 1; lastD = d
                    }
                }
                // Algunos MPD (Max) describen solo el primer trozo de subtítulos y el servidor sigue con los siguientes números
                // (1.vtt, 2.vtt…): se siguen pidiendo hasta cubrir la película. Si alguno no existe, el relay devuelve un WebVTT vacío.
                var covered = subs.reduce(0) { $0 + $1.dur }
                if lastD > 0, totalDur > 0, subs.count <= 2, covered < totalDur * 0.9 {
                    while covered < totalDur - 1, subs.count < 400 {
                        if let u = URL(string: fill(mediaT, number: number, time: time), relativeTo: bu)?.absoluteURL {
                            subs.append((Double(lastD) / timescale, "\(relay)/\(route)?u=\(enc(u.absoluteString))&opt=1"))
                        }
                        covered += Double(lastD) / timescale; time += lastD; number += 1
                    }
                }
                return playlist("", subs, vodEnd: true)
            }
            guard let initT = st.attrs["initialization"], let mediaT = st.attrs["media"],
                  let initUrl = URL(string: fill(initT, number: 0, time: 0), relativeTo: bu)?.absoluteURL else {
                throw NSError(domain: "MpdToHls", code: 4, userInfo: [NSLocalizedDescriptionKey: "SegmentTemplate incompleta"])
            }
            mapLine = "#EXT-X-MAP:URI=\"\(initRoute(initUrl, nil))\""
            var number = Int(st.attrs["startNumber"] ?? "1") ?? 1
            var times: [Int] = []                     // instante de cada trozo: sirve para numerar los trozos de un directo
            if let tl = st.child("SegmentTimeline") {
                var time = 0
                for s in tl.all("S") {
                    if let t = s.attrs["t"], let tv = Int(t) { time = tv }
                    let d = Int(s.attrs["d"] ?? "0") ?? 0
                    for _ in 0...(Int(s.attrs["r"] ?? "0") ?? 0) {
                        if let u = URL(string: fill(mediaT, number: number, time: time), relativeTo: bu)?.absoluteURL {
                            entries.append((Double(d) / timescale, segRoute(u, nil, initUrl: initUrl.absoluteString)))
                            times.append(time)
                        }
                        time += d; number += 1
                    }
                }
            } else {
                let d = Double(st.attrs["duration"] ?? "0") ?? 0
                guard d > 0, totalDur > 0 else { throw NSError(domain: "MpdToHls", code: 5, userInfo: [NSLocalizedDescriptionKey: "SegmentTemplate sin duración"]) }
                let segDur = d / timescale
                let count = Int((totalDur / segDur).rounded(.up))
                for i in 0..<count {
                    if let u = URL(string: fill(mediaT, number: number + i, time: Int(Double(i) * d)), relativeTo: bu)?.absoluteURL {
                        entries.append((min(segDur, totalDur - Double(i) * segDur), segRoute(u, nil, initUrl: initUrl.absoluteString)))
                    }
                }
            }
            // Directo: la lista se desliza. El número del primer trozo (MEDIA-SEQUENCE) debe subir de forma coherente en cada
            // recarga; con siempre 0, AVPlayer cree que es otra lista y se para a los pocos segundos.
            let live = mpd.attrs["type"] == "dynamic"
            return playlist(mapLine, entries, vodEnd: !live, firstSeq: live ? (liveSequence?(times) ?? 0) : 0)
        }

        if let sl = rep.inheritedChild("SegmentList") {
            // Lista explícita de segmentos
            let timescale = Double(sl.attrs["timescale"] ?? "1") ?? 1
            let segDur = (Double(sl.attrs["duration"] ?? "0") ?? 0) / timescale
            guard let initSrc = sl.child("Initialization")?.attrs["sourceURL"],
                  let initUrl = URL(string: initSrc, relativeTo: bu)?.absoluteURL else {
                throw NSError(domain: "MpdToHls", code: 6, userInfo: [NSLocalizedDescriptionKey: "SegmentList sin Initialization"])
            }
            mapLine = "#EXT-X-MAP:URI=\"\(initRoute(initUrl, nil))\""
            for s in sl.all("SegmentURL") {
                if let m = s.attrs["media"], let u = URL(string: m, relativeTo: bu)?.absoluteURL {
                    entries.append((segDur, segRoute(u, nil, initUrl: initUrl.absoluteString)))
                }
            }
            return playlist(mapLine, entries, vodEnd: true)
        }
        _ = set
        throw NSError(domain: "MpdToHls", code: 7, userInfo: [NSLocalizedDescriptionKey: "Representation sin SegmentBase/Template/List"])
    }

    private static func playlist(_ map: String, _ entries: [(dur: Double, url: String)], vodEnd: Bool, firstSeq: Int = 0) -> String {
        let target = Int((entries.map { $0.dur }.max() ?? 6).rounded(.up))
        var l = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:\(firstSeq)",
                 "#EXT-X-INDEPENDENT-SEGMENTS"]
        if vodEnd { l.append("#EXT-X-PLAYLIST-TYPE:VOD") }
        if !map.isEmpty { l.append(map) }
        for e in entries { l.append("#EXTINF:\(String(format: "%.5f", e.dur)),"); l.append(e.url) }
        if vodEnd { l.append("#EXT-X-ENDLIST") }
        return l.joined(separator: "\n") + "\n"
    }

    // MARK: - sidx

    struct Sidx { var timescale: Int; var firstOffset: Int; var items: [(size: Int, duration: Int)] }

    static func parseSidx(_ b: [UInt8]) throws -> Sidx {
        // El rango puede empezar en la caja «sidx» (cabecera de 8 bytes)
        guard b.count >= 32, Cenc.fourcc(b, 4) == "sidx" else {
            throw NSError(domain: "MpdToHls", code: 8, userInfo: [NSLocalizedDescriptionKey: "no hay sidx en el rango indicado"])
        }
        var p = 8
        let version = Int(b[p]); p += 4
        p += 4                                         // reference_ID
        let timescale = Cenc.u32(b, p); p += 4
        var first = 0
        if version == 0 { p += 4; first = Cenc.u32(b, p); p += 4 }
        else { p += 8; first = Cenc.u64(b, p); p += 8 }
        p += 2
        let count = Cenc.u16(b, p); p += 2
        var items: [(Int, Int)] = []
        for _ in 0..<count {
            guard p + 12 <= b.count else { break }
            items.append((Cenc.u32(b, p) & 0x7FFFFFFF, Cenc.u32(b, p + 4))); p += 12
        }
        return Sidx(timescale: max(timescale, 1), firstOffset: first, items: items.map { (size: $0.0, duration: $0.1) })
    }
}
