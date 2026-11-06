import Foundation
import Vision
import CoreImage
import AppKit

/// Лицо, найденное в кадре.
struct FaceHit {
    var rect: CGRect        // доли кадра, начало внизу слева (как в Vision)
    var crop: CGImage       // выровненное лицо 160×160: глаза горизонтально, на одной высоте
    var emb: [Float]        // вектор признаков (L2 = 1)
    var yaw: Double         // поворот головы, рад
    var px: CGFloat         // ширина лица в пикселях
}

/// Поиск лиц (Vision) + выравнивание по глазам + вектор признаков (VNFeaturePrint).
/// Вектор — общий «отпечаток картинки», а не специальная модель лиц, поэтому узнавание строится
/// на ближайших соседях по многим снимкам каждого человека: чем больше поправок, тем точнее.
final class FaceEngine {
    static let version = 2           // меняется при смене выравнивания/признаков → пересчёт базы
    static let side: CGFloat = 160
    let ci = CIContext(options: [.cacheIntermediates: false])
    var minFace: CGFloat = 0.06       // минимальная ширина лица, доля кадра (≈ 1,5 м от ноутбука)

    func analyze(_ image: CIImage) -> [FaceHit] {
        let req = VNDetectFaceLandmarksRequest()
        let h = VNImageRequestHandler(ciImage: image, options: [:])
        do { try h.perform([req]) } catch { return [] }
        let size = image.extent.size
        var out: [FaceHit] = []
        for obs in req.results ?? [] {
            let px = obs.boundingBox.width * size.width
            if obs.boundingBox.width < minFace || px < 36 { continue }
            guard let crop = align(image, obs), let emb = embedding(crop) else { continue }
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

    /// Поворот и масштаб так, чтобы зрачки были горизонтально на фиксированных местах.
    func align(_ img: CIImage, _ obs: VNFaceObservation) -> CGImage? {
        let ext = img.extent
        let S = FaceEngine.side
        var a: CGPoint, b: CGPoint
        if let lm = obs.landmarks,
           let le = lm.leftPupil ?? lm.leftEye, let re = lm.rightPupil ?? lm.rightEye {
            a = center(le.pointsInImage(imageSize: ext.size))
            b = center(re.pointsInImage(imageSize: ext.size))
            if a.x > b.x { swap(&a, &b) }
        } else {
            // Без точек — оцениваем глаза по рамке лица.
            let r = VNImageRectForNormalizedRect(obs.boundingBox, Int(ext.width), Int(ext.height))
            a = CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.62)
            b = CGPoint(x: r.minX + r.width * 0.7, y: a.y)
        }
        let d = hypot(b.x - a.x, b.y - a.y)
        guard d > 4 else { return nil }
        let theta = atan2(b.y - a.y, b.x - a.x)
        let k = 0.36 * S / d
        let c = CGPoint(x: (a.x + b.x) / 2 + ext.minX, y: (a.y + b.y) / 2 + ext.minY)
        let t = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: -theta))
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: S / 2, y: S * 0.60))
        let out = img.clampedToExtent().transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
        return ci.createCGImage(out, from: out.extent)
    }

    func embedding(_ crop: CGImage) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFill
        let h = VNImageRequestHandler(cgImage: crop, options: [:])
        do { try h.perform([req]) } catch { return nil }
        guard let fp = req.results?.first as? VNFeaturePrintObservation else { return nil }
        var v: [Float]
        switch fp.elementType {
        case .float: v = fp.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double: v = fp.data.withUnsafeBytes { $0.bindMemory(to: Double.self).map { Float($0) } }
        default: return nil
        }
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
