import Foundation
import SQLite3

/// Человек в базе.
struct Person: Identifiable, Hashable {
    var id: Int64
    var name: String
    var count: Int
}

/// Образец лица: выровненный кроп 160×160 (JPEG) + вектор признаков.
struct Sample {
    var id: Int64
    var userId: Int64
    var emb: [Float]
    var version: Int
}

/// База лиц на SQLite: users (люди) и samples (снимки лиц).
/// Кроп лица хранится целиком, поэтому векторы можно пересчитать при смене алгоритма.
final class Store {
    private var db: OpaquePointer?
    let path: String
    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if sqlite3_open(path, &db) != SQLITE_OK { fatalError("Не открыть базу \(path)") }
        exec("PRAGMA foreign_keys=ON")
        exec("""
        CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created REAL);
        CREATE TABLE IF NOT EXISTS samples(id INTEGER PRIMARY KEY,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            emb BLOB, version INTEGER, jpeg BLOB, created REAL, source TEXT);
        CREATE INDEX IF NOT EXISTS samples_user ON samples(user_id);
        """)
    }
    deinit { sqlite3_close(db) }

    static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ktotam/faces.sqlite").path
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { print("SQL:", String(cString: err)); sqlite3_free(err) }
            return false
        }
        return true
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) != SQLITE_OK {
            print("SQL prepare:", String(cString: sqlite3_errmsg(db)), sql)
            return nil
        }
        return st
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ d: Data) {
        d.withUnsafeBytes { p in _ = sqlite3_bind_blob(st, i, p.baseAddress, Int32(d.count), TRANSIENT) }
    }

    private func blob(_ st: OpaquePointer?, _ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
    }

    // MARK: люди

    func people() -> [Person] {
        let st = prepare("""
            SELECT u.id, u.name, (SELECT COUNT(*) FROM samples s WHERE s.user_id=u.id)
            FROM users u ORDER BY u.name COLLATE NOCASE
            """)
        defer { sqlite3_finalize(st) }
        var out: [Person] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(Person(id: sqlite3_column_int64(st, 0),
                              name: String(cString: sqlite3_column_text(st, 1)),
                              count: Int(sqlite3_column_int(st, 2))))
        }
        return out
    }

    func addPerson(_ name: String) -> Int64 {
        let st = prepare("INSERT INTO users(name, created) VALUES(?, ?)")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, name, -1, TRANSIENT)
        sqlite3_bind_double(st, 2, Date().timeIntervalSince1970)
        sqlite3_step(st)
        return sqlite3_last_insert_rowid(db)
    }

    func rename(_ id: Int64, _ name: String) {
        let st = prepare("UPDATE users SET name=? WHERE id=?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, name, -1, TRANSIENT)
        sqlite3_bind_int64(st, 2, id)
        sqlite3_step(st)
    }

    func deletePerson(_ id: Int64) {
        let st = prepare("DELETE FROM users WHERE id=?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, id)
        sqlite3_step(st)
    }

    // MARK: образцы

    @discardableResult
    func addSample(user: Int64, emb: [Float], version: Int, jpeg: Data, source: String) -> Int64 {
        let st = prepare("INSERT INTO samples(user_id, emb, version, jpeg, created, source) VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, user)
        bind(st, 2, emb.withUnsafeBufferPointer { Data(buffer: $0) })
        sqlite3_bind_int(st, 3, Int32(version))
        bind(st, 4, jpeg)
        sqlite3_bind_double(st, 5, Date().timeIntervalSince1970)
        sqlite3_bind_text(st, 6, source, -1, TRANSIENT)
        sqlite3_step(st)
        return sqlite3_last_insert_rowid(db)
    }

    func samples() -> [Sample] {
        let st = prepare("SELECT id, user_id, emb, version FROM samples")
        defer { sqlite3_finalize(st) }
        var out: [Sample] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let d = blob(st, 2)
            let emb: [Float] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            out.append(Sample(id: sqlite3_column_int64(st, 0), userId: sqlite3_column_int64(st, 1),
                              emb: emb, version: Int(sqlite3_column_int(st, 3))))
        }
        return out
    }

    /// Снимки человека (новые сверху): id и JPEG.
    func thumbs(of user: Int64, limit: Int = 200) -> [(Int64, Data)] {
        let st = prepare("SELECT id, jpeg FROM samples WHERE user_id=? ORDER BY id DESC LIMIT ?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, user)
        sqlite3_bind_int(st, 2, Int32(limit))
        var out: [(Int64, Data)] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append((sqlite3_column_int64(st, 0), blob(st, 1))) }
        return out
    }

    func jpeg(of sample: Int64) -> Data? {
        let st = prepare("SELECT jpeg FROM samples WHERE id=?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, sample)
        return sqlite3_step(st) == SQLITE_ROW ? blob(st, 0) : nil
    }

    func updateEmb(_ sample: Int64, _ emb: [Float], version: Int) {
        let st = prepare("UPDATE samples SET emb=?, version=? WHERE id=?")
        defer { sqlite3_finalize(st) }
        bind(st, 1, emb.withUnsafeBufferPointer { Data(buffer: $0) })
        sqlite3_bind_int(st, 2, Int32(version))
        sqlite3_bind_int64(st, 3, sample)
        sqlite3_step(st)
    }

    func deleteSample(_ id: Int64) {
        let st = prepare("DELETE FROM samples WHERE id=?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, id)
        sqlite3_step(st)
    }

    func moveSample(_ id: Int64, to user: Int64) {
        let st = prepare("UPDATE samples SET user_id=? WHERE id=?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, user)
        sqlite3_bind_int64(st, 2, id)
        sqlite3_step(st)
    }
}
