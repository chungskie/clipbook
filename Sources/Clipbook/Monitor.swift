import AppKit
import Foundation

final class ClipboardMonitor {
  private let store: ClipStore
  private var timer: Timer?
  private var lastChangeCount: Int
  private(set) var paused: Bool
  var onSaved: (() -> Void)?

  private static let pauseKey = "capturePaused"
  private static let retryDelays: [TimeInterval] = [0.25, 0.45, 0.8, 1.2, 2.0, 3.0]

  init(store: ClipStore) {
    self.store = store
    self.paused = UserDefaults.standard.bool(forKey: Self.pauseKey)
    self.lastChangeCount = NSPasteboard.general.changeCount
  }

  func start() {
    if !paused {
      capture(bumpExisting: false)
    }
    let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
      self?.poll()
    }
    timer.tolerance = 0.12
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func setPaused(_ value: Bool) {
    paused = value
    UserDefaults.standard.set(value, forKey: Self.pauseKey)
    lastChangeCount = NSPasteboard.general.changeCount
    log(value ? "capture paused" : "capture resumed")
  }

  /// Ignore the pasteboard write Clipbook itself just made.
  func noteOwnWrite() {
    lastChangeCount = NSPasteboard.general.changeCount
  }

  private func poll() {
    let count = NSPasteboard.general.changeCount
    guard count != lastChangeCount else { return }
    lastChangeCount = count
    guard !paused else { return }
    capture(bumpExisting: true)
  }

  private func capture(bumpExisting: Bool, attempt: Int = 0) {
    let count = NSPasteboard.general.changeCount
    let front = NSWorkspace.shared.frontmostApplication
    let outcome = PasteboardIO.read(
      frontName: front?.localizedName,
      frontBundle: front?.bundleIdentifier
    )
    switch outcome {
    case .clip(let clip):
      do {
        _ = try store.upsert(clip, bumpExisting: bumpExisting)
        log("saved \(clip.kind.rawValue) \(clip.byteSize)B \(clip.sourceDevice) \(clip.sourceName)")
        onSaved?()
      } catch {
        log("save failed \(error)")
      }
    case .retry:
      guard attempt < Self.retryDelays.count else {
        log("gave up waiting for clipboard data")
        return
      }
      if attempt == 0 { log("clipboard data not ready") }
      let delay = Self.retryDelays[attempt]
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        guard NSPasteboard.general.changeCount == count else { return }
        self.capture(bumpExisting: bumpExisting, attempt: attempt + 1)
      }
    case .ignored, .empty:
      break
    }
  }
}
