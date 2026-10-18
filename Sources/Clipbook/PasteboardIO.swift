import AppKit
import CryptoKit
import Foundation

enum ReadOutcome {
  case clip(RawClip)
  case ignored
  case retry
  case empty
}

enum PasteboardIO {
  private static let textUTIs: Set<String> = [
    "public.utf8-plain-text",
    "public.url",
    "public.file-url",
    "public.html",
  ]

  static func read(frontName: String?, frontBundle: String?) -> ReadOutcome {
    let pasteboard = NSPasteboard.general
    let items = pasteboard.pasteboardItems ?? []
    var typeNames = Set((pasteboard.types ?? []).map(\.rawValue))
    for item in items {
      for type in item.types {
        typeNames.insert(type.rawValue)
      }
    }
    if typeNames.isEmpty { return .empty }
    if PasteboardPolicy.isIgnored(typeNames) { return .ignored }

    let remote = typeNames.contains(PasteboardPolicy.remoteType)
    var sourceBundle = frontBundle
    var sourceName = frontName ?? "This Mac"
    if let marked = firstString(PasteboardPolicy.sourceType, in: items), !marked.isEmpty {
      sourceBundle = marked
      sourceName = applicationName(bundleID: marked) ?? marked
    }
    if remote {
      sourceBundle = nil
      sourceName = "Nearby Apple device"
    }
    if sourceBundle == AppInfo.bundleID {
      sourceName = "Clipbook"
    }

    var stored: [RawItemBlob] = []
    var plain = ""
    var html = ""
    var urlString: String?
    var filePaths: [String] = []
    var rtfPresent = false
    var pdfCount = 0
    var imageData: Data?
    var imageUTI: String?
    var byteSize = 0

    for item in items {
      var blobs: [RawTypeBlob] = []
      for type in item.types {
        let uti = type.rawValue
        if uti == PasteboardPolicy.remoteType || uti == PasteboardPolicy.sourceType { continue }
        if uti.hasPrefix("dyn.") { continue }
        guard PasteboardPolicy.storedUTIs.contains(uti) else { continue }
        guard let data = data(for: uti, item: item) else { continue }
        if data.count > PasteboardPolicy.byteCap(for: uti) {
          log("skipped oversized \(uti) \(data.count) bytes")
          continue
        }
        blobs.append(RawTypeBlob(uti: uti, data: data))
        byteSize += data.count
        switch uti {
        case "public.utf8-plain-text":
          if plain.isEmpty, let text = String(data: data, encoding: .utf8) { plain = text }
        case "public.html":
          if html.isEmpty, let text = String(data: data, encoding: .utf8) { html = text }
        case "public.rtf":
          rtfPresent = true
          if plain.isEmpty, let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            plain = attributed.string
          }
        case "public.url":
          if urlString == nil, let text = String(data: data, encoding: .utf8) { urlString = text }
        case "public.file-url":
          if let path = filePath(from: data) { filePaths.append(path) }
        case "NSFilenamesPboardType":
          if let names = item.propertyList(forType: type) as? [String] {
            filePaths.append(contentsOf: names)
          }
        case "public.pdf":
          pdfCount = data.count
        default:
          break
        }
      }
      if !blobs.isEmpty {
        stored.append(RawItemBlob(types: blobs))
      }
    }

    for uti in PasteboardPolicy.imageUTIs {
      if let data = firstData(uti, in: stored) {
        imageData = data
        imageUTI = uti
        break
      }
    }

    if plain.isEmpty && !html.isEmpty {
      plain = ClipClassifier.stripHTML(html)
    }

    if stored.isEmpty && imageData == nil && filePaths.isEmpty && plain.isEmpty {
      return remote ? .retry : .empty
    }

    if let imageData, (imageUTI == "public.heic" || imageUTI == "public.tiff"),
       firstData("public.png", in: stored) == nil,
       let png = ImageThumb.png(from: imageData, maxPixel: 1800) {
      if stored.isEmpty {
        stored.append(RawItemBlob(types: []))
      }
      stored[0].types.append(RawTypeBlob(uti: "public.png", data: png))
      byteSize += png.count
    }

    let facts = ClipboardFacts(
      plainText: plain,
      hasRichText: rtfPresent || !html.isEmpty,
      urlString: urlString,
      filePaths: uniquePaths(filePaths),
      imageByteCount: imageData?.count ?? 0,
      imageUTI: imageUTI,
      pdfByteCount: pdfCount,
      remote: remote
    )
    let classification = ClipClassifier.classify(facts)
    if classification.drop { return remote ? .retry : .empty }

    var previewJPEG = imageData.flatMap { ImageThumb.jpeg(from: $0, maxPixel: 480) }
    let paths = uniquePaths(filePaths)
    if previewJPEG == nil, classification.kind == .file, paths.count == 1 {
      previewJPEG = ImageThumb.jpegFromImageFile(paths[0])
    }

    let hashText = plain.trimmingCharacters(in: .whitespacesAndNewlines)
    var material = Data()
    func add(_ tag: String, _ data: Data) {
      material.append(Data(tag.utf8))
      material.append(data)
    }
    if !hashText.isEmpty { add("t", Data(hashText.utf8)) }
    if let imageData { add("i", imageData) }
    if imageData == nil && hashText.isEmpty && !paths.isEmpty {
      add("f", Data(paths.sorted().joined(separator: "\n").utf8))
    }
    if material.isEmpty {
      for item in stored {
        for type in item.types { add(type.uti, type.data) }
      }
    }
    if material.isEmpty { return remote ? .retry : .empty }

    let clip = RawClip(
      copiedAt: Date(),
      kind: classification.kind,
      preview: classification.preview,
      searchText: classification.searchText,
      sourceName: sourceName,
      sourceBundle: sourceBundle,
      sourceDevice: classification.sourceDevice,
      contentHash: sha256(material),
      byteSize: byteSize,
      items: stored,
      previewJPEG: previewJPEG
    )
    return .clip(clip)
  }

  static func write(directory: URL) -> Bool {
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: manifestURL),
          let manifest = try? JSONDecoder().decode(PayloadManifest.self, from: data)
    else { return false }

    var objects: [NSPasteboardItem] = []
    for item in manifest.items {
      let pasteboardItem = NSPasteboardItem()
      var wrote = false
      for entry in item.types {
        let file = directory.appendingPathComponent(entry.file)
        guard file.lastPathComponent == entry.file, !entry.file.contains("/") else { continue }
        guard let blob = try? Data(contentsOf: file), !blob.isEmpty else { continue }
        let type = NSPasteboard.PasteboardType(entry.uti)
        if textUTIs.contains(entry.uti), let string = String(data: blob, encoding: .utf8) {
          pasteboardItem.setString(string, forType: type)
        } else {
          pasteboardItem.setData(blob, forType: type)
        }
        wrote = true
      }
      if wrote { objects.append(pasteboardItem) }
    }
    guard !objects.isEmpty else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.writeObjects(objects)
  }

  private static func data(for uti: String, item: NSPasteboardItem) -> Data? {
    let type = NSPasteboard.PasteboardType(uti)
    if let data = item.data(forType: type), !data.isEmpty { return data }
    if let string = item.string(forType: type), !string.isEmpty { return Data(string.utf8) }
    return nil
  }

  private static func firstString(_ uti: String, in items: [NSPasteboardItem]) -> String? {
    let type = NSPasteboard.PasteboardType(uti)
    for item in items {
      if let string = item.string(forType: type), !string.isEmpty { return string }
    }
    return nil
  }

  private static func firstData(_ uti: String, in items: [RawItemBlob]) -> Data? {
    for item in items {
      if let blob = item.types.first(where: { $0.uti == uti }) { return blob.data }
    }
    return nil
  }

  private static func filePath(from data: Data) -> String? {
    guard let string = String(data: data, encoding: .utf8) else { return nil }
    if let url = URL(string: string), url.isFileURL { return url.path }
    if string.hasPrefix("/") { return string }
    return nil
  }

  private static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for path in paths where seen.insert(path).inserted {
      ordered.append(path)
    }
    return ordered
  }

  private static func applicationName(bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return FileManager.default.displayName(atPath: url.path)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

enum ImageThumb {
  static func jpeg(from data: Data, maxPixel: CGFloat) -> Data? {
    guard let image = NSImage(data: data) else { return nil }
    return jpeg(from: image, maxPixel: maxPixel)
  }

  static func png(from data: Data, maxPixel: CGFloat) -> Data? {
    guard let image = NSImage(data: data) else { return nil }
    return encoded(image, maxPixel: maxPixel, fileType: .png, properties: [:])
  }

  static func jpegFromImageFile(_ path: String) -> Data? {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp"]
    guard allowed.contains(ext) else { return nil }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? NSNumber,
          size.intValue > 0,
          size.intValue < 8_000_000,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path))
    else { return nil }
    return jpeg(from: data, maxPixel: 480)
  }

  private static func jpeg(from image: NSImage, maxPixel: CGFloat) -> Data? {
    encoded(image, maxPixel: maxPixel, fileType: .jpeg, properties: [.compressionFactor: 0.75])
  }

  private static func encoded(
    _ image: NSImage,
    maxPixel: CGFloat,
    fileType: NSBitmapImageRep.FileType,
    properties: [NSBitmapImageRep.PropertyKey: Any]
  ) -> Data? {
    var proposed = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
    let pixelW = CGFloat(cgImage.width)
    let pixelH = CGFloat(cgImage.height)
    guard pixelW > 1, pixelH > 1 else { return nil }
    let scale = min(1, maxPixel / max(pixelW, pixelH))
    let width = max(1, Int((pixelW * scale).rounded()))
    let height = max(1, Int((pixelH * scale).rounded()))
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: scaled)
    return rep.representation(using: fileType, properties: properties)
  }
}
