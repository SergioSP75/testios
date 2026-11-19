import Foundation

/// Lo que ofrece un título para ver o bajar: calidades de vídeo, pistas de audio y subtítulos, igual para cualquier origen
/// (lista HLS, DASH, Smooth, MKV, MP4, Emby/Jellyfin, Plex). Es la ventana de «Opciones de descarga» de Android:
/// el usuario ve todo lo que hay y elige, sin importar de qué proveedor o servidor venga.

public struct OfferVideo: Identifiable, Equatable {
    public var id: String
    public var width: Int
    public var height: Int
    public var codec: String          // nombre legible: «H.264», «HEVC», «VP9», «AV1», «Dolby Vision», «MPEG-2»…
    public var range: String          // «SDR», «HDR10 (PQ)», «HLG», «Dolby Vision»
    public var mbps: Double
    public var fps: Double
    /// Reproductor que lo abre en este aparato (AVPlayer o VLC por software)
    public var engine: PlaybackEngine

    public var label: String {
        var p = [height > 0 ? "\(height)p" : "Vídeo", codec]
        if range != "SDR", !range.isEmpty { p.append(range) }
        if fps > 31 { p.append("\(Int(fps.rounded())) fps") }
        if mbps > 0 { p.append(String(format: "%.1f Mbps", mbps)) }
        return p.joined(separator: " · ")
    }
}

public struct OfferAudio: Identifiable, Equatable {
    public var id: String
    public var lang: String
    public var name: String
    public var codec: String          // «AAC», «AC-3», «E-AC-3», «DTS», «TrueHD», «Opus», «FLAC»…
    public var channels: Int
    public var kbps: Int
    public var isDescription: Bool
    public var engine: PlaybackEngine

    public var channelsText: String {
        switch channels { case 0: return ""; case 1: return "mono"; case 2: return "estéreo"; case 6: return "5.1"; case 8: return "7.1"; default: return "\(channels) canales" }
    }
    public var label: String {
        var p = [name.isEmpty ? (lang.isEmpty ? "Audio" : lang) : name]
        var fmt = [codec, channelsText].filter { !$0.isEmpty }.joined(separator: " ")
        if kbps > 0 { fmt += (fmt.isEmpty ? "" : " · ") + "\(kbps) kbps" }
        if !fmt.isEmpty { p.append(fmt) }
        if isDescription { p.append("audiodescripción") }
        return p.joined(separator: " · ")
    }
    /// Código de idioma sin región: «es-419» → «es».
    public var baseLang: String { String(lang.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "") }
}

public struct OfferSub: Identifiable, Equatable {
    public var id: String
    public var lang: String
    public var name: String
    public var format: String         // «WebVTT», «TTML», «SRT», «ASS», «PGS»…
    public var forced: Bool
    /// Los de imagen (PGS, VobSub, DVB) no se pasan a texto: solo los dibuja VLC
    public var isImage: Bool

    public var label: String {
        var p = [name.isEmpty ? (lang.isEmpty ? "Subtítulos" : lang) : name]
        if !format.isEmpty { p.append(format) }
        if forced { p.append("forzados") }
        return p.joined(separator: " · ")
    }
    public var baseLang: String { String(lang.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "") }
}

public struct StreamOffer: Equatable {
    /// «hls», «dash», «smooth», «mkv», «mp4», «emby», «plex»…
    public var source: String
    public var videos: [OfferVideo] = []
    public var audios: [OfferAudio] = []
    public var subs: [OfferSub] = []
    public var isEmpty: Bool { videos.isEmpty && audios.isEmpty && subs.isEmpty }
    public init(source: String) { self.source = source }

    /// Alturas distintas de mayor a menor (para «Hasta 1080p»).
    public var heights: [Int] { Array(Set(videos.map { $0.height }.filter { $0 > 0 })).sorted(by: >) }
    /// Idiomas de audio distintos (primer nombre de cada uno).
    public var audioLanguages: [(code: String, name: String)] { Self.distinct(audios.map { ($0.baseLang, $0.name.isEmpty ? $0.lang : $0.name) }) }
    public var subLanguages: [(code: String, name: String)] { Self.distinct(subs.map { ($0.baseLang, $0.name.isEmpty ? $0.lang : $0.name) }) }
    private static func distinct(_ a: [(String, String)]) -> [(code: String, name: String)] {
        var seen = Set<String>(), out: [(code: String, name: String)] = []
        for (c, n) in a where !c.isEmpty && seen.insert(c).inserted { out.append((code: c, name: n)) }
        return out
    }
}

// MARK: - Nombres de códec

public enum CodecNames {
    /// Códec de vídeo → nombre legible. Vale para RFC 6381 («avc1.64002A»), Matroska («V_MPEGH/ISO/HEVC»), Smooth («H264») y servidores («h264»).
    public static func video(_ raw: String) -> String {
        let c = raw.lowercased()
        if c.isEmpty { return "?" }
        if c.hasPrefix("dvh") || c.contains("dolby") { return "Dolby Vision" }
        if c.hasPrefix("avc") || c.contains("h264") || c.contains("h.264") || c.contains("mpeg4/iso/avc") { return "H.264" }
        if c.hasPrefix("hvc") || c.hasPrefix("hev") || c.contains("hevc") || c.contains("h265") || c.contains("mpegh") { return "HEVC" }
        if c.hasPrefix("vp09") || c.contains("vp9") { return "VP9" }
        if c.hasPrefix("vp08") || c.contains("vp8") { return "VP8" }
        if c.hasPrefix("av01") || c.contains("av1") { return "AV1" }
        if c.contains("mpeg2") || c.contains("mpeg-2") || c.hasPrefix("mp2v") || c.contains("v_mpeg2") { return "MPEG-2" }
        if c.contains("mpeg4") || c.hasPrefix("mp4v") || c.contains("xvid") || c.contains("divx") { return "MPEG-4" }
        if c.contains("vc1") || c.contains("wvc1") { return "VC-1" }
        if c.contains("wmv") { return "WMV" }
        if c.contains("theora") { return "Theora" }
        if c.contains("prores") || c.hasPrefix("apc") { return "ProRes" }
        if c.contains("mjpeg") || c.contains("mjpg") { return "MJPEG" }
        return String(c.prefix { $0 != "." }).uppercased()
    }

    /// Códec de audio → nombre legible («mp4a.40.2» → AAC, «ec-3» → E-AC-3, «A_DTS» → DTS…).
    public static func audio(_ raw: String) -> String {
        let c = raw.lowercased()
        if c.isEmpty { return "" }
        if c.hasPrefix("ec-3") || c.contains("eac3") || c.contains("e-ac-3") || c.contains("a_eac3") { return "E-AC-3" }
        if c.hasPrefix("ac-3") || c.hasPrefix("ac3") || c.contains("a_ac3") { return "AC-3" }
        if c.hasPrefix("ac-4") { return "AC-4" }
        if c.contains("truehd") || c.contains("mlp") { return "TrueHD" }
        if c.contains("dts") || c == "dca" { return c.contains("hd") || c.contains("ma") ? "DTS-HD" : "DTS" }
        if c.hasPrefix("mp4a.40.5") || c.hasPrefix("mp4a.40.29") { return "HE-AAC" }
        if c.hasPrefix("mp4a.6b") || c.hasPrefix("mp4a.69") || c.contains("mpeg/l3") || c == "mp3" { return "MP3" }
        if c.hasPrefix("mp4a") || c.contains("aac") { return "AAC" }
        if c.contains("opus") { return "Opus" }
        if c.contains("vorbis") { return "Vorbis" }
        if c.contains("flac") { return "FLAC" }
        if c.contains("alac") { return "ALAC" }
        if c.contains("pcm") || c.contains("lpcm") { return "PCM" }
        if c.contains("wma") { return "WMA" }
        if c.contains("mpeg/l2") || c == "mp2" { return "MP2" }
        return c.prefix { $0 != "." }.uppercased()
    }

    /// Subtítulo → (nombre del formato, ¿es de imagen?)
    public static func subtitle(_ raw: String) -> (name: String, image: Bool) {
        let c = raw.lowercased()
        if c.contains("vtt") { return ("WebVTT", false) }
        if c.contains("ttml") || c.contains("stpp") || c.contains("dfxp") || c.contains("xml") { return ("TTML", false) }
        if c.contains("subrip") || c == "srt" || c.contains("s_text/utf8") { return ("SRT", false) }
        if c.contains("ass") || c.contains("ssa") { return ("ASS", false) }
        if c.contains("mov_text") || c.contains("tx3g") { return ("Texto MP4", false) }
        if c.contains("cea") || c.contains("608") || c.contains("708") || c.contains("eia") { return ("CEA-608/708", false) }
        if c.contains("pgs") || c.contains("hdmv") { return ("PGS", true) }
        if c.contains("vobsub") || c.contains("dvd_subtitle") || c.contains("s_vobsub") { return ("VobSub", true) }
        if c.contains("dvb") { return ("DVB", true) }
        return (raw.isEmpty ? "" : raw.uppercased(), false)
    }
}

// MARK: - Constructores del catálogo por origen

public enum StreamOffers {

    private static func engine(video codec: String, _ f: MediaFacts) -> PlaybackEngine { EngineChooser.videoNeedsVlc(codec, f) ? .vlc : .avplayer }
    private static func engine(audio codec: String) -> PlaybackEngine { EngineChooser.audioNeedsVlc(codec) ? .vlc : .avplayer }

    // HLS ---------------------------------------------------------------------------------------------------------

    static func attr(_ line: String, _ name: String) -> String? {
        guard let r = line.range(of: "(^|[:,])\(name)=(\"[^\"]*\"|[^,]*)", options: .regularExpression) else { return nil }
        let part = String(line[r]); let v = String(part[part.index(after: part.firstIndex(of: "=")!)...])
        return v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Lista maestra HLS: calidades (STREAM-INF), audios (EXT-X-MEDIA TYPE=AUDIO) y subtítulos (TYPE=SUBTITLES).
    public static func fromHls(_ master: String, facts: MediaFacts = MediaFacts(), ui: String = "") -> StreamOffer {
        var o = StreamOffer(source: "hls")
        let lines = master.components(separatedBy: .newlines)
        // Códec y tasa de cada grupo de audio, sacados de las variantes que lo usan
        var groupCodec: [String: String] = [:]
        var seenVideo = Set<String>()
        for l in lines where l.hasPrefix("#EXT-X-STREAM-INF") {
            let codecs = (attr(l, "CODECS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let audioCodec = codecs.first { $0.lowercased().hasPrefix("mp4a") || $0.lowercased().hasPrefix("ec-3") || $0.lowercased().hasPrefix("ac-3") || $0.lowercased().hasPrefix("ac-4") || $0.lowercased().hasPrefix("opus") || $0.lowercased().contains("flac") || $0.lowercased().contains("dts") }
            let videoCodec = codecs.first { $0 != audioCodec && !$0.lowercased().hasPrefix("stpp") && !$0.lowercased().hasPrefix("wvtt") } ?? ""
            if let g = attr(l, "AUDIO"), groupCodec[g] == nil, let a = audioCodec { groupCodec[g] = a }
            var w = 0, h = 0
            if let res = attr(l, "RESOLUTION") { let p = res.lowercased().split(separator: "x").compactMap { Int($0) }; if p.count == 2 { w = p[0]; h = p[1] } }
            let bw = Double(attr(l, "AVERAGE-BANDWIDTH") ?? attr(l, "BANDWIDTH") ?? "") ?? 0
            let fps = Double(attr(l, "FRAME-RATE") ?? "") ?? 0
            // Pistas de solo audio o de imágenes sueltas no son una calidad
            guard h > 0 || !videoCodec.isEmpty else { continue }
            let range: String
            switch attr(l, "VIDEO-RANGE") {
            case "PQ": range = videoCodec.lowercased().hasPrefix("dvh") ? "Dolby Vision" : "HDR10 (PQ)"
            case "HLG": range = "HLG"
            default: range = VideoLabels.rangeName(l, videoCodec.lowercased())
            }
            let v = OfferVideo(id: "\(h)|\(CodecNames.video(videoCodec))|\(range)|\(Int(bw / 100_000))", width: w, height: h, codec: CodecNames.video(videoCodec), range: range,
                               mbps: bw / 1_000_000, fps: fps, engine: engine(video: videoCodec, facts))
            if seenVideo.insert(v.id).inserted { o.videos.append(v) }
        }
        o.videos.sort { ($0.height, $0.mbps) > ($1.height, $1.mbps) }
        let shown = AudioLabels.displayNames(master, ui: ui)
        for l in lines where l.hasPrefix("#EXT-X-MEDIA") {
            let name = attr(l, "NAME") ?? "", lang = attr(l, "LANGUAGE") ?? "", group = attr(l, "GROUP-ID") ?? ""
            if l.contains("TYPE=AUDIO") {
                let codec = groupCodec[group] ?? ""
                let ch = Int((attr(l, "CHANNELS") ?? "").split(separator: "/").first ?? "") ?? 0
                let ad = l.lowercased().contains("describes-video") || name.lowercased().contains("audio description") || name.lowercased().contains("audiodescrip")
                var disp = name
                if let s = shown[group + "|" + name] { disp = s.components(separatedBy: " · ").first ?? s }   // idioma legible sin «· códec canales»
                o.audios.append(OfferAudio(id: group + "|" + name, lang: lang, name: disp, codec: CodecNames.audio(codec), channels: ch, kbps: 0, isDescription: ad, engine: engine(audio: codec)))
            } else if l.contains("TYPE=SUBTITLES") {
                let f = CodecNames.subtitle("vtt")
                o.subs.append(OfferSub(id: group + "|" + name, lang: lang, name: LanguageNames.readable(name: name, lang: lang, ui: ui), format: f.name, forced: l.contains("FORCED=YES"), isImage: false))
            }
        }
        return o
    }

    // DASH ---------------------------------------------------------------------------------------------------------

    /// MPD: cada Representation de vídeo es una calidad; cada AdaptationSet de audio/texto, una pista. Se saltan las pistas de avance rápido.
    public static func fromMpd(_ xml: String, facts: MediaFacts = MediaFacts()) -> StreamOffer {
        var o = StreamOffer(source: "dash")
        guard let root = try? MpdToHls.parse(xml) else { return o }
        var seen = Set<String>()
        for period in root.all("Period") {
            for set in period.all("AdaptationSet") {
                let reps = set.all("Representation")
                let kind = MpdToHls.kind(set, reps.first)
                if kind == "video" {
                    if MpdToHls.isTrickMode(set) { continue }
                    for r in reps {
                        let codec = r.inherited("codecs") ?? ""
                        let bw = Double(r.attrs["bandwidth"] ?? "") ?? 0
                        let fps = MpdToHls.frameRateValue(r.inherited("frameRate") ?? "") ?? 0
                        let rangeProp = (set.children + r.children).first { $0.name == "SupplementalProperty" || $0.name == "EssentialProperty" }
                        let hdr = (rangeProp?.attrs["value"] ?? "") == "16" ? "HDR10 (PQ)" : (rangeProp?.attrs["value"] ?? "") == "18" ? "HLG" : VideoLabels.rangeName("", codec.lowercased())
                        let v = OfferVideo(id: r.attrs["id"] ?? "", width: Int(r.inherited("width") ?? "") ?? 0, height: Int(r.inherited("height") ?? "") ?? 0,
                                           codec: CodecNames.video(codec), range: hdr, mbps: bw / 1_000_000, fps: fps, engine: engine(video: codec, facts))
                        if seen.insert("v|\(v.id)|\(v.height)|\(v.codec)|\(Int(bw))").inserted { o.videos.append(v) }
                    }
                } else if kind == "audio" {
                    let lang = set.attrs["lang"] ?? ""
                    let roles = set.all("Role").compactMap { $0.attrs["value"] }
                    let ad = roles.contains("description") || (set.attrs["label"] ?? "").lowercased().contains("descri")
                    for r in reps {
                        let codec = r.inherited("codecs") ?? ""
                        let chNode = r.child("AudioChannelConfiguration") ?? set.child("AudioChannelConfiguration")
                        var ch = Int(chNode?.attrs["value"] ?? "") ?? 0
                        if ch == 0, let v = chNode?.attrs["value"], v.count == 4, let n = Int(v, radix: 16) { ch = n.nonzeroBitCount }   // máscara Dolby «F801» → 6
                        let bw = Int((Double(r.attrs["bandwidth"] ?? "") ?? 0) / 1000)
                        let a = OfferAudio(id: (r.attrs["id"] ?? "") + "|" + lang, lang: lang, name: set.attrs["label"] ?? LanguageNames.readable(name: lang, lang: lang, ui: ""),
                                           codec: CodecNames.audio(codec), channels: ch, kbps: bw, isDescription: ad, engine: engine(audio: codec))
                        if seen.insert("a|\(a.id)").inserted { o.audios.append(a) }
                    }
                } else if kind == "text" || (kind == "application" && (set.attrs["mimeType"] ?? "").contains("ttml")) || (set.attrs["mimeType"] ?? "").hasPrefix("text/") {
                    let lang = set.attrs["lang"] ?? ""
                    let rep = reps.first
                    let fmtRaw = (rep?.inherited("codecs") ?? "") + " " + (rep?.inherited("mimeType") ?? set.attrs["mimeType"] ?? "")
                    let f = CodecNames.subtitle(fmtRaw)
                    let forced = set.all("Role").contains { $0.attrs["value"] == "forced-subtitle" }
                    let s = OfferSub(id: (rep?.attrs["id"] ?? set.attrs["id"] ?? "") + "|" + lang, lang: lang, name: set.attrs["label"] ?? LanguageNames.readable(name: lang, lang: lang, ui: ""), format: f.name, forced: forced, isImage: f.image)
                    if seen.insert("s|\(s.id)").inserted { o.subs.append(s) }
                }
            }
        }
        o.videos.sort { ($0.height, $0.mbps) > ($1.height, $1.mbps) }
        return o
    }

    // Smooth Streaming ----------------------------------------------------------------------------------------------

    public static func fromSmooth(_ xml: String, facts: MediaFacts = MediaFacts()) -> StreamOffer {
        var o = StreamOffer(source: "smooth")
        guard let root = try? MpdToHls.parse(xml) else { return o }
        for si in root.all("StreamIndex") {
            let type = (si.attrs["Type"] ?? "").lowercased(), lang = si.attrs["Language"] ?? ""
            for q in si.all("QualityLevel") {
                let fourCC = q.attrs["FourCC"] ?? ""
                let bw = Double(q.attrs["Bitrate"] ?? "") ?? 0
                let idx = q.attrs["Index"] ?? "\(Int(bw))"
                if type == "video" {
                    o.videos.append(OfferVideo(id: idx, width: Int(q.attrs["MaxWidth"] ?? "") ?? 0, height: Int(q.attrs["MaxHeight"] ?? "") ?? 0, codec: CodecNames.video(fourCC),
                                               range: "SDR", mbps: bw / 1_000_000, fps: 0, engine: engine(video: fourCC, facts)))
                } else if type == "audio" {
                    // Smooth da AACL/AACH/EC-3/AC-3 en FourCC; «mp4a» en el códec de la cabecera
                    let codec = fourCC.uppercased().hasPrefix("AAC") ? "mp4a.40.2" : fourCC
                    o.audios.append(OfferAudio(id: (si.attrs["Name"] ?? "audio") + "|" + idx, lang: lang, name: si.attrs["Name"] ?? LanguageNames.readable(name: lang, lang: lang, ui: ""), codec: CodecNames.audio(codec),
                                               channels: Int(q.attrs["Channels"] ?? "") ?? 0, kbps: Int(bw / 1000), isDescription: false, engine: engine(audio: codec)))
                }
            }
            if type == "text" {
                let f = CodecNames.subtitle(si.attrs["Subtype"] ?? "ttml")
                o.subs.append(OfferSub(id: (si.attrs["Name"] ?? "text") + "|" + lang, lang: lang, name: si.attrs["Name"] ?? LanguageNames.readable(name: lang, lang: lang, ui: ""), format: f.name.isEmpty ? "TTML" : f.name,
                                       forced: (si.attrs["Subtype"] ?? "").lowercased() == "forced", isImage: false))
            }
        }
        o.videos.sort { ($0.height, $0.mbps) > ($1.height, $1.mbps) }
        return o
    }

    // MKV ---------------------------------------------------------------------------------------------------------

    /// Pistas de un MKV (de `MkvToHls.report`): las «directas» las pasa AVPlayer tras reempaquetar; las otras solo VLC.
    public static func fromMkv(_ tracks: [MkvToHls.TrackReport], facts: MediaFacts = MediaFacts()) -> StreamOffer {
        var o = StreamOffer(source: "mkv")
        for (i, t) in tracks.enumerated() {
            if t.kind == "Vídeo" {
                let size = t.label.split(separator: "x").compactMap { Int($0) }
                o.videos.append(OfferVideo(id: "mkv\(i)", width: size.first ?? 0, height: size.count > 1 ? size[1] : 0, codec: CodecNames.video(t.codec), range: "SDR", mbps: 0, fps: 0,
                                           engine: t.direct ? engine(video: t.codec, facts) : .vlc))
            } else if t.kind == "Audio" {
                let ch = Int(t.label.split(separator: " ").last?.replacingOccurrences(of: "ch", with: "") ?? "") ?? 0
                let name = t.label.split(separator: " ").dropLast(ch > 0 ? 1 : 0).joined(separator: " ")
                o.audios.append(OfferAudio(id: "mkv\(i)", lang: t.lang, name: name, codec: CodecNames.audio(t.codec), channels: ch, kbps: 0, isDescription: false, engine: t.direct ? engine(audio: t.codec) : .vlc))
            }
        }
        return o
    }

    // Servidores externos -----------------------------------------------------------------------------------------

    /// Emby/Jellyfin: `MediaSources[0].MediaStreams` (Type Video/Audio/Subtitle).
    public static func fromEmbyStreams(_ streams: [[String: Any]], facts: MediaFacts = MediaFacts()) -> StreamOffer {
        var o = StreamOffer(source: "emby")
        func s(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? (d[k].map { "\($0)" } ?? "") }
        func n(_ d: [String: Any], _ k: String) -> Int { (d[k] as? Int) ?? Int(s(d, k)) ?? 0 }
        for st in streams {
            let idx = s(st, "Index"), codec = s(st, "Codec"), lang = s(st, "Language")
            switch s(st, "Type") {
            case "Video":
                let rt = s(st, "VideoRangeType").lowercased()
                let range = rt.contains("dovi") ? "Dolby Vision" : rt.contains("hdr10") ? "HDR10 (PQ)" : rt.contains("hlg") ? "HLG" : "SDR"
                o.videos.append(OfferVideo(id: idx, width: n(st, "Width"), height: n(st, "Height"), codec: CodecNames.video(codec), range: range,
                                           mbps: Double(n(st, "BitRate")) / 1_000_000, fps: Double(s(st, "RealFrameRate")) ?? Double(s(st, "AverageFrameRate")) ?? 0, engine: engine(video: codec, facts)))
            case "Audio":
                var title = s(st, "DisplayTitle"); if title.isEmpty { title = s(st, "Language") }
                o.audios.append(OfferAudio(id: idx, lang: lang, name: title, codec: CodecNames.audio(codec), channels: n(st, "Channels"), kbps: n(st, "BitRate") / 1000, isDescription: false, engine: engine(audio: codec)))
            case "Subtitle":
                var title = s(st, "DisplayTitle"); if title.isEmpty { title = s(st, "Language") }
                let f = CodecNames.subtitle(codec)
                o.subs.append(OfferSub(id: idx, lang: lang, name: title, format: f.name, forced: (st["IsForced"] as? Bool) ?? false, isImage: f.image))
            default: break
            }
        }
        return o
    }

    /// Plex: `Media[0].Part[0].Stream` (streamType 1 = vídeo, 2 = audio, 3 = subtítulos).
    public static func fromPlexStreams(_ streams: [[String: Any]], facts: MediaFacts = MediaFacts()) -> StreamOffer {
        var o = StreamOffer(source: "plex")
        func s(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? (d[k].map { "\($0)" } ?? "") }
        func n(_ d: [String: Any], _ k: String) -> Int { (d[k] as? Int) ?? Int(s(d, k)) ?? 0 }
        for st in streams {
            let id = s(st, "id"), codec = s(st, "codec"), lang = s(st, "languageTag").isEmpty ? s(st, "languageCode") : s(st, "languageTag")
            switch n(st, "streamType") {
            case 1:
                let range = s(st, "colorTrc") == "smpte2084" ? "HDR10 (PQ)" : s(st, "colorTrc") == "arib-std-b67" ? "HLG" : "SDR"
                o.videos.append(OfferVideo(id: id, width: n(st, "width"), height: n(st, "height"), codec: CodecNames.video(codec), range: range, mbps: Double(n(st, "bitrate")) / 1000, fps: Double(s(st, "frameRate")) ?? 0, engine: engine(video: codec, facts)))
            case 2:
                var title = s(st, "displayTitle"); if title.isEmpty { title = s(st, "language") }
                o.audios.append(OfferAudio(id: id, lang: lang, name: title, codec: CodecNames.audio(codec), channels: n(st, "channels"), kbps: n(st, "bitrate"), isDescription: false, engine: engine(audio: codec)))
            case 3:
                var title = s(st, "displayTitle"); if title.isEmpty { title = s(st, "language") }
                let f = CodecNames.subtitle(codec)
                o.subs.append(OfferSub(id: id, lang: lang, name: title, format: f.name, forced: s(st, "forced") == "1", isImage: f.image))
            default: break
            }
        }
        return o
    }
}
