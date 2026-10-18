import Foundation
import SQLite3

struct StoreError: Error, CustomStringConvertible {
  var description: String
}

struct PayloadManifest: Codable {
  struct Entry: Codable {
    var uti: String
    var file: String
  }

  struct Item: Codable {
    var types: [Entry]
  }

  var items: [Item]
}

final class ClipStore {
  let root: URL
  private var db: OpaquePointer?
  private var lastPrune = Date.distantPast
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  static func supportDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Clipbook", isDirectory: true)
  }

  static func prepareSupportDirectory() throws -> URL {
    let url = supportDirectory()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("payloads", isDirectory: true), withIntermediateDirectories: true)
    try open()
    try prune()
    lastPrune = Date()
  }

  deinit {
    if db != nil {
      sqlite3_close(db)
    }
  }

  func upsert(_ clip: RawClip, bumpExisting: Bool) throws -> String {
    let preview = String(clip.preview.prefix(800))
    let search = String(clip.searchText.lowercased().prefix(20_000))
    if let existing = try id(forHash: clip.contentHash) {
      if !bumpExisting { return existing }
      let dir = directory(for: existing)
      try? FileManager.default.removeItem(at: dir)
      try writePayload(clip, id: existing)
      try update(
        id: existing,
        copiedAt: clip.copiedAt,
        kind: clip.kind,
        preview: preview,
        search: search,
        sourceName: clip.sourceName,
        sourceBundle: clip.sourceBundle,
        sourceDevice: clip.sourceDevice,
        byteSize: clip.byteSize
      )
      try pruneIfNeeded()
      return existing
    }
    let id = UUID().uuidString
    try writePayload(clip, id: id)
    try insert(
      id: id,
      copiedAt: clip.copiedAt,
      kind: clip.kind,
      preview: preview,
      search: search,
      sourceName: clip.sourceName,
      sourceBundle: clip.sourceBundle,
      sourceDevice: clip.sourceDevice,
      byteSize: clip.byteSize,
      hash: clip.contentHash
    )
    try pruneIfNeeded()
    return id
  }

  func fetch(kind: ClipKind?, query: String, limit: Int = 500) -> [ClipRecord] {
    let cutoff = Retention.cutoff(from: Date())
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var sql = """
    SELECT id, copied_at, kind, preview, source_name, source_bundle, source_device, byte_size
    FROM clips
    WHERE copied_at >= ?
    """
    if kind != nil { sql += " AND kind = ?" }
    if !trimmed.isEmpty { sql += " AND search_text LIKE ? ESCAPE '\\'" }
    sql += " ORDER BY copied_at DESC LIMIT ?"

    var records: [ClipRecord] = []
    do {
      try queryRows(sql) { stmt in
        var index: Int32 = 1
        sqlite3_bind_double(stmt, index, cutoff.timeIntervalSince1970)
        index += 1
        if let kind {
          bindText(stmt, index, kind.rawValue)
          index += 1
        }
        if !trimmed.isEmpty {
          bindText(stmt, index, likePattern(trimmed))
          index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(limit))
      } row: { stmt in
        records.append(readRecord(stmt))
      }
    } catch {
      log("fetch failed \(error)")
    }
    return records
  }

  func count() -> Int {
    let cutoff = Retention.cutoff(from: Date())
    var total = 0
    do {
      try queryRows("SELECT COUNT(*) FROM clips WHERE copied_at >= ?") { stmt in
        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
      } row: { stmt in
        total = Int(sqlite3_column_int64(stmt, 0))
      }
    } catch {
      log("count failed \(error)")
    }
    return total
  }

  func delete(id: String) {
    guard isSafeID(id) else { return }
    do {
      try execPrepared("DELETE FROM clips WHERE id = ?") { stmt in
        bindText(stmt, 1, id)
      }
      try? FileManager.default.removeItem(at: directory(for: id))
    } catch {
      log("delete failed \(error)")
    }
  }

  func pruneNow() throws {
    try prune()
  }

  func deleteAll() {
    do {
      try exec("DELETE FROM clips")
      let payloads = root.appendingPathComponent("payloads", isDirectory: true)
      try? FileManager.default.removeItem(at: payloads)
      try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
    } catch {
      log("clear failed \(error)")
    }
  }

  func payloadDirectory(id: String) -> URL? {
    guard isSafeID(id) else { return nil }
    let dir = directory(for: id)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }
    return dir
  }

  private func open() throws {
    let path = root.appendingPathComponent("history.db").path
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
      throw StoreError(description: errmsg())
    }
    sqlite3_busy_timeout(db, 1000)
    try exec("PRAGMA journal_mode=WAL")
    try exec("PRAGMA synchronous=NORMAL")
    try exec("""
    CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS clips (
      id TEXT PRIMARY KEY,
      copied_at REAL NOT NULL,
      kind TEXT NOT NULL,
      preview TEXT NOT NULL,
      search_text TEXT NOT NULL,
      source_name TEXT NOT NULL,
      source_bundle TEXT,
      source_device TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      content_hash TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_clips_copied ON clips(copied_at DESC);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_clips_hash ON clips(content_hash);
    """)
    try exec("INSERT OR IGNORE INTO meta(key, value) VALUES('schema', '1')")
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  private func pruneIfNeeded() throws {
    if Date().timeIntervalSince(lastPrune) < 3600 { return }
    lastPrune = Date()
    try prune()
  }

  private func prune() throws {
    let cutoff = Retention.cutoff(from: Date())
    var doomed: [String] = []
    try queryRows("SELECT id FROM clips WHERE copied_at < ?") { stmt in
      sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
    } row: { stmt in
      if let id = columnText(stmt, 0) { doomed.append(id) }
    }
    try queryRows("SELECT id FROM clips ORDER BY copied_at DESC LIMIT -1 OFFSET ?") { stmt in
      sqlite3_bind_int(stmt, 1, Int32(AppInfo.maxItems))
    } row: { stmt in
      if let id = columnText(stmt, 0) { doomed.append(id) }
    }
    for id in Set(doomed) where isSafeID(id) {
      try execPrepared("DELETE FROM clips WHERE id = ?") { stmt in
        bindText(stmt, 1, id)
      }
      try? FileManager.default.removeItem(at: directory(for: id))
    }
    try removeOrphans()
  }

  private func removeOrphans() throws {
    var known = Set<String>()
    try queryRows("SELECT id FROM clips") { _ in } row: { stmt in
      if let id = columnText(stmt, 0) { known.insert(id) }
    }
    let payloads = root.appendingPathComponent("payloads", isDirectory: true)
    let entries = try FileManager.default.contentsOfDirectory(at: payloads, includingPropertiesForKeys: nil)
    for entry in entries where !known.contains(entry.lastPathComponent) {
      try? FileManager.default.removeItem(at: entry)
    }
  }

  private func writePayload(_ clip: RawClip, id: String) throws {
    let dir = directory(for: id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var manifest = PayloadManifest(items: [])
    for (itemIndex, item) in clip.items.enumerated() {
      var entries: [PayloadManifest.Entry] = []
      for (typeIndex, type) in item.types.enumerated() {
        let name = "\(itemIndex)_\(typeIndex).bin"
        try type.data.write(to: dir.appendingPathComponent(name), options: .atomic)
        entries.append(PayloadManifest.Entry(uti: type.uti, file: name))
      }
      if !entries.isEmpty {
        manifest.items.append(PayloadManifest.Item(types: entries))
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    if let jpeg = clip.previewJPEG {
      try jpeg.write(to: dir.appendingPathComponent("preview.jpg"), options: .atomic)
    }
  }

  private func directory(for id: String) -> URL {
    root.appendingPathComponent("payloads", isDirectory: true).appendingPathComponent(id, isDirectory: true)
  }

  private func isSafeID(_ id: String) -> Bool {
    guard id.count == 36 else { return false }
    return id.allSatisfy { $0.isHexDigit || $0 == "-" }
  }

  private func id(forHash hash: String) throws -> String? {
    var found: String?
    try queryRows("SELECT id FROM clips WHERE content_hash = ? LIMIT 1") { stmt in
      bindText(stmt, 1, hash)
    } row: { stmt in
      found = columnText(stmt, 0)
    }
    return found
  }

  private func insert(
    id: String,
    copiedAt: Date,
    kind: ClipKind,
    preview: String,
    search: String,
    sourceName: String,
    sourceBundle: String?,
    sourceDevice: String,
    byteSize: Int,
    hash: String
  ) throws {
    try execPrepared("""
    INSERT INTO clips (id, copied_at, kind, preview, search_text, source_name, source_bundle, source_device, byte_size, content_hash)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """) { stmt in
      bindText(stmt, 1, id)
      sqlite3_bind_double(stmt, 2, copiedAt.timeIntervalSince1970)
      bindText(stmt, 3, kind.rawValue)
      bindText(stmt, 4, preview)
      bindText(stmt, 5, search)
      bindText(stmt, 6, sourceName)
      if let sourceBundle {
        bindText(stmt, 7, sourceBundle)
      } else {
        sqlite3_bind_null(stmt, 7)
      }
      bindText(stmt, 8, sourceDevice)
      sqlite3_bind_int64(stmt, 9, Int64(byteSize))
      bindText(stmt, 10, hash)
    }
  }

  private func update(
    id: String,
    copiedAt: Date,
    kind: ClipKind,
    preview: String,
    search: String,
    sourceName: String,
    sourceBundle: String?,
    sourceDevice: String,
    byteSize: Int
  ) throws {
    try execPrepared("""
    UPDATE clips
    SET copied_at = ?, kind = ?, preview = ?, search_text = ?, source_name = ?, source_bundle = ?, source_device = ?, byte_size = ?
    WHERE id = ?
    """) { stmt in
      sqlite3_bind_double(stmt, 1, copiedAt.timeIntervalSince1970)
      bindText(stmt, 2, kind.rawValue)
      bindText(stmt, 3, preview)
      bindText(stmt, 4, search)
      bindText(stmt, 5, sourceName)
      if let sourceBundle {
        bindText(stmt, 6, sourceBundle)
      } else {
        sqlite3_bind_null(stmt, 6)
      }
      bindText(stmt, 7, sourceDevice)
      sqlite3_bind_int64(stmt, 8, Int64(byteSize))
      bindText(stmt, 9, id)
    }
  }

  private func readRecord(_ stmt: OpaquePointer?) -> ClipRecord {
    let id = columnText(stmt, 0) ?? ""
    let kind = ClipKind(rawValue: columnText(stmt, 2) ?? "") ?? .text
    let previewURL = directory(for: id).appendingPathComponent("preview.jpg")
    let hasPreview = FileManager.default.fileExists(atPath: previewURL.path)
    return ClipRecord(
      id: id,
      copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
      kind: kind,
      preview: columnText(stmt, 3) ?? "",
      sourceName: columnText(stmt, 4) ?? "",
      sourceBundle: optionalColumnText(stmt, 5),
      sourceDevice: columnText(stmt, 6) ?? "mac",
      byteSize: Int(sqlite3_column_int64(stmt, 7)),
      previewImageURL: hasPreview ? previewURL : nil
    )
  }

  private func likePattern(_ query: String) -> String {
    var escaped = ""
    for character in query.lowercased() {
      if character == "\\" || character == "%" || character == "_" {
        escaped.append("\\")
      }
      escaped.append(character)
    }
    return "%\(escaped)%"
  }

  private func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? errmsg()
      sqlite3_free(error)
      throw StoreError(description: message)
    }
  }

  private func execPrepared(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw StoreError(description: errmsg())
    }
    defer { sqlite3_finalize(stmt) }
    bind(stmt)
    let result = sqlite3_step(stmt)
    guard result == SQLITE_DONE else {
      throw StoreError(description: errmsg())
    }
  }

  private func queryRows(
    _ sql: String,
    bind: (OpaquePointer?) -> Void,
    row: (OpaquePointer?) -> Void
  ) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw StoreError(description: errmsg())
    }
    defer { sqlite3_finalize(stmt) }
    bind(stmt)
    while true {
      let result = sqlite3_step(stmt)
      if result == SQLITE_ROW {
        row(stmt)
        continue
      }
      if result == SQLITE_DONE { break }
      throw StoreError(description: errmsg())
    }
  }

  private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    sqlite3_bind_text(stmt, index, text, -1, transient)
  }

  private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
  }

  private func optionalColumnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
    return columnText(stmt, index)
  }

  private func errmsg() -> String {
    guard let db else { return "sqlite is not open" }
    return String(cString: sqlite3_errmsg(db))
  }
}
