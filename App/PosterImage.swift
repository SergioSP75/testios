import SwiftUI
import ImageIO

/// Carga de carátulas con caché propia (memoria y disco) y reducción de tamaño.
/// AsyncImage no guarda nada y con miles de títulos se quedaba sin cargar; esta reintenta y deja traza si falla.
/// Carpeta de imágenes ya reducidas (se reutilizan sin volver a bajar ni a reducir).
private let imageDiskDir: URL = {
    let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("caratulas", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
}()

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failedHosts = Set<String>()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 30_000_000, diskCapacity: 400_000_000)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()
    private init() { memory.countLimit = 600; Task.detached(priority: .background) { Self.prune() } }

    private nonisolated static func file(for key: String) -> URL {
        // Nombre estable a partir de la dirección (base64 acortada)
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").suffix(120)
        return imageDiskDir.appendingPathComponent(String(name) + ".jpg")
    }

    /// Borra lo más viejo: lo que pasa de X días y, si aún se pasa del tope en MB, lo menos usado.
    /// Se llama al abrir la app y desde Ajustes.
    nonisolated static func prune(clearAll: Bool = false) {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: imageDiskDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var items = list.compactMap { u -> (URL, Date, Int)? in
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (u, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }
        if clearAll { for i in items { try? fm.removeItem(at: i.0) }; Trace.shared.log("imagen", "caché vaciada (\(items.count) ficheros)"); return }
        let days = AppSettings.imageCacheDays, cap = AppSettings.imageCacheMB * 1_000_000
        var removed = 0
        if days > 0 {
            let limit = Date().addingTimeInterval(-Double(days) * 86400)
            for i in items where i.1 < limit { try? fm.removeItem(at: i.0); removed += 1 }
            items.removeAll { $0.1 < limit }
        }
        var total = items.reduce(0) { $0 + $1.2 }
        if cap > 0, total > cap {
            for i in items.sorted(by: { $0.1 < $1.1 }) where total > cap * 8 / 10 {      // se baja hasta el 80 % del tope
                try? fm.removeItem(at: i.0); total -= i.2; removed += 1
            }
        }
        if removed > 0 { Trace.shared.log("imagen", "caché: \(removed) imágenes borradas · quedan \(total / 1_000_000) MB") }
    }
    /// Tamaño actual del disco de imágenes, en MB.
    nonisolated static func diskMB() -> Int {
        let list = (try? FileManager.default.contentsOfDirectory(at: imageDiskDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return list.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } / 1_000_000
    }

    func image(for raw: String, maxPixel: Int) async -> UIImage? {
        let key = "\(raw)#\(maxPixel)" as NSString
        if let m = memory.object(forKey: key) { return m }
        if let t = inFlight[key as String] { return await t.value }
        let task = Task<UIImage?, Never> { [session] in
            // Primero el disco propio: ya viene reducida y no hace falta red
            let cached = Self.file(for: key as String)
            if let d = try? Data(contentsOf: cached), let img = UIImage(data: d) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)    // «usada hoy»
                return img
            }
            guard let url = Self.makeURL(raw) else { return nil }
            for attempt in 1...3 {
                var req = URLRequest(url: url)
                req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                if let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true,
                   let img = Self.downsample(data, maxPixel: maxPixel) {
                    if let jpg = img.jpegData(compressionQuality: 0.85) { try? jpg.write(to: cached, options: .atomic) }
                    return img
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
            return nil
        }
        inFlight[key as String] = task
        let img = await task.value
        inFlight[key as String] = nil
        if let i = img { memory.setObject(i, forKey: key) }
        else if let host = URL(string: raw)?.host, failedHosts.insert(host).inserted { Trace.shared.log("imagen", "no se pudo cargar una carátula de \(host): \(raw.prefix(120))") }
        return img
    }

    /// Direcciones con corchetes o espacios (p. ej. `?od[]=…`) se codifican antes de pedirlas.
    nonisolated static func makeURL(_ raw: String) -> URL? {
        if let u = URL(string: raw) { return u }
        return raw.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%:/?&=#[]"))).flatMap(URL.init(string:))
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Imagen remota rellenando su marco; mientras carga (o si no hay) enseña `placeholder`.
struct PosterImage<Placeholder: View>: View {
    let url: String?
    var maxPixel = 360
    /// true = la imagen entera dentro del marco (logos); false = rellena recortando (carátulas)
    var fit = false
    /// true = carga con prioridad baja, para que no compita con el texto ni con el desplazamiento (guía)
    var background = false
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        // La imagen se ajusta al marco con GeometryReader: antes `scaledToFill` se salía del marco y las carátulas vecinas
        // se tapaban entre sí, de modo que solo se podía tocar el borde derecho de cada una.
        GeometryReader { geo in
            ZStack {
                if let image { Group { if fit { Image(uiImage: image).resizable().scaledToFit() } else { Image(uiImage: image).resizable().scaledToFill() } }.frame(width: geo.size.width, height: geo.size.height).clipped() }
                else { placeholder().frame(width: geo.size.width, height: geo.size.height) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .contentShape(Rectangle())
        .task(id: url, priority: background ? .utility : .userInitiated) {
            guard let url, !url.isEmpty else { image = nil; return }
            image = await ImageLoader.shared.image(for: url, maxPixel: maxPixel)
        }
    }
}
