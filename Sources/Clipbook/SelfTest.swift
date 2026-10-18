import Foundation

enum SelfTest {
  static func run() -> Int32 {
    var failed = 0
    func check(_ condition: Bool, _ name: String) {
      if condition {
        print("PASS \(name)")
      } else {
        print("FAIL \(name)")
        failed += 1
      }
    }

    check(ClipClassifier.stripHTML("<p>Hello <b>there</b></p>") == "Hello there", "strip html")
    check(ClipClassifier.stripHTML("<script>nope()</script><p>Keep</p>").contains("Keep"), "strip script")
    check(!ClipClassifier.stripHTML("<script>nope()</script><p>Keep</p>").contains("nope"), "script body gone")
    check(ClipClassifier.isSingleURL("https://example.com/a"), "url")
    check(!ClipClassifier.isSingleURL("hello https://example.com"), "not a lone url")
    check(ClipClassifier.sanitize("a\u{0000}b", limit: 10) == "ab", "drop null")

    let text = ClipClassifier.classify(facts(plain: "Alpha beta"))
    check(!text.drop && text.kind == .text && text.preview == "Alpha beta", "plain text")

    let link = ClipClassifier.classify(facts(plain: "https://apple.com/iphone"))
    check(link.kind == .link && link.sourceDevice == "mac", "text url is a link")

    let typedLink = ClipClassifier.classify(facts(plain: "see this", url: "https://apple.com"))
    check(typedLink.kind == .link, "url type wins over prose when the url field is a single url")

    var imageFacts = facts(plain: "https://images.example/cat.png", url: "https://images.example/cat.png")
    imageFacts.imageByteCount = 40_000
    imageFacts.imageUTI = "public.png"
    let image = ClipClassifier.classify(imageFacts)
    check(image.kind == .image, "image wins over url")

    var iconFacts = facts(plain: "")
    iconFacts.imageByteCount = 800
    iconFacts.imageUTI = "public.tiff"
    iconFacts.filePaths = ["/Users/me/Desktop/Notes.txt"]
    let icon = ClipClassifier.classify(iconFacts)
    check(icon.kind == .file && icon.preview == "Notes.txt", "finder icon tiff stays a file")

    let files = ClipClassifier.classify(facts(plain: "", files: ["/tmp/a.pdf", "/tmp/b.pdf"]))
    check(files.kind == .file && files.preview.hasPrefix("2 files"), "multi file")

    var remote = facts(plain: "from the phone")
    remote.remote = true
    let phone = ClipClassifier.classify(remote)
    check(phone.sourceDevice == "continuity" && phone.searchText.contains("nearby apple device"), "continuity label")

    let blank = ClipClassifier.classify(facts(plain: "  \n  "))
    check(blank.drop, "blank text dropped")

    let rich = ClipClassifier.classify(facts(plain: "Styled", rich: true))
    check(rich.kind == .rich, "rich text")

    check(PasteboardPolicy.isIgnored(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), "concealed skipped")
    check(!PasteboardPolicy.isIgnored(["public.utf8-plain-text"]), "normal text kept")
    check(PasteboardPolicy.isIgnored(["com.apple.is-remote-clipboard"]) == false, "remote marker is not ignored")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipbook-selftest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      let store = try ClipStore(root: root)
      let hello = sample(hash: "h1", preview: "Hello", search: "hello", kind: .text, when: Date())
      _ = try store.upsert(hello, bumpExisting: true)
      let older = sample(
        hash: "h2",
        preview: "Older",
        search: "older",
        kind: .text,
        when: Date().addingTimeInterval(-2 * 86_400)
      )
      _ = try store.upsert(older, bumpExisting: true)
      let stale = sample(
        hash: "old",
        preview: "Stale",
        search: "stale",
        kind: .file,
        when: Date().addingTimeInterval(-40 * 86_400)
      )
      _ = try store.upsert(stale, bumpExisting: true)
      try store.pruneNow()

      let all = store.fetch(kind: nil, query: "")
      check(all.count == 2, "prune keeps 30 days")
      check(all.first?.preview == "Hello", "newest first")
      check(store.fetch(kind: nil, query: "hell").count == 1, "search")
      check(store.fetch(kind: .file, query: "").isEmpty, "kind filter after prune")
      check(store.fetch(kind: nil, query: "100%_done").isEmpty, "like escape does not throw")

      let percent = sample(hash: "pct", preview: "100%_done", search: "100%_done", kind: .text, when: Date())
      _ = try store.upsert(percent, bumpExisting: true)
      check(store.fetch(kind: nil, query: "100%_done").count == 1, "search percent underscore")

      var again = hello
      again.preview = "Hello again"
      again.copiedAt = Date().addingTimeInterval(5)
      _ = try store.upsert(again, bumpExisting: true)
      let bumped = store.fetch(kind: nil, query: "hello")
      check(bumped.count == 1 && bumped.first?.preview == "Hello again", "dedup bumps")

      let before = store.fetch(kind: nil, query: "").count
      _ = try store.upsert(hello, bumpExisting: false)
      check(store.fetch(kind: nil, query: "").count == before, "dedup without bump does not duplicate")

      let payload = root.appendingPathComponent("payloads")
      let dirs = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
      check(dirs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }, "manifest written")
      check(dirs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("preview.jpg").path) }, "preview written")

      if let id = store.fetch(kind: nil, query: "hello").first?.id {
        store.delete(id: id)
        check(store.fetch(kind: nil, query: "hello").isEmpty, "delete")
        check(!FileManager.default.fileExists(atPath: payload.appendingPathComponent(id).path), "payload removed")
      } else {
        check(false, "delete")
      }
      store.deleteAll()
      check(store.count() == 0, "clear")
    } catch {
      print("FAIL store \(error)")
      failed += 1
    }

    if failed == 0 {
      print("ALL PASS")
      return 0
    }
    print("\(failed) FAILED")
    return 1
  }

  private static func facts(
    plain: String,
    url: String? = nil,
    files: [String] = [],
    rich: Bool = false
  ) -> ClipboardFacts {
    ClipboardFacts(
      plainText: plain,
      hasRichText: rich,
      urlString: url,
      filePaths: files,
      imageByteCount: 0,
      imageUTI: nil,
      pdfByteCount: 0,
      remote: false
    )
  }

  private static func sample(hash: String, preview: String, search: String, kind: ClipKind, when: Date) -> RawClip {
    RawClip(
      copiedAt: when,
      kind: kind,
      preview: preview,
      searchText: search,
      sourceName: "Test",
      sourceBundle: "test.app",
      sourceDevice: "mac",
      contentHash: hash,
      byteSize: preview.utf8.count,
      items: [RawItemBlob(types: [RawTypeBlob(uti: "public.utf8-plain-text", data: Data(preview.utf8))])],
      previewJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
    )
  }
}

