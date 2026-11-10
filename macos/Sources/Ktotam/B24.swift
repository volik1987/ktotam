import Foundation
import AppKit

/// Сотрудник портала.
struct B24Person: Identifiable, Hashable {
    var id: Int
    var name: String
    var position: String
}

enum B24Error: Error { case unauthorized, http(Int), bad }

/// Связь с Битрикс24 (обвязка «Кто там» на портале: /ade/claude/ktotam/).
///
/// Подключение: приложение просит код, сотрудник подтверждает его на портале под своей учёткой,
/// приложение получает токен. Дальше сообщает «появился / ушёл» (только id сотрудника и время —
/// никаких фото и векторов), раз в 30 с шлёт пульс «кто перед экраном», а long-poll забирает
/// голосовые сообщения. Все поля — на главном потоке, сеть — через async URLSession.
@MainActor
final class B24Client: ObservableObject {
    enum State { case off, pairing, connected, error }

    nonisolated static let api = "/ade/claude/ktotam/api.php"
    static let heartbeat: TimeInterval = 30

    @Published var state: State = .off
    @Published var status = ""
    @Published var code = ""
    @Published var pairURL: URL?
    @Published var people: [B24Person] = []
    @Published var userName = ""

    var openBrowser = true
    var onMessage: ((String) -> Void)?   // текст с портала — проговорить
    var onNote: ((String) -> Void)?      // строка в журнал

    private let d: UserDefaults
    private var gen = 0
    private var events: [[String: Any]] = []
    private var present: [Int] = []
    private var persons: [[String: Any]]?
    private var personsSent: Data?
    private var kick = false

    init(defaults: UserDefaults) {
        d = defaults
        userName = d.string(forKey: "b24_user_name") ?? ""
        if connected { start() }
    }

    var url: String { d.string(forKey: "b24_url") ?? "" }
    private var device: String { d.string(forKey: "b24_device") ?? "" }
    private var token: String { d.string(forKey: "b24_token") ?? "" }
    var connected: Bool { !url.isEmpty && !device.isEmpty && !token.isEmpty }

    /// «crm.example.ru/ade/...» → «https://crm.example.ru»
    static func normalize(_ s: String) -> String {
        var u = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return "" }
        if u.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil { u = "https://" + u }
        guard let r = u.range(of: "^https?://[^/?#]+", options: [.regularExpression, .caseInsensitive]) else { return "" }
        return String(u[r]).lowercased()
    }

    // MARK: от модели

    func event(_ type: String, user: Int64, name: String) {
        guard connected else { return }
        events.append(["type": type, "user": user, "name": name])
        if events.count > 200 { events.removeFirst(events.count - 200) }
        kick = true
    }

    func setPresent(_ users: [Int64]) {
        present = Array(Set(users.filter { $0 > 0 }.map { Int($0) })).sorted()
    }

    func setPersons(_ list: [Person]) {
        persons = list.map { ["name": $0.name, "user": $0.b24, "samples": $0.count] }
        kick = true
    }

    // MARK: подключение

    func connect(_ address: String) {
        let u = B24Client.normalize(address)
        guard !u.isEmpty else { state = .error; status = "Впишите адрес портала, например crm.example.ru"; return }
        disconnect(localOnly: true)
        d.set(u, forKey: "b24_url")
        gen += 1
        let g = gen
        state = .pairing; status = "Запрашиваю код…"; code = ""
        Task { await pair(g, u) }
    }

    func disconnect(localOnly: Bool = false) {
        if connected && !localOnly {
            let (u, dev, tok) = (url, device, token)
            Task { _ = try? await B24Client.http(u, "unpair", body: [:], headers: B24Client.auth(dev, tok)) }
        }
        gen += 1
        for k in ["b24_device", "b24_token", "b24_user", "b24_user_name"] { d.removeObject(forKey: k) }
        state = .off; status = ""; code = ""; pairURL = nil; people = []; userName = ""
        personsSent = nil
    }

    private func pair(_ g: Int, _ u: String) async {
        let host = Host.current().localizedName ?? "Mac"
        let r: [String: Any]
        do { r = try await B24Client.http(u, "pair_start", body: ["name": String(host.prefix(60))]) } catch {
            if g == gen { state = .error; status = "Портал не ответил: \(B24Client.describe(error))" }
            return
        }
        guard g == gen, let c = r["code"] as? String, let secret = r["secret"] as? String,
              let link = (r["url"] as? String).flatMap(URL.init(string:)) else {
            if g == gen { state = .error; status = "Ответ не похож на портал с «Кто там»" }
            return
        }
        code = c; pairURL = link
        status = "Подтвердите код на портале (страница открылась в браузере)"
        if openBrowser { NSWorkspace.shared.open(link) }
        let deadline = Date().addingTimeInterval((r["expires"] as? Double) ?? 600)
        while g == gen && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard g == gen else { return }
            let p: [String: Any]
            do { p = try await B24Client.http(u, "pair_poll", body: ["code": c, "secret": secret]) } catch B24Error.http(404) {
                break
            } catch { continue }
            if p["wait"] != nil { continue }
            guard g == gen, let dev = p["device"] as? String, let tok = p["token"] as? String,
                  let user = p["user"] as? [String: Any] else { continue }
            d.set(dev, forKey: "b24_device")
            d.set(tok, forKey: "b24_token")
            d.set(user["id"] as? Int ?? 0, forKey: "b24_user")
            userName = user["name"] as? String ?? ""
            d.set(userName, forKey: "b24_user_name")
            code = ""; pairURL = nil
            onNote?("🔗 Подключено к Битрикс24: \(userName)")
            start()
            return
        }
        if g == gen { state = .error; status = "Код не подтвердили за 10 минут — нажмите «Подключить» ещё раз"; code = "" }
    }

    private func start() {
        gen += 1
        let g = gen
        state = .connected; status = "Подключено"
        personsSent = nil
        Task { await mainLoop(g) }
        Task { await pullLoop(g) }
    }

    // MARK: рабочие циклы

    private func mainLoop(_ g: Int) async {
        var lastBeat = Date.distantPast, lastPeople = Date.distantPast, fails = 0
        while g == gen {
            do {
                if Date().timeIntervalSince(lastPeople) > 600 {
                    let r = try await call("people", method: "GET")
                    people = (r["people"] as? [[String: Any]] ?? []).compactMap {
                        guard let id = $0["id"] as? Int else { return nil }
                        return B24Person(id: id, name: $0["name"] as? String ?? "#\(id)", position: $0["position"] as? String ?? "")
                    }
                    lastPeople = Date()
                }
                if let p = persons, let data = try? JSONSerialization.data(withJSONObject: p), data != personsSent {
                    _ = try await call("sync", body: ["persons": p])
                    personsSent = data
                }
                while g == gen, let ev = events.first {
                    _ = try await call("event", body: ev)
                    if !events.isEmpty { events.removeFirst() }
                }
                if Date().timeIntervalSince(lastBeat) > B24Client.heartbeat {
                    _ = try await call("status", body: ["present": present])
                    lastBeat = Date()
                }
                if fails > 0 { onNote?("🔗 Связь с Битрикс24 восстановлена") }
                fails = 0
                if g == gen { state = .connected; status = "Подключено" }
            } catch B24Error.unauthorized {
                revoked(g); return
            } catch {
                guard g == gen else { return }
                fails += 1
                if fails == 1 { onNote?("🔗 Нет связи с Битрикс24: \(B24Client.describe(error))") }
                state = .error; status = "Нет связи с порталом: \(B24Client.describe(error)) — повторяю"
                try? await Task.sleep(nanoseconds: UInt64(min(60, 5 * fails)) * 1_000_000_000)
                continue
            }
            // Ждём до 5 с, но просыпаемся сразу, если появилось событие
            for _ in 0..<25 where g == gen && !kick { try? await Task.sleep(nanoseconds: 200_000_000) }
            kick = false
        }
    }

    private func pullLoop(_ g: Int) async {
        var fails = 0
        while g == gen {
            do {
                let r = try await call("pull", method: "GET", query: "&wait=25", timeout: 40)
                let items = r["items"] as? [[String: Any]] ?? []
                guard g == gen else { return }
                for it in items { if let t = it["text"] as? String { onMessage?(t) } }
                if !items.isEmpty { _ = try await call("ack", body: ["ids": items.compactMap { $0["id"] as? Int }]) }
                fails = 0
            } catch B24Error.unauthorized {
                revoked(g); return
            } catch {
                fails += 1
                try? await Task.sleep(nanoseconds: UInt64(min(60, 3 * fails)) * 1_000_000_000)
            }
        }
    }

    private func revoked(_ g: Int) {
        guard g == gen else { return }
        onNote?("🔗 Портал отключил это приложение — подключите заново")
        disconnect(localOnly: true)
        state = .error; status = "Приложение отключено на портале — подключите заново"
    }

    // MARK: HTTP

    private static func auth(_ dev: String, _ tok: String) -> [String: String] {
        ["X-Ktotam-Device": dev, "X-Ktotam-Token": tok]
    }

    private func call(_ action: String, body: [String: Any]? = nil, method: String = "POST",
                      query: String = "", timeout: TimeInterval = 15) async throws -> [String: Any] {
        try await B24Client.http(url, action, body: body, method: method, query: query, timeout: timeout,
                                 headers: B24Client.auth(device, token))
    }

    nonisolated static func http(_ base: String, _ action: String, body: [String: Any]? = nil, method: String = "POST",
                                 query: String = "", timeout: TimeInterval = 15,
                                 headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let u = URL(string: "\(base)\(api)?action=\(action)\(query)") else { throw B24Error.bad }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Ktotam", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw B24Error.unauthorized }
        if code != 200 { throw B24Error.http(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw B24Error.bad }
        return obj
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case B24Error.http(let c): return "ошибка \(c)"
        case B24Error.bad: return "ответ не похож на портал с «Кто там»"
        case let u as URLError: return u.localizedDescription
        default: return String(describing: e).prefix(80).description
        }
    }
}
