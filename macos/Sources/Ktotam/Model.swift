import Foundation
import SwiftUI
import AVFoundation
import CoreImage

/// Лицо в кадре для интерфейса.
struct LiveFace: Identifiable {
    var id: Int            // id трека
    var rect: CGRect       // доли кадра, Vision (снизу слева)
    var label: Int64?      // устойчивая метка: nil — думаем, -1 — незнакомец
    var match: Match
    var crop: CGImage
    var emb: [Float]
}

/// Снимок для проверки: «программа думала, что это …» — пользователь подтверждает или поправляет.
struct Review: Identifiable {
    let id = UUID()
    var crop: CGImage
    var emb: [Float]
    var match: Match
    var time: Date
    var resolved: String?
}

struct EventLine: Identifiable {
    let id = UUID()
    var time: Date
    var text: String
}

/// Куда отнести лицо при поправке.
enum Target: Equatable {
    case live(Int)
    case review(UUID)
    case none
}

final class Speaker {
    private let synth = AVSpeechSynthesizer()
    var voiceId: String = ""

    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: voiceId) ?? Speaker.russianVoices().first
            ?? AVSpeechSynthesisVoice(language: "ru-RU")
        synth.speak(u)
    }
}

@MainActor
final class Model: ObservableObject {
    let store: Store
    let engine = FaceEngine()
    let rec = Recognizer()
    let tracker = Tracker()
    var presence = Presence()
    let camera = Camera()
    let speaker = Speaker()

    @Published var frame: CGImage?
    @Published var faces: [LiveFace] = []
    @Published var people: [Person] = []
    @Published var reviews: [Review] = []
    @Published var events: [EventLine] = []
    @Published var status = "Запуск камеры…"
    @Published var revision = 0                // меняется при правке базы — обновить миниатюры
    @Published var enrollUser: Int64?
    @Published var enrollLeft = 0
    @Published var presentNames: [String] = []

    /// --defaults <имя>: отдельные настройки для тестов
    private let d = Args.value("--defaults").flatMap { UserDefaults(suiteName: $0) } ?? .standard
    let b24: B24Client
    @Published var threshold: Double { didSet { d.set(threshold, forKey: "threshold"); rec.threshold = Float(threshold) } }
    @Published var absence: Double { didSet { d.set(absence, forKey: "absence"); presence.absence = absence } }
    @Published var speak: Bool { didSet { d.set(speak, forKey: "speak") } }
    @Published var greetUnknown: Bool { didSet { d.set(greetUnknown, forKey: "greetUnknown") } }
    @Published var autoLearn: Bool { didSet { d.set(autoLearn, forKey: "autoLearn") } }
    @Published var mirror: Bool { didSet { d.set(mirror, forKey: "mirror") } }
    @Published var voiceId: String { didSet { d.set(voiceId, forKey: "voiceId"); speaker.voiceId = voiceId } }
    @Published var cameraId: String { didSet { d.set(cameraId, forKey: "cameraId"); startCamera() } }

    private var lastEnroll: TimeInterval = 0
    private var lastAuto: [Int64: TimeInterval] = [:]
    private var fakeFolder: URL?
    var reviewEvery: TimeInterval = 8

    init(dbPath: String = Store.defaultPath, fakeFolder: URL? = nil) {
        store = Store(path: dbPath)
        b24 = B24Client(defaults: d)
        self.fakeFolder = fakeFolder
        d.register(defaults: ["threshold": 0.95, "absence": 3.0, "speak": true, "greetUnknown": false,
                              "autoLearn": false, "mirror": true])
        // Порог зависит от модели: при переходе на SFace (версия 3) старое значение не подходит.
        if d.integer(forKey: "engineVersion") != FaceEngine.version {
            d.removeObject(forKey: "threshold")
            d.set(FaceEngine.version, forKey: "engineVersion")
        }
        threshold = d.double(forKey: "threshold")
        absence = d.double(forKey: "absence")
        speak = d.bool(forKey: "speak")
        greetUnknown = d.bool(forKey: "greetUnknown")
        autoLearn = d.bool(forKey: "autoLearn")
        mirror = d.bool(forKey: "mirror")
        voiceId = d.string(forKey: "voiceId") ?? ""
        cameraId = d.string(forKey: "cameraId") ?? ""
        rec.threshold = Float(threshold)
        presence.absence = absence
        speaker.voiceId = voiceId
        b24.onNote = { [weak self] s in self?.log(s) }
        b24.onMessage = { [weak self] s in
            self?.log("🔊 " + s)
            if !Args.has("--mute") { self?.speaker.say(s) }
        }
        refreshPeople()
        migrateEmbeddings()
        rec.rebuild(store.samples())

        let engine = self.engine
        camera.onFrame = { [weak self] img in
            // Очередь камеры: тяжёлая часть (поиск лиц, признаки, картинка для экрана).
            let hits = engine.analyze(img)
            let scale = min(1, 960 / img.extent.width)
            let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let shown = engine.ci.createCGImage(small, from: small.extent)
            let now = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { self?.ingest(hits, shown: shown, now: now) }
        }
        startCamera()
    }

    func startCamera() {
        if let f = fakeFolder { camera.startFake(folder: f); status = "Тестовый режим: фото из папки"; return }
        Camera.requestAccess { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.status = "Нет доступа к камере: Системные настройки → Конфиденциальность → Камера"
                return
            }
            if let err = self.camera.start(deviceId: self.cameraId.isEmpty ? nil : self.cameraId) {
                self.status = err
            } else { self.status = "" }
        }
    }

    /// Снимки, посчитанные старым алгоритмом, пересчитываем из сохранённых кропов.
    /// Кропы 160 (версии 1–2, VNFeaturePrint) переводим в кроп 112 для SFace по известному положению глаз.
    private func migrateEmbeddings() {
        var n = 0
        for s in store.samples() where s.version != FaceEngine.version {
            guard let j = store.jpeg(of: s.id), var img = FaceEngine.cgImage(jpeg: j) else { continue }
            if s.version < 3 && img.width != Int(FaceEngine.side) {
                guard let r = engine.realignOld(img) else { continue }
                img = r
            }
            guard let e = engine.embedding(img) else { continue }
            store.replaceSample(s.id, jpeg: engine.jpeg(img), emb: e, version: FaceEngine.version)
            n += 1
        }
        if n > 0 { log("База переведена на новую модель SFace: пересчитано снимков \(n)") }
    }

    func refreshPeople() {
        people = store.people()
        revision += 1
        b24.setPersons(people)
    }

    func b24Of(_ id: Int64) -> Int { people.first { $0.id == id }?.b24 ?? 0 }

    /// Связать человека из базы с сотрудником портала (0 — отвязать).
    func linkB24(_ id: Int64, _ b24: Int) {
        store.setB24(id, b24)
        refreshPeople()
    }

    func name(_ id: Int64?) -> String {
        guard let id else { return "?" }
        if id == Track.unknown { return "незнакомец" }
        return people.first { $0.id == id }?.name ?? "?"
    }

    // MARK: кадр

    func ingest(_ hits: [FaceHit], shown: CGImage?, now: TimeInterval) {
        frame = shown
        let tracks = tracker.update(hits.map { $0.rect }, now: now)
        var live: [LiveFace] = []
        for (h, t) in zip(hits, tracks) {
            let m = rec.match(h.emb)
            t.hit = h
            t.match = m
            t.vote(m.known ? m.best! : Track.unknown)
            // После поправки добираем ещё снимков этого лица к правильному человеку.
            if let u = t.pinned, t.boostLeft > 0, now - t.lastBoost > 0.4, abs(h.yaw) < 0.5 {
                t.lastBoost = now
                t.boostLeft -= 1
                addSample(h.crop, h.emb, to: u, source: "fix+", refresh: t.boostLeft == 0)
            }
            live.append(LiveFace(id: t.id, rect: h.rect, label: t.label, match: m, crop: h.crop, emb: h.emb))

            // Снимок на проверку: когда лицо определилось и потом раз в reviewEvery секунд.
            if t.label != nil && now - t.lastSnap > reviewEvery && abs(h.yaw) < 0.5 {
                t.lastSnap = now
                reviews.insert(Review(crop: h.crop, emb: h.emb, match: m, time: Date()), at: 0)
                if reviews.count > 120 { reviews.removeLast(reviews.count - 120) }
            }
            // Самообучение: уверенные снимки сами пополняют базу (по умолчанию выключено).
            if autoLearn, m.known, let u = m.best, t.label == u, m.dist < Float(threshold) * 0.75,
               now - (lastAuto[u] ?? 0) > 5, abs(h.yaw) < 0.4 {
                lastAuto[u] = now
                addSample(h.crop, h.emb, to: u, source: "auto", refresh: false)
            }
        }

        // Серия снимков для выбранного человека: самое крупное лицо, 4 снимка в секунду.
        if let u = enrollUser, enrollLeft > 0, now - lastEnroll > 0.25,
           let i = hits.indices.max(by: { hits[$0].px < hits[$1].px }), abs(hits[i].yaw) < 0.7 {
            lastEnroll = now
            addSample(hits[i].crop, hits[i].emb, to: u, source: "enroll", refresh: false)
            tracks[i].force(u)
            enrollLeft -= 1
            if enrollLeft == 0 { enrollUser = nil; refreshPeople(); log("Серия снимков для «\(name(u))» готова") }
        }
        faces = live

        // Кто перед компом.
        var visible = Set<Int64>()
        for t in tracker.tracks {
            guard let l = t.label else { continue }
            if l > 0 || (l == Track.unknown && greetUnknown) { visible.insert(l) }
        }
        let (hello, bye) = presence.step(visible: visible, now: now)
        for u in bye { greet(u, hello: false) }
        for u in hello { greet(u, hello: true) }
        presentNames = presence.present.filter { $0 > 0 }.map { name($0) }.sorted()
        b24.setPresent(presence.present.filter { $0 > 0 }.map { Int64(b24Of($0)) })
    }

    private func greet(_ u: Int64, hello: Bool) {
        let who = u == Track.unknown ? "незнакомец" : name(u)
        let text = hello ? "Привет, \(who)!" : "Пока, \(who)!"
        log((hello ? "👋 " : "🚪 ") + text)
        if speak && !Args.has("--mute") { speaker.say(text) }
        b24.event(hello ? "appeared" : "left", user: u > 0 ? Int64(b24Of(u)) : 0, name: u > 0 ? who : "")
    }

    /// Для --b24-test: приветствие/прощание без камеры.
    func greetForTest(_ u: Int64, hello: Bool) {
        greet(u, hello: hello)
        b24.setPresent(hello ? [Int64(b24Of(u))] : [])
    }

    func log(_ s: String) {
        print(String(format: "%.1f", ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1000)), "событие:", s)
        events.insert(EventLine(time: Date(), text: s), at: 0)
        if events.count > 300 { events.removeLast() }
    }

    // MARK: обучение

    private func addSample(_ crop: CGImage, _ emb: [Float], to u: Int64, source: String, refresh: Bool = true) {
        store.addSample(user: u, emb: emb, version: FaceEngine.version, jpeg: engine.jpeg(crop), source: source)
        rec.add(emb, to: u)
        if refresh { refreshPeople() }
    }

    private func faceFor(_ target: Target) -> (CGImage, [Float], Match)? {
        switch target {
        case .live(let id): return faces.first { $0.id == id }.map { ($0.crop, $0.emb, $0.match) }
        case .review(let id): return reviews.first { $0.id == id }.map { ($0.crop, $0.emb, $0.match) }
        case .none: return nil
        }
    }

    /// «Да, это он» — снимок в базу к угаданному человеку.
    func confirm(_ target: Target) {
        guard let (_, _, m) = faceFor(target), let u = m.best else { return }
        assign(target, to: u)
    }

    /// «Нет, это …» — снимок в базу к указанному человеку; живой трек сразу переименовываем.
    func assign(_ target: Target, to u: Int64) {
        guard let (crop, emb, m) = faceFor(target) else { return }
        addSample(crop, emb, to: u, source: m.best == u ? "confirm" : "fix")
        switch target {
        case .live(let id):
            if let t = tracker.tracks.first(where: { $0.id == id }) {
                let old = t.label
                t.force(u, pin: true)
                t.boostLeft = m.best == u ? 2 : 6
                t.lastBoost = ProcessInfo.processInfo.systemUptime
                // Ошибочно узнанного не провожаем «пока», если его больше нет в кадре.
                if let old, old != u, !tracker.tracks.contains(where: { $0 !== t && $0.label == old }) {
                    presence.forget(old)
                }
            }
        case .review(let id):
            if let i = reviews.firstIndex(where: { $0.id == id }) {
                reviews[i].resolved = (m.best == u ? "✓ " : "→ ") + name(u)
            }
        case .none: break
        }
        if m.best != u { log("Поправка: это «\(name(u))», а не «\(name(m.best))»") }
    }

    func dismiss(_ id: UUID) {
        if let i = reviews.firstIndex(where: { $0.id == id }) { reviews[i].resolved = "✗ пропущено" }
    }

    @discardableResult
    func addPerson(_ name: String, from target: Target = .none) -> Int64? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let id = store.addPerson(n)
        refreshPeople()
        log("Новый человек: «\(n)»")
        if target != .none { assign(target, to: id) }
        return id
    }

    func rename(_ id: Int64, _ n: String) {
        let n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        store.rename(id, n)
        refreshPeople()
    }

    func deletePerson(_ id: Int64) {
        store.deletePerson(id)
        presence.forget(id)
        for t in tracker.tracks where t.label == id { t.votes = []; t.label = nil }
        rec.rebuild(store.samples())
        refreshPeople()
    }

    func deleteSample(_ id: Int64) {
        store.deleteSample(id)
        rec.rebuild(store.samples())
        refreshPeople()
    }

    func moveSample(_ id: Int64, to u: Int64) {
        store.moveSample(id, to: u)
        rec.rebuild(store.samples())
        refreshPeople()
    }

    func startEnroll(_ u: Int64, count: Int = 20) {
        enrollUser = u
        enrollLeft = count
        log("Снимаю серию для «\(name(u))»: смотрите в камеру, поворачивайте голову")
    }

    func stopEnroll() { enrollUser = nil; enrollLeft = 0; refreshPeople() }
}
