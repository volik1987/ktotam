import Foundation
import CoreImage

/// Автотест без камеры и окна.
enum SelfTest {
    static var fails = 0
    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ок  " : "  ОШИБКА ", what)
        if !ok { fails += 1 }
    }

    static func run(_ dir: String?) -> Bool {
        print("== Логика")
        logic()
        print("== База")
        storeTest()
        if let dir { print("== Узнавание по папке \(dir)"); accuracy(dir) }
        print(fails == 0 ? "ВСЁ ХОРОШО" : "ОШИБОК: \(fails)")
        return fails == 0
    }

    static func logic() {
        // Голосование трека: случайный промах не меняет метку.
        let t = Track(id: 1, rect: .zero, now: 0)
        for v: Int64 in [5, 5, 5] { t.vote(v) }
        check(t.label == 5, "трек определился после 3 одинаковых кадров")
        t.vote(7)
        check(t.label == 5, "один чужой кадр метку не меняет")
        for _ in 0..<6 { t.vote(7) }
        check(t.label == 7, "устойчиво другой — метка сменилась")
        t.force(9)
        check(t.label == 9, "поправка пользователя применяется сразу")
        t.force(4, pin: true)
        for _ in 0..<8 { t.vote(7) }
        check(t.label == 4, "закреплённое поправкой имя держится, пока лицо в кадре")

        // Присутствие: привет при появлении, пока — после паузы, короткое пропадание не считается.
        var p = Presence(); p.absence = 3
        var r = p.step(visible: [1], now: 0)
        check(r.hello == [1] && r.bye.isEmpty, "привет при появлении")
        r = p.step(visible: [], now: 2)
        check(r.bye.isEmpty, "пропал на 2 с — не прощаемся")
        r = p.step(visible: [1], now: 2.5)
        check(r.hello.isEmpty, "вернулся быстро — второй раз не здороваемся")
        r = p.step(visible: [2], now: 6)
        check(r.hello == [2] && r.bye == [1], "второй пришёл, первый ушёл")
        p.forget(2)
        r = p.step(visible: [], now: 20)
        check(r.bye.isEmpty, "ошибочно узнанного не провожаем")

        // Трекер: лицо чуть сдвинулось — тот же трек.
        let tr = Tracker()
        let a = tr.update([CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)], now: 0)[0]
        let b = tr.update([CGRect(x: 0.43, y: 0.41, width: 0.2, height: 0.2)], now: 0.1)[0]
        check(a === b, "трекер ведёт сдвинувшееся лицо")
        _ = tr.update([], now: 2)
        check(tr.tracks.isEmpty, "трек исчезает, когда лица нет")

        // Узнавание: ближайший сосед, порог и отрыв.
        let rec = Recognizer()
        rec.threshold = 0.5
        func v(_ x: Float, _ y: Float) -> [Float] { let n = (x * x + y * y).squareRoot(); return [x / n, y / n] }
        rec.rebuild([Sample(id: 1, userId: 1, emb: v(1, 0), version: 0), Sample(id: 2, userId: 1, emb: v(1, 0.1), version: 0),
                     Sample(id: 3, userId: 2, emb: v(0, 1), version: 0)])
        check(rec.match(v(1, 0.05)).best == 1 && rec.match(v(1, 0.05)).known, "узнаёт ближайшего")
        check(!rec.match(v(1, 1)).known, "посередине — «не знаю»")
    }

    static func storeTest() {
        let path = NSTemporaryDirectory() + "ktotam-test-\(getpid()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = Store(path: path)
        let a = s.addPerson("Вася"), b = s.addPerson("Петя")
        let id = s.addSample(user: a, emb: [0.6, 0.8], version: 1, jpeg: Data([1, 2, 3]), source: "t")
        check(s.people().first { $0.id == a }?.count == 1, "снимок сохранён")
        s.moveSample(id, to: b)
        check(s.samples().first?.userId == b && s.samples().first?.emb == [0.6, 0.8], "перенос снимка, вектор цел")
        s.rename(b, "Пётр")
        check(s.people().contains { $0.name == "Пётр" }, "переименование")
        s.deletePerson(b)
        check(s.samples().isEmpty, "удаление человека удаляет снимки")
    }

    /// Папка: человек/ролик/кадры (или человек/кадры). Проверка как в жизни:
    /// у кого несколько роликов — учим на первом, узнаём на остальных (другой день, свет, одежда);
    /// у кого один — учим на первой половине, узнаём на второй.
    /// Плюс «незнакомцы»: каждого по очереди убираем из базы и смотрим, отвергнет ли его порог.
    static func accuracy(_ dir: String) {
        let eng = FaceEngine()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir)
        func subdirs(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix("_") }
                .sorted { $0.path < $1.path }
        }
        func images(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
        }
        let out = root.appendingPathComponent("_crops")
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        var names: [Int64: String] = [:]
        var train: [Sample] = [], cross: [Sample] = [], same: [Sample] = []
        var uid: Int64 = 0
        var all: [Sample] = []
        for p in subdirs(root) {
            uid += 1
            names[uid] = p.lastPathComponent
            var clips = subdirs(p)
            if clips.isEmpty { clips = [p] }
            var line = "  \(p.lastPathComponent):"
            for (ci, c) in clips.enumerated() {
                var embs: [Sample] = []
                for f in images(c) {
                    guard let img = CIImage(contentsOf: f, options: [.applyOrientationProperty: true]),
                          let h = eng.largestFace(in: img) else { continue }
                    let s = Sample(id: Int64(all.count), userId: uid, emb: h.emb, version: FaceEngine.version)
                    all.append(s); embs.append(s)
                    if embs.count % 10 == 1 { try? eng.jpeg(h.crop).write(to: out.appendingPathComponent("\(p.lastPathComponent)_\(ci)_\(embs.count).jpg")) }
                }
                line += " \(c.lastPathComponent)=\(embs.count)"
                if clips.count == 1 {
                    train += embs.prefix(embs.count / 2); same += embs.suffix(from: embs.count / 2)
                } else if ci == 0 { train += embs } else { cross += embs }
            }
            print(line)
        }
        guard names.count >= 2 else { print("  нужно минимум 2 человека"); return }
        func q(_ a: [Float], _ p: Double) -> Float { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }

        let rec = Recognizer()
        rec.margin = 0
        rec.rebuild(train)
        func evaluate(_ set: [Sample], _ title: String) -> Double {
            guard !set.isEmpty else { return 1 }
            var ok = 0, okD: [Float] = [], conf: [String: Int] = [:]
            var votesOk = 0, votesN = 0
            var window: [Int64] = []
            var prevUser: Int64 = -9
            for s in set {
                let m = rec.match(s.emb)
                if m.best == s.userId { ok += 1; okD.append(m.dist) }
                else { conf["\(names[s.userId]!)→\(names[m.best ?? 0] ?? "?")", default: 0] += 1 }
                // Голосование как в треке: большинство из 8 последних кадров (2 кадра/с = 4 с).
                if s.userId != prevUser { window = []; prevUser = s.userId }
                window.append(m.best ?? 0); if window.count > 8 { window.removeFirst() }
                if window.count >= 3 {
                    var c: [Int64: Int] = [:]; for w in window { c[w, default: 0] += 1 }
                    votesN += 1
                    if c.max(by: { $0.value < $1.value })!.key == s.userId { votesOk += 1 }
                }
            }
            let acc = Double(ok) / Double(set.count)
            print(String(format: "  %@: по кадру %.1f%% (%d из %d), с голосованием трека %.1f%%; расстояние до верного: медиана %.3f, 90%% %.3f",
                         title, acc * 100, ok, set.count, Double(votesOk) / Double(max(votesN, 1)) * 100, q(okD, 0.5), q(okD, 0.9)))
            if !conf.isEmpty { print("    путает: " + conf.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
            return acc
        }
        let accSame = evaluate(same, "тот же ролик")
        let accCross = evaluate(cross, "другой ролик")

        // Незнакомцы: человек убран из базы — какое расстояние до ближайшего чужого?
        var strangerD: [Float] = []
        let test = same + cross
        for (u, _) in names {
            let r2 = Recognizer(); r2.rebuild(train.filter { $0.userId != u })
            for s in test where s.userId == u { strangerD.append(r2.match(s.emb).dist) }
        }
        var knownD: [(Float, Bool)] = test.map { let m = rec.match($0.emb); return (m.dist, m.best == $0.userId) }
        knownD.sort { $0.0 < $1.0 }
        print("  порог → узнаёт своих верно / принимает чужого за своего:")
        for t in stride(from: Float(0.25), through: 0.6, by: 0.05) {
            let acc = Float(knownD.filter { $0.0 <= t && $0.1 }.count) / Float(knownD.count)
            let far = Float(strangerD.filter { $0 <= t }.count) / Float(max(strangerD.count, 1))
            print(String(format: "    %.2f → %5.1f%% / %5.1f%%", t, acc * 100, far * 100))
        }
        print("  кропы лиц: \(out.path)")
        check(accSame >= 0.9, "тот же ролик ≥ 90%")
        check(accCross >= 0.8, "другой ролик ≥ 80%")
    }

    /// Импорт фото в базу: каждая подпапка — человек (имя = имя папки), фото можно класть и глубже.
    static func importFolder(_ dir: String, db: String) -> Bool {
        let eng = FaceEngine()
        let store = Store(path: db)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir)
        let people = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix("_") }
        for p in people.sorted(by: { $0.path < $1.path }) {
            let name = p.lastPathComponent
            let uid = store.people().first { $0.name == name }?.id ?? store.addPerson(name)
            var n = 0
            let en = fm.enumerator(at: p, includingPropertiesForKeys: nil)
            while let f = en?.nextObject() as? URL {
                guard ["jpg", "jpeg", "png", "heic"].contains(f.pathExtension.lowercased()),
                      let img = CIImage(contentsOf: f, options: [.applyOrientationProperty: true]),
                      let h = eng.largestFace(in: img) else { continue }
                store.addSample(user: uid, emb: h.emb, version: FaceEngine.version, jpeg: eng.jpeg(h.crop), source: "import")
                n += 1
            }
            print("\(name): добавлено \(n) лиц")
        }
        return true
    }
}
