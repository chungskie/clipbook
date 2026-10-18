import AppKit
import Carbon
import SwiftUI

final class PanelModel: ObservableObject {
  @Published var items: [ClipRecord] = []
  @Published var query = ""
  @Published var filter: ClipKind?
  @Published var selection = 0
  @Published var scrollToken = 0
  @Published var totalCount = 0
  @Published var trusted = false

  var store: ClipStore?
  var requestTrust: () -> Void = {}
  var onPaste: (Int) -> Void = { _ in }

  var countLabel: String {
    if !query.isEmpty || filter != nil {
      return "\(items.count) of \(totalCount)"
    }
    if totalCount > items.count {
      return "Latest \(items.count) of \(totalCount) · 30 days"
    }
    return "\(totalCount) · 30 days"
  }

  func reload(resetSelection: Bool) {
    guard let store else { return }
    let current = items.indices.contains(selection) ? items[selection].id : nil
    items = store.fetch(kind: filter, query: query, limit: 500)
    totalCount = store.count()
    if resetSelection {
      selection = 0
    } else if let current, let index = items.firstIndex(where: { $0.id == current }) {
      selection = index
    } else if selection >= items.count {
      selection = max(0, items.count - 1)
    }
  }

  func setQuery(_ value: String) {
    query = String(value.prefix(200))
    reload(resetSelection: true)
  }

  func setFilter(_ kind: ClipKind?) {
    filter = kind
    reload(resetSelection: true)
  }

  func move(_ delta: Int) {
    guard !items.isEmpty else { return }
    selection = min(max(0, selection + delta), items.count - 1)
    scrollToken += 1
  }

  func typeCharacter(_ text: String) {
    guard query.count < 200 else { return }
    setQuery(query + text)
  }

  func backspaceInQuery() -> Bool {
    guard !query.isEmpty else { return false }
    setQuery(String(query.dropLast()))
    return true
  }

  func clearSearch() -> Bool {
    guard !query.isEmpty else { return false }
    setQuery("")
    return true
  }

  func item(at index: Int) -> ClipRecord? {
    guard items.indices.contains(index) else { return nil }
    return items[index]
  }

  func deleteSelection() {
    guard let store, items.indices.contains(selection) else { return }
    store.delete(id: items[selection].id)
    reload(resetSelection: false)
  }
}

final class ClipPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

final class ClearHost<Content: View>: NSHostingView<Content> {
  override var isOpaque: Bool { false }
}

final class PanelController {
  let model = PanelModel()
  let panel: ClipPanel
  weak var monitor: ClipboardMonitor?
  var isStatusItem: (NSPoint) -> Bool = { _ in false }

  private let keyTap = KeyTap()
  private var monitors: [Any] = []
  private var trustTimer: Timer?
  private var hintPanel: NSPanel?
  private var targetApp: NSRunningApplication?
  private var pasting = false
  private var lastToggle = Date.distantPast

  private static let optionSlots: [Int64: Int] = [
    Int64(kVK_ANSI_1): 0,
    Int64(kVK_ANSI_2): 1,
    Int64(kVK_ANSI_3): 2,
    Int64(kVK_ANSI_4): 3,
    Int64(kVK_ANSI_5): 4,
    Int64(kVK_ANSI_6): 5,
    Int64(kVK_ANSI_7): 6,
    Int64(kVK_ANSI_8): 7,
    Int64(kVK_ANSI_9): 8,
  ]

  init() {
    panel = ClipPanel(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 348),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovable = false
    panel.title = "Clipbook"
    panel.animationBehavior = .utilityWindow
    panel.becomesKeyOnlyIfNeeded = false

    let host = ClearHost(rootView: PanelRoot(model: model))
    host.translatesAutoresizingMaskIntoConstraints = false
    // Default hosting-view sizing follows the SwiftUI ideal height. That ideal
    // height is unbounded here, so the shelf grew past the bottom of the screen
    // and the card footers never appeared. The panel frame is the size.
    host.sizingOptions = []
    host.setContentHuggingPriority(.defaultLow, for: .horizontal)
    host.setContentHuggingPriority(.defaultLow, for: .vertical)
    host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.clear.cgColor

    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    background.isEmphasized = true
    background.wantsLayer = true
    background.layer?.cornerRadius = 18
    background.layer?.masksToBounds = true
    background.layer?.borderWidth = 1
    background.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    background.addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      host.topAnchor.constraint(equalTo: background.topAnchor),
      host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    panel.contentView = background
    model.onPaste = { [weak self] index in
      self?.paste(index: index)
    }
  }

  func toggle() {
    let now = Date()
    if now.timeIntervalSince(lastToggle) < 0.25 { return }
    lastToggle = now
    if panel.isVisible {
      hide()
    } else {
      show()
    }
  }

  func show() {
    pasting = false
    let front = NSWorkspace.shared.frontmostApplication
    if front?.bundleIdentifier == AppInfo.bundleID {
      targetApp = nil
    } else {
      targetApp = front
    }
    model.trusted = Accessibility.trusted()
    model.query = ""
    model.filter = nil
    model.reload(resetSelection: true)
    place(animated: !panel.isVisible)
    keyTap.onKey = { [weak self] event in
      self?.handleKey(event) ?? false
    }
    keyTap.start()
    installMonitors()
    startTrustTimer()
  }

  func hide() {
    guard panel.isVisible else { return }
    keyTap.stop()
    removeMonitors()
    trustTimer?.invalidate()
    trustTimer = nil
    var target = panel.frame
    target.origin.y -= 28
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.13
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().setFrame(target, display: true)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      self?.panel.orderOut(nil)
      self?.panel.alphaValue = 1
    }
  }

  func hideImmediately() {
    keyTap.stop()
    removeMonitors()
    trustTimer?.invalidate()
    trustTimer = nil
    panel.orderOut(nil)
    panel.alphaValue = 1
  }

  func reloadIfVisible() {
    guard panel.isVisible else { return }
    model.reload(resetSelection: false)
  }

  private func place(animated: Bool) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    guard let screen else { return }
    let visible = screen.visibleFrame
    let width = min(1080, max(560, visible.width - 28))
    let height = min(348, max(260, visible.height - 24))
    let final = NSRect(
      x: visible.midX - width / 2,
      y: visible.minY + 10,
      width: width,
      height: height
    )
    if panel.isVisible && !animated {
      panel.setFrame(final, display: true)
      panel.orderFrontRegardless()
      panel.makeKey()
      return
    }
    var start = final
    start.origin.y -= 36
    panel.setFrame(start, display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    panel.makeKey()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(final, display: true)
      panel.animator().alphaValue = 1
    }
  }

  private func installMonitors() {
    removeMonitors()
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
      self?.clickedOutside()
    }) {
      monitors.append(monitor)
    }
  }

  private func removeMonitors() {
    for monitor in monitors {
      NSEvent.removeMonitor(monitor)
    }
    monitors.removeAll()
  }

  private func clickedOutside() {
    let location = NSEvent.mouseLocation
    if panel.frame.contains(location) { return }
    if isStatusItem(location) { return }
    hide()
  }

  private func startTrustTimer() {
    trustTimer?.invalidate()
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.model.trusted = Accessibility.trusted()
    }
    RunLoop.main.add(timer, forMode: .common)
    trustTimer = timer
  }

  private func handleKey(_ event: CGEvent) -> Bool {
    guard panel.isVisible else { return false }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let command = flags.contains(.maskCommand)
    let option = flags.contains(.maskAlternate)
    let control = flags.contains(.maskControl)
    let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) == 1

    if command && flags.contains(.maskShift) && code == Int64(kVK_ANSI_V) {
      toggle()
      return true
    }
    if command || control { return false }

    switch code {
    case Int64(kVK_Escape):
      if !model.clearSearch() { hide() }
      return true
    case Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter):
      if !repeatKey { paste(index: model.selection) }
      return true
    case Int64(kVK_LeftArrow):
      model.move(-1)
      return true
    case Int64(kVK_RightArrow):
      model.move(1)
      return true
    case Int64(kVK_Delete), Int64(kVK_ForwardDelete):
      if !model.backspaceInQuery() { model.deleteSelection() }
      return true
    default:
      break
    }

    if option {
      if let slot = Self.optionSlots[code], !repeatKey {
        paste(index: slot)
      }
      return true
    }

    if let text = Self.characters(from: event), text.count == 1, let character = text.first, character >= " " {
      model.typeCharacter(String(character))
      return true
    }
    return false
  }

  private func paste(index: Int) {
    guard !pasting, let store = model.store, let item = model.item(at: index) else { return }
    guard let directory = store.payloadDirectory(id: item.id), PasteboardIO.write(directory: directory) else {
      log("paste failed")
      return
    }
    pasting = true
    monitor?.noteOwnWrite()
    let trusted = Accessibility.trusted()
    let target = targetApp
    hideImmediately()
    guard trusted else {
      showHint("Copied. Press ⌘V to paste.")
      return
    }
    if let target, target.bundleIdentifier != AppInfo.bundleID {
      _ = target.activate(from: .current)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
      PasteKeystroke.send()
    }
  }

  private func showHint(_ text: String) {
    hintPanel?.orderOut(nil)
    let hint = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 42),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    hint.level = .popUpMenu
    hint.isOpaque = false
    hint.backgroundColor = .clear
    hint.hidesOnDeactivate = false
    hint.hasShadow = true
    hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let wrap = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
    wrap.material = .hudWindow
    wrap.state = .active
    wrap.wantsLayer = true
    wrap.layer?.cornerRadius = 10
    wrap.layer?.masksToBounds = true
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.alignment = .center
    label.frame = wrap.bounds.insetBy(dx: 12, dy: 8)
    label.autoresizingMask = [.width, .height]
    wrap.addSubview(label)
    hint.contentView = wrap
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    if let screen {
      let visible = screen.visibleFrame
      hint.setFrame(
        NSRect(x: visible.midX - 160, y: visible.minY + 16, width: 320, height: 42),
        display: true
      )
    }
    hint.orderFrontRegardless()
    hintPanel = hint
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak hint] in
      hint?.orderOut(nil)
    }
  }

  private static func characters(from event: CGEvent) -> String? {
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(
      maxStringLength: buffer.count,
      actualStringLength: &length,
      unicodeString: &buffer
    )
    guard length > 0 else { return nil }
    return String(utf16CodeUnits: buffer, count: length)
  }
}

struct PanelRoot: View {
  @ObservedObject var model: PanelModel

  var body: some View {
    VStack(spacing: 0) {
      header
      cards
      if !model.trusted {
        trustBanner
      }
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "doc.on.clipboard")
          .font(.system(size: 14, weight: .semibold))
        Text("Clipbook")
          .font(.system(size: 13, weight: .semibold))
        Text(model.countLabel)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Spacer(minLength: 12)
        searchField
      }
      HStack(spacing: 6) {
        FilterChip(title: "All", selected: model.filter == nil) { model.setFilter(nil) }
        ForEach(ClipKind.allCases) { kind in
          FilterChip(title: kind.filterLabel, selected: model.filter == kind) {
            model.setFilter(kind)
          }
        }
        Spacer()
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Text(model.query.isEmpty ? "Type to search" : model.query)
        .font(.system(size: 12))
        .foregroundStyle(model.query.isEmpty ? Color.secondary : Color.primary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(width: 220, height: 26)
    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
  }

  private var cards: some View {
    GeometryReader { geometry in
      if model.items.isEmpty {
        emptyState
          .frame(width: geometry.size.width, height: geometry.size.height)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
              ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                ClipCard(item: item, index: index, selected: index == model.selection) {
                  model.onPaste(index)
                }
                .frame(width: 200, height: max(160, geometry.size.height - 12))
                .id(item.id)
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
          }
          .onChange(of: model.scrollToken) { _, _ in
            guard model.items.indices.contains(model.selection) else { return }
            withAnimation(.easeOut(duration: 0.12)) {
              proxy.scrollTo(model.items[model.selection].id, anchor: .center)
            }
          }
        }
      }
    }
    .frame(maxHeight: .infinity)
  }

  private var emptyState: some View {
    Group {
      if model.query.isEmpty && model.filter == nil && model.totalCount == 0 {
        VStack(spacing: 8) {
          Image(systemName: "doc.on.clipboard")
            .font(.system(size: 26))
            .foregroundStyle(.secondary)
          Text("Nothing from the last 30 days")
            .font(.system(size: 15, weight: .semibold))
          Text("Copy with ⌘C. Open this shelf with ⌘⇧V. Click a card, or press ⌥1 through ⌥9, to paste it back.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
          Text("An iPhone, iPad, or another Mac shows up here when Universal Clipboard delivers the copy. Clipbook keeps it on this Mac for 30 days. It does not sync history through iCloud.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, 20)
      } else {
        Text("No matches")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var trustBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "hand.raised")
        .foregroundStyle(.secondary)
      Text("Accessibility is off, so a click copies the item and you press ⌘V. If Clipbook is already on in Settings, remove it from the list and turn the new switch on.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Button("Turn On") { model.requestTrust() }
        .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 6)
  }

  private var footer: some View {
    Text("⌥1–⌥9 paste    ← → choose    return paste    delete remove    esc close")
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(maxWidth: .infinity)
      .padding(.bottom, 10)
      .padding(.top, 2)
  }
}

struct FilterChip: View {
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
          Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
        )
        .overlay(
          Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.75) : Color.clear, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
  }
}

struct ClipCard: View {
  let item: ClipRecord
  let index: Int
  let selected: Bool
  let onPaste: () -> Void
  @State private var hovered = false

  var body: some View {
    chrome
      .onHover { hovered = $0 }
      .onTapGesture(perform: onPaste)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityName)
      .accessibilityHint(pasteHint)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, onPaste)
  }

  private var pasteHint: String {
    index < 9 ? "Option \(index + 1)" : "Paste"
  }

  private var chrome: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Circle()
          .fill(item.kind.dot)
          .frame(width: 6, height: 6)
        Text(item.kind.label)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        if index < 9 {
          Text("⌥\(index + 1)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
      }
      preview
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(-1)
      sourceRow
        .layoutPriority(1)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(fillOpacity))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(borderColor, lineWidth: selected ? 2 : 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var fillOpacity: Double { selected ? 0.96 : 0.72 }

  private var borderColor: Color {
    if selected { return Color.accentColor }
    return Color.primary.opacity(hovered ? 0.22 : 0.08)
  }

  private var sourceRow: some View {
    HStack(spacing: 4) {
      if item.sourceDevice == "continuity" {
        Image(systemName: "iphone")
          .font(.system(size: 9))
      }
      Text(item.sourceName)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(ClipDate.relative(item.copiedAt))
        .monospacedDigit()
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var preview: some View {
    if let url = item.previewImageURL {
      VStack(alignment: .leading, spacing: 6) {
        CardImage(url: url)
          .frame(maxWidth: .infinity)
          .frame(height: 140)
          .background(Color.black.opacity(0.04))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        if !item.preview.isEmpty {
          Text(item.preview)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    } else if item.kind == .link {
      VStack(alignment: .leading, spacing: 6) {
        Image(systemName: "link")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.green)
        Text(host(item.preview))
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(2)
        Text(item.preview)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
    } else if item.kind == .file {
      VStack(alignment: .leading, spacing: 4) {
        Image(systemName: item.preview.contains("\n") ? "doc.on.doc" : "doc")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.orange)
        Text(item.preview)
          .font(.system(size: 12))
          .lineLimit(6)
      }
    } else {
      Text(item.preview.isEmpty ? item.kind.label : item.preview)
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .lineLimit(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var accessibilityName: String {
    let body = item.preview.isEmpty ? item.kind.label : item.preview.replacingOccurrences(of: "\n", with: " ")
    let trimmed = body.count > 80 ? String(body.prefix(80)) : body
    return "\(item.kind.label), \(trimmed)"
  }

  private func host(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), let host = url.host, !host.isEmpty { return host }
    return trimmed
  }
}

private extension ClipKind {
  var dot: Color {
    switch self {
    case .text: return .blue
    case .rich: return .purple
    case .link: return .green
    case .image: return .orange
    case .file: return .yellow
    }
  }
}

/// Previews are decoded on the main thread when the card is built.
/// A background `NSImage` draws blank in this layer-backed panel.
struct CardImage: View {
  private let image: NSImage?

  init(url: URL) {
    let data = try? Data(contentsOf: url)
    image = data.flatMap { NSImage(data: $0) }
  }

  var body: some View {
    if let image {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .drawingGroup()
    } else {
      Image(systemName: "photo")
        .font(.system(size: 22))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

enum ClipDate {
  static func relative(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 8 { return "Now" }
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
    return day.string(from: date)
  }

  private static let day: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()
}
