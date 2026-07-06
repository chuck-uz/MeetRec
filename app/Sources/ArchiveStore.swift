// Локальный индекс архива встреч для поиска по всем транскриптам (RAG).
// Хранилище — системный SQLite (FTS5 + вектора BLOB), без внешних зависимостей.
import Accelerate
import Foundation
import SQLite3

/// Фрагмент транскрипта — единица индексации и извлечения.
struct TranscriptChunk {
    let meetingID: String      // имя файла записи без расширения
    let title: String
    let date: Date
    let tsStart: Int           // миллисекунды от начала встречи
    let speaker: String?
    let text: String
}

/// Результат поиска: фрагмент + релевантность + откуда он.
struct ArchiveHit: Identifiable {
    let id = UUID()
    let title: String
    let date: Date
    let tsStart: Int
    let speaker: String?
    let text: String
    let transcriptPath: String
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor ArchiveStore {
    static let shared = ArchiveStore()

    private var db: OpaquePointer?

    static var dbURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec/archive.sqlite")
    }

    private func open() throws {
        guard db == nil else { return }
        let url = Self.dbURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw MeetRecError("Не удалось открыть индекс архива.")
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS meetings(
                id TEXT PRIMARY KEY, title TEXT, date REAL,
                path TEXT, mtime REAL);
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id TEXT, ts_start INTEGER, speaker TEXT,
                text TEXT, embedding BLOB);
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_chunks_meeting ON chunks(meeting_id);")
        // FTS5 для ключевого поиска; trigram терпим к русской морфологии.
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                text, content='chunks', content_rowid='id',
                tokenize='trigram');
        """)
    }

    // MARK: - Индексация

    /// Нужно ли переиндексировать встречу (новая или транскрипт изменился).
    func needsIndex(meetingID: String, mtime: Date) -> Bool {
        (try? open()) != nil
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "SELECT mtime FROM meetings WHERE id=?;", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, meetingID, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0) < mtime.timeIntervalSince1970 - 0.5
        }
        return true
    }

    /// Полностью переиндексирует одну встречу.
    func replace(
        meetingID: String, title: String, date: Date,
        path: String, mtime: Date,
        chunks: [(chunk: TranscriptChunk, embedding: [Float])]
    ) throws {
        try open()
        exec("BEGIN;")
        deleteChunks(meetingID: meetingID)

        var meetingStmt: OpaquePointer?
        sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO meetings(id,title,date,path,mtime) VALUES(?,?,?,?,?);",
            -1, &meetingStmt, nil)
        sqlite3_bind_text(meetingStmt, 1, meetingID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(meetingStmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(meetingStmt, 3, date.timeIntervalSince1970)
        sqlite3_bind_text(meetingStmt, 4, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(meetingStmt, 5, mtime.timeIntervalSince1970)
        sqlite3_step(meetingStmt)
        sqlite3_finalize(meetingStmt)

        for (chunk, embedding) in chunks {
            var normalized = embedding
            var norm: Float = 0
            vDSP_svesq(embedding, 1, &norm, vDSP_Length(embedding.count))
            norm = sqrt(norm)
            if norm > 0 {
                var inv = 1 / norm
                vDSP_vsmul(embedding, 1, &inv, &normalized, 1, vDSP_Length(embedding.count))
            }
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db,
                "INSERT INTO chunks(meeting_id,ts_start,speaker,text,embedding) VALUES(?,?,?,?,?);",
                -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, meetingID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(chunk.tsStart))
            if let speaker = chunk.speaker {
                sqlite3_bind_text(stmt, 3, speaker, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, chunk.text, -1, SQLITE_TRANSIENT)
            normalized.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 5, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
            let rowid = sqlite3_last_insert_rowid(db)
            sqlite3_finalize(stmt)

            var fts: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO chunks_fts(rowid,text) VALUES(?,?);", -1, &fts, nil)
            sqlite3_bind_int64(fts, 1, rowid)
            sqlite3_bind_text(fts, 2, chunk.text, -1, SQLITE_TRANSIENT)
            sqlite3_step(fts)
            sqlite3_finalize(fts)
        }
        exec("COMMIT;")
    }

    func removeMissing(existingIDs: Set<String>) {
        (try? open()) != nil
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM meetings;", -1, &stmt, nil)
        var stale: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                let id = String(cString: c)
                if !existingIDs.contains(id) { stale.append(id) }
            }
        }
        sqlite3_finalize(stmt)
        for id in stale {
            exec("BEGIN;")
            deleteChunks(meetingID: id)
            var del: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM meetings WHERE id=?;", -1, &del, nil)
            sqlite3_bind_text(del, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(del)
            sqlite3_finalize(del)
            exec("COMMIT;")
        }
    }

    var indexedCount: Int {
        (try? open()) != nil
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meetings;", -1, &stmt, nil)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Поиск (гибрид: вектор + FTS5, слияние RRF)

    func search(queryEmbedding: [Float], queryText: String, limit: Int = 8) throws -> [ArchiveHit] {
        try open()
        let vectorRanked = vectorSearch(queryEmbedding, k: 30)
        let keywordRanked = keywordSearch(queryText, k: 30)

        // Reciprocal Rank Fusion
        var score: [Int64: Double] = [:]
        for (rank, id) in vectorRanked.enumerated() {
            score[id, default: 0] += 1.0 / Double(60 + rank)
        }
        for (rank, id) in keywordRanked.enumerated() {
            score[id, default: 0] += 1.0 / Double(60 + rank)
        }
        let topIDs = score.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
        return topIDs.compactMap { loadHit(rowid: $0) }
    }

    private func vectorSearch(_ query: [Float], k: Int) -> [Int64] {
        var q = query
        var norm: Float = 0
        vDSP_svesq(q, 1, &norm, vDSP_Length(q.count))
        norm = sqrt(norm)
        if norm > 0 { var inv = 1 / norm; vDSP_vsmul(q, 1, &inv, &q, 1, vDSP_Length(q.count)) }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "SELECT id, embedding FROM chunks;", -1, &stmt, nil)
        var scored: [(Int64, Float)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let bytes = Int(sqlite3_column_bytes(stmt, 1))
            let count = bytes / MemoryLayout<Float>.size
            guard count == q.count else { continue }
            let vec = blob.withMemoryRebound(to: Float.self, capacity: count) {
                Array(UnsafeBufferPointer(start: $0, count: count))
            }
            var dot: Float = 0
            vDSP_dotpr(q, 1, vec, 1, &dot, vDSP_Length(count)) // косинус (оба нормализованы)
            scored.append((rowid, dot))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(k).map(\.0)
    }

    private func keywordSearch(_ text: String, k: Int) -> [Int64] {
        // Экранируем в фразу — FTS5 иначе трактует спецсимволы как синтаксис.
        let escaped = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,
            "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?;",
            -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, escaped, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(k))
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    private func loadHit(rowid: Int64) -> ArchiveHit? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, """
            SELECT m.title, m.date, c.ts_start, c.speaker, c.text, m.path
            FROM chunks c JOIN meetings m ON c.meeting_id = m.id
            WHERE c.id = ?;
        """, -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, rowid)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func str(_ i: Int32) -> String? {
            sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
        return ArchiveHit(
            title: str(0) ?? "Встреча",
            date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            tsStart: Int(sqlite3_column_int(stmt, 2)),
            speaker: str(3),
            text: str(4) ?? "",
            transcriptPath: str(5) ?? "")
    }

    // MARK: - Утилиты

    private func deleteChunks(meetingID: String) {
        var ids: [Int64] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM chunks WHERE meeting_id=?;", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, meetingID, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        sqlite3_finalize(stmt)
        for id in ids {
            var f: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO chunks_fts(chunks_fts,rowid,text) VALUES('delete',?,(SELECT text FROM chunks WHERE id=?));", -1, &f, nil)
            sqlite3_bind_int64(f, 1, id)
            sqlite3_bind_int64(f, 2, id)
            sqlite3_step(f)
            sqlite3_finalize(f)
        }
        var del: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM chunks WHERE meeting_id=?;", -1, &del, nil)
        sqlite3_bind_text(del, 1, meetingID, -1, SQLITE_TRANSIENT)
        sqlite3_step(del)
        sqlite3_finalize(del)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
