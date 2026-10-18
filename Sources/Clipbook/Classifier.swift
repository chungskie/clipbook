import Foundation

enum ClipClassifier {
  static func classify(_ facts: ClipboardFacts) -> Classification {
    let trimmed = facts.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    let previewPlain = sanitize(trimmed, limit: 800)
    let device = facts.remote ? "continuity" : "mac"

    func result(kind: ClipKind, preview: String, extraSearch: String = "") -> Classification {
      var search = sanitize(trimmed, limit: 20_000).lowercased()
      let extra = extraSearch.trimmingCharacters(in: .whitespacesAndNewlines)
      if !extra.isEmpty {
        search += "\n" + extra.lowercased()
      }
      if facts.remote {
        search += "\nnearby apple device"
      }
      if search.count > 20_000 {
        search = String(search.prefix(20_000))
      }
      return Classification(
        drop: false,
        kind: kind,
        preview: preview,
        searchText: search,
        sourceDevice: device
      )
    }

    if hasSubstantialImage(facts) {
      let caption = imageCaption(facts, plain: previewPlain)
      let names = facts.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
      var extra = names.joined(separator: "\n")
      if let url = facts.urlString { extra += "\n" + url }
      return result(kind: .image, preview: caption, extraSearch: extra)
    }

    if !facts.filePaths.isEmpty {
      let names = facts.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
      let preview: String
      if names.count == 1 {
        preview = names[0]
      } else {
        preview = "\(names.count) files\n" + names.prefix(6).joined(separator: "\n")
      }
      return result(kind: .file, preview: sanitize(preview, limit: 800), extraSearch: names.joined(separator: "\n"))
    }

    if facts.pdfByteCount > 0 && trimmed.isEmpty {
      return result(kind: .file, preview: "PDF document", extraSearch: "pdf")
    }

    if let url = facts.urlString?.trimmingCharacters(in: .whitespacesAndNewlines), isSingleURL(url) {
      return result(kind: .link, preview: sanitize(url, limit: 800), extraSearch: url)
    }
    if isSingleURL(trimmed) {
      return result(kind: .link, preview: sanitize(trimmed, limit: 800), extraSearch: trimmed)
    }

    if trimmed.isEmpty {
      return Classification(drop: true, kind: .text, preview: "", searchText: "", sourceDevice: device)
    }
    if facts.hasRichText {
      return result(kind: .rich, preview: previewPlain)
    }
    return result(kind: .text, preview: previewPlain)
  }

  static func isSingleURL(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count < 2048, !trimmed.contains(where: \.isNewline) else { return false }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https" || scheme == "mailto"
  }

  static func stripHTML(_ html: String) -> String {
    let sample = String(html.prefix(200_000))
    var text = sample
    if let script = try? NSRegularExpression(pattern: "(?is)<(script|style)[^>]*>.*?</\\1>") {
      text = script.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    if let tags = try? NSRegularExpression(pattern: "<[^>]+>") {
      text = tags.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    let entities = [
      "&nbsp;": " ",
      "&amp;": "&",
      "&lt;": "<",
      "&gt;": ">",
      "&quot;": "\"",
      "&#39;": "'",
    ]
    for (entity, value) in entities {
      text = text.replacingOccurrences(of: entity, with: value)
    }
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func sanitize(_ text: String, limit: Int) -> String {
    let scalars = text.unicodeScalars.filter { scalar in
      if scalar.value == 0 { return false }
      if scalar == "\n" || scalar == "\t" { return true }
      return scalar.value >= 32
    }
    var cleaned = String(String.UnicodeScalarView(scalars))
    cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n")
    cleaned = cleaned.replacingOccurrences(of: "\r", with: "\n")
    if cleaned.count > limit {
      cleaned = String(cleaned.prefix(limit))
    }
    return cleaned
  }

  private static func hasSubstantialImage(_ facts: ClipboardFacts) -> Bool {
    guard facts.imageByteCount >= 32, let uti = facts.imageUTI else { return false }
    if uti == "public.tiff" && facts.imageByteCount < 12_000 && !facts.filePaths.isEmpty {
      return false
    }
    return true
  }

  private static func imageCaption(_ facts: ClipboardFacts, plain: String) -> String {
    if let url = facts.urlString, let host = URL(string: url)?.host, !host.isEmpty {
      return host
    }
    if let path = facts.filePaths.first {
      return URL(fileURLWithPath: path).lastPathComponent
    }
    if !plain.isEmpty && plain.count < 80 && !plain.contains("\n") {
      return plain
    }
    return ""
  }
}
