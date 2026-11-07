import Foundation
import Vision
import CoreImage
import AppKit
import CoreML

/// Лицо, найденное в кадре.
struct FaceHit {
    var rect: CGRect        // доли кадра, начало внизу слева (как в Vision)
    var crop: CGImage       // выровненное лицо 112×112 по 5 точкам (шаблон ArcFace)
    var emb: [Float]        // вектор лица SFace, 128 чисел (L2 = 1)
    var yaw: Double         // поворот головы, рад
    var px: CGFloat         // ширина лица в пикселях
}

/// Поиск лиц и точек (Vision) + выравнивание по 5 точкам + вектор лица SFace (Core ML).
/// SFace — модель распознавания лиц из OpenCV Zoo, та же, что в Windows-версии;
/// вектор совпадает с cv2.FaceRecognizerSF.feature (проверено, косинус 1.0).
final class FaceEngine {
    static let version = 3           // 1–2 — VNFeaturePrint по кропу 160; 3 — SFace по кропу 112
    static let side: CGFloat = 112
    /// Куда SFace ждёт глаза, кончик носа и углы рта (x вправо, y вниз; 0 — глаз слева на картинке).
    static let template: [CGPoint] = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
                                      CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
                                      CGPoint(x: 70.7299, y: 92.2041)]
    let ci = CIContext(options: [.cacheIntermediates: false])
    var minFace: CGFloat = 0.06       // минимальная ширина лица, доля кадра (≈ 1,5 м от ноутбука)
    let model: MLModel?

    init() {
        model = FaceEngine.loadModel()
        if model == nil { print("Не найдена модель SFace.mlmodelc") }
    }

    /// Модель лежит в Contents/Resources приложения; у голого build/Ktotam — в macos/models.
    static func loadModel() -> MLModel? {
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") { urls.append(u) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        urls.append(exe.appendingPathComponent("../models/SFace.mlmodelc").standardizedFileURL)
        urls.append(exe.appendingPathComponent("../Resources/SFace.mlmodelc").standardizedFileURL)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        for u in urls where FileManager.default.fileExists(atPath: u.path) {
            if let m = try? MLModel(contentsOf: u, configuration: cfg) { return m }
        }
        return nil
    }

    func analyze(_ image: CIImage) -> [FaceHit] {
        let req = VNDetectFaceLandmarksRequest()
        let h = VNImageRequestHandler(ciImage: image, options: [:])
        do { try h.perform([req]) } catch { return [] }
        let size = image.extent.size
        var out: [FaceHit] = []
        for obs in req.results ?? [] {
            let px = obs.boundingBox.width * size.width
            if obs.boundingBox.width < minFace || px < 36 { continue }
            guard let pts = fivePoints(obs, image.extent),
                  let crop = align(image, pts), let emb = embedding(crop) else { continue }
            out.append(FaceHit(rect: obs.boundingBox, crop: crop, emb: emb,
                               yaw: obs.yaw?.doubleValue ?? 0, px: px))
        }
        return out
    }

    /// Самое крупное лицо на фото (для самотеста и импорта снимков).
    func largestFace(in image: CIImage) -> FaceHit? {
        let saved = minFace
        minFace = 0.02
        defer { minFace = saved }
        return analyze(image).max { $0.px < $1.px }
    }

    private func center(_ pts: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(pts.count, 1))
        return CGPoint(x: pts.reduce(0) { $0 + $1.x } / n, y: pts.reduce(0) { $0 + $1.y } / n)
    }

    /// 5 точек в координатах картинки с началом сверху слева: глаз слева, глаз справа, нос, угол рта слева, справа.
    func fivePoints(_ obs: VNFaceObservation, _ ext: CGRect) -> [CGPoint]? {
        guard let lm = obs.landmarks, let le = lm.leftPupil ?? lm.leftEye, let re = lm.rightPupil ?? lm.rightEye,
              let nose = lm.noseCrest ?? lm.nose, let lips = lm.outerLips else { return nil }
        let sz = ext.size
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: sz.height - p.y) }
        var a = flip(center(le.pointsInImage(imageSize: sz))), b = flip(center(re.pointsInImage(imageSize: sz)))
        if a.x > b.x { swap(&a, &b) }
        // Кончик носа — самая нижняя точка спинки носа.
        guard let tip = nose.pointsInImage(imageSize: sz).map(flip).max(by: { $0.y < $1.y }) else { return nil }
        let lp = lips.pointsInImage(imageSize: sz).map(flip)
        guard let ml = lp.min(by: { $0.x < $1.x }), let mr = lp.max(by: { $0.x < $1.x }) else { return nil }
        return [a, b, tip, ml, mr]
    }

    /// Подобие (поворот + масштаб + сдвиг) методом наименьших квадратов — как alignCrop в OpenCV.
    static func similarity(_ src: [CGPoint], _ dst: [CGPoint]) -> CGAffineTransform? {
        let n = CGFloat(src.count)
        let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var num1: CGFloat = 0, num2: CGFloat = 0, den: CGFloat = 0
        for (p, q) in zip(src, dst) {
            let x = p.x - ms.x, y = p.y - ms.y, u = q.x - md.x, v = q.y - md.y
            num1 += x * u + y * v
            num2 += x * v - y * u
            den += x * x + y * y
        }
        guard den > 1e-6 else { return nil }
        let a = num1 / den, b = num2 / den
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: md.x - (a * ms.x - b * ms.y), ty: md.y - (b * ms.x + a * ms.y))
    }

    /// Вырезает лицо 112×112: точки (сверху слева) переводятся в шаблон.
    func align(_ img: CIImage, _ pts: [CGPoint]) -> CGImage? {
        guard let t = FaceEngine.similarity(pts, FaceEngine.template) else { return nil }
        let ext = img.extent, S = FaceEngine.side
        // CIImage считает от нижнего левого угла: переворачиваем вход и выход.
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -ext.minX, ty: ext.maxY)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: S)
        let full = flipIn.concatenating(t).concatenating(flipOut)
        let out = img.clampedToExtent().transformed(by: full).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
        return ci.createCGImage(out, from: out.extent)
    }

    /// Старый кроп 160×160 (версии 1–2: зрачки на (80 ∓ 28.8, 64) сверху) → новый кроп 112 по шаблону глаз.
    func realignOld(_ old: CGImage) -> CGImage? {
        let src = [CGPoint(x: 51.2, y: 64), CGPoint(x: 108.8, y: 64)]
        let dst = Array(FaceEngine.template.prefix(2))
        guard let t = FaceEngine.similarity(src, dst) else { return nil }
        let H = CGFloat(old.height), S = FaceEngine.side
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: S)
        let out = CIImage(cgImage: old).clampedToExtent().transformed(by: flipIn.concatenating(t).concatenating(flipOut))
            .cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
        return ci.createCGImage(out, from: out.extent)
    }

    func embedding(_ crop: CGImage) -> [Float]? {
        guard let model,
              let fv = try? MLFeatureValue(cgImage: crop, pixelsWide: 112, pixelsHigh: 112,
                                           pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["image": fv]),
              let res = try? model.prediction(from: input),
              let arr = res.featureValue(for: "feature")?.multiArrayValue else { return nil }
        var v = [Float](repeating: 0, count: arr.count)
        for i in 0..<arr.count { v[i] = arr[i].floatValue }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if n > 0 { for i in v.indices { v[i] /= n } }
        return v
    }

    func jpeg(_ img: CGImage, quality: Double = 0.85) -> Data {
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) ?? Data()
    }

    static func cgImage(jpeg: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
