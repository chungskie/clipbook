import AppKit
import Foundation

@main
enum ClipbookMain {
  static func main() {
    umask(0o077)
    if CommandLine.arguments.contains("--self-test") {
      exit(SelfTest.run())
    }

    let support: URL
    do {
      support = try ClipStore.prepareSupportDirectory()
    } catch {
      fputs("Clipbook could not create its folder: \(error)\n", stderr)
      exit(0)
    }

    let lockPath = support.appendingPathComponent("instance.lock").path
    if !InstanceLock.acquire(path: lockPath) {
      DistributedNotificationCenter.default().postNotificationName(
        .clipbookShow,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
      )
      exit(0)
    }

    log("starting")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var store: ClipStore!
  private var monitor: ClipboardMonitor!
  private var panel: PanelController!
  private let hotkey = HotkeyCenter()
  private var activity: NSObjectProtocol?
  private var showObserver: NSObjectProtocol?
  private var status: NSStatusItem!

  func applicationDidFinishLaunching(_ notification: Notification) {
    log("Clipbook \(AppInfo.version) launched, accessibility \(Accessibility.trusted())")
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "Keeping clipboard history"
    )
    do {
      store = try ClipStore(root: ClipStore.supportDirectory())
    } catch {
      log("database error \(error)")
      NSApp.terminate(nil)
      return
    }

    panel = PanelController()
    modelSetup()
    monitor = ClipboardMonitor(store: store)
    panel.monitor = monitor
    monitor.onSaved = { [weak panel] in
      panel?.reloadIfVisible()
    }
    monitor.start()

    setupStatusItem()
    panel.isStatusItem = { [weak self] point in
      self?.statusItemFrame().contains(point) ?? false
    }
    hotkey.onPress = { [weak panel] in
      panel?.toggle()
    }
    hotkey.register()

    showObserver = DistributedNotificationCenter.default().addObserver(
      forName: .clipbookShow,
      object: nil,
      queue: .main
    ) { [weak panel] _ in
      panel?.show()
    }

    if !UserDefaults.standard.bool(forKey: "didPromptAccessibility") {
      UserDefaults.standard.set(true, forKey: "didPromptAccessibility")
      _ = Accessibility.prompt()
    }
    if CommandLine.arguments.contains("--show") {
      panel.show()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.show()
    return false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    panel.show()
  }

  private func modelSetup() {
    panel.model.store = store
    panel.model.requestTrust = {
      _ = Accessibility.prompt()
      if !Accessibility.trusted() {
        Accessibility.openSettings()
      }
    }
  }

  private func setupStatusItem() {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = status.button else { return }
    button.target = self
    button.action = #selector(statusClicked)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.toolTip = "Clipbook — ⌘⇧V"
    updateIcon()
  }

  private func updateIcon() {
    let symbol = monitor.paused ? "pause.circle" : "doc.on.clipboard"
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Clipbook")
    image?.isTemplate = true
    status.button?.image = image
  }

  private func statusItemFrame() -> NSRect {
    guard let button = status.button, let window = button.window else { return .zero }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  @objc private func statusClicked() {
    let event = NSApp.currentEvent
    let right = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
    if right {
      panel.hideImmediately()
      popMenu()
      return
    }
    panel.toggle()
  }

  @objc private func showPanel() {
    panel.show()
  }

  @objc private func togglePause() {
    monitor.setPaused(!monitor.paused)
    updateIcon()
  }

  @objc private func clearHistory() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Clear clipboard history?"
    alert.informativeText = "This removes everything Clipbook has saved on this Mac. The clipboard you have copied right now stays as it is."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Clear History")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      store.deleteAll()
      panel.reloadIfVisible()
    }
  }

  @objc private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Clipbook"
    alert.informativeText = """
    Clipbook remembers what you copy on this Mac for 30 days. Press ⌘⇧V to open the shelf at the bottom of the screen. Click a card, or press ⌥1 through ⌥9, to paste it into the app you were using.

    Copies from your iPhone, iPad, or another Mac show up when Universal Clipboard places them on this Mac. That needs Handoff, Bluetooth, Wi-Fi, and the same Apple ID, with the devices near each other. Clipbook does not keep its own iCloud history. It saves the copy locally for 30 days after it arrives.

    Passwords marked private by apps such as 1Password are not saved.

    ⌘⇧V is Paste and Match Style in many apps. While Clipbook is running, that shortcut opens Clipbook.

    The clipboard icon in the menu bar opens Clipbook. Right-click it to pause, clear history, or quit. Clipbook opens when you log in. Turn that off in System Settings → General → Login Items.
    """
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func popMenu() {
    let menu = NSMenu()
    let show = NSMenuItem(title: "Show Clipbook", action: #selector(showPanel), keyEquivalent: "v")
    show.keyEquivalentModifierMask = [.command, .shift]
    show.target = self
    menu.addItem(show)

    let pauseTitle = monitor.paused ? "Resume Capturing" : "Pause Capturing"
    let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
    pause.target = self
    menu.addItem(pause)
    menu.addItem(.separator())

    let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
    clear.target = self
    menu.addItem(clear)
    let about = NSMenuItem(title: "About Clipbook", action: #selector(showAbout), keyEquivalent: "")
    about.target = self
    menu.addItem(about)
    menu.addItem(.separator())

    let quit = NSMenuItem(title: "Quit Clipbook", action: #selector(quit), keyEquivalent: "q")
    quit.keyEquivalentModifierMask = [.command]
    quit.target = self
    menu.addItem(quit)

    guard let button = status.button else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
  }
}
