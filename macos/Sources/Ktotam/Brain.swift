import Foundation
import CoreGraphics

/// Результат сравнения лица с базой.
struct Match {
    var best: Int64?      // ближайший человек (даже если не уверены)
    var dist: Float       // расстояние до него (меньше — похожее)
    var second: Float     // расстояние до следующего человека
    var known: Bool       // уверенно узнан
    static let none = Match(best: nil, dist: 9, second: 9, known: false)
}

/// Узнавание ближайшими соседями: для каждого человека берём среднее k самых близких его снимков.
final class Recognizer {
    private(set) var byUser: [Int64: [[Float]]] = [:]
    var threshold: Float = 0.42     // дальше — «не знаю»
    var margin: Float = 0.015       // насколько лучший должен опережать второго
    var k = 3
    var maxPerUser = 400

    func rebuild(_ samples: [Sample]) {
        var m: [Int64: [[Float]]] = [:]
        for s in samples where !s.emb.isEmpty { m[s.userId, default: []].append(s.emb) }
        for (u, v) in m where v.count > maxPerUser { m[u] = Array(v.suffix(maxPerUser)) }
        byUser = m
    }

    func add(_ emb: [Float], to user: Int64) {
        byUser[user, default: []].append(emb)
        if byUser[user]!.count > maxPerUser { byUser[user]!.removeFirst() }
    }

    static func dist(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        let n = min(a.count, b.count)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 0..<n { let d = pa[i] - pb[i]; s += d * d }
            }
        }
        return s.squareRoot()
    }

    /// Расстояние до человека: среднее k ближайших снимков.
    func score(_ emb: [Float], _ list: [[Float]], exclude: Int? = nil) -> Float {
        var ds: [Float] = []
        ds.reserveCapacity(list.count)
        for (i, e) in list.enumerated() where i != exclude { ds.append(Recognizer.dist(emb, e)) }
        if ds.isEmpty { return 9 }
        ds.sort()
        let kk = min(k, ds.count)
        return ds.prefix(kk).reduce(0, +) / Float(kk)
    }

    func match(_ emb: [Float]) -> Match {
        var scores: [(Int64, Float)] = byUser.map { ($0.key, score(emb, $0.value)) }
        if scores.isEmpty { return .none }
        scores.sort { $0.1 < $1.1 }
        let best = scores[0], second = scores.count > 1 ? scores[1].1 : 9
        let known = best.1 <= threshold && (second - best.1) >= margin
        return Match(best: best.0, dist: best.1, second: second, known: known)
    }
}

/// Лицо, которое ведём от кадра к кадру. Метка устойчива: решает большинство последних кадров.
final class Track: Identifiable {
    static let unknown: Int64 = -1
    let id: Int
    var rect: CGRect
    var lastSeen: TimeInterval
    var votes: [Int64] = []
    var label: Int64?          // nil — ещё не решили; -1 — незнакомец
    var hit: FaceHit?
    var match: Match = .none
    var lastSnap: TimeInterval = 0
    var pinned: Int64?         // имя закреплено поправкой пользователя — пока лицо в кадре
    var boostLeft = 0          // сколько ещё снимков этого лица добрать к закреплённому человеку
    var lastBoost: TimeInterval = 0
    init(id: Int, rect: CGRect, now: TimeInterval) { self.id = id; self.rect = rect; lastSeen = now }

    func vote(_ v: Int64) {
        if let p = pinned { label = p; return }
        votes.append(v)
        if votes.count > 8 { votes.removeFirst() }
        var cnt: [Int64: Int] = [:]
        for x in votes { cnt[x, default: 0] += 1 }
        let top = cnt.max { $0.value < $1.value }!
        if votes.count >= 3 && top.value * 2 > votes.count { label = top.key }
        else if let l = label, (cnt[l] ?? 0) < 2 { label = nil }
    }

    /// После поправки пользователя — сразу перевешиваем голоса.
    func force(_ v: Int64, pin: Bool = false) {
        votes = Array(repeating: v, count: 6)
        label = v
        if pin { pinned = v }
    }
}

final class Tracker {
    private(set) var tracks: [Track] = []
    private var nextId = 1
    var lostAfter: TimeInterval = 0.8

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        if i.isNull { return 0 }
        let ia = i.width * i.height
        return ia / (a.width * a.height + b.width * b.height - ia)
    }

    /// Сопоставляет лица кадра с треками (жадно по перекрытию), возвращает трек для каждого лица.
    func update(_ rects: [CGRect], now: TimeInterval) -> [Track] {
        var free = Set(tracks.indices)
        var result: [Track] = []
        for r in rects {
            var bestI = -1
            var bestV: CGFloat = 0.15
            for i in free {
                let t = tracks[i]
                var v = Tracker.iou(t.rect, r)
                if v < 0.15 {
                    let dc = hypot(t.rect.midX - r.midX, t.rect.midY - r.midY)
                    if dc < max(t.rect.width, r.width) * 0.6 { v = 0.16 }
                }
                if v > bestV { bestV = v; bestI = i }
            }
            if bestI >= 0 {
                free.remove(bestI)
                let t = tracks[bestI]
                t.rect = r; t.lastSeen = now
                result.append(t)
            } else {
                let t = Track(id: nextId, rect: r, now: now)
                nextId += 1
                tracks.append(t)
                result.append(t)
            }
        }
        tracks.removeAll { now - $0.lastSeen > lostAfter }
        return result
    }
}

/// Кто «перед компом»: здороваемся при появлении, прощаемся после паузы отсутствия.
struct Presence {
    var absence: TimeInterval = 3
    private(set) var lastSeen: [Int64: TimeInterval] = [:]

    var present: Set<Int64> { Set(lastSeen.keys) }

    mutating func step(visible: Set<Int64>, now: TimeInterval) -> (hello: [Int64], bye: [Int64]) {
        var hello: [Int64] = []
        for u in visible {
            if lastSeen[u] == nil { hello.append(u) }
            lastSeen[u] = now
        }
        var bye: [Int64] = []
        for (u, t) in lastSeen where now - t > absence {
            bye.append(u)
        }
        for u in bye { lastSeen[u] = nil }
        return (hello.sorted(), bye.sorted())
    }

    /// Молча убрать (ошибочно узнанного) человека, без «пока».
    mutating func forget(_ u: Int64) { lastSeen[u] = nil }
}
