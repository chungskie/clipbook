import AppKit
import ApplicationServices
import Darwin
import Foundation

enum AppInfo {
  static let version = "1.0"
  static let retentionDays = 30
  static let maxItems = 5000
  static let bundleID = "com.schnappi.clipbook"
}

extension Notification.Name {
  static let clipbookShow = Notification.Name("com.schnappi.clipbook.show")
}

func log(_ message: String) {
  let line = "[\(Int(Date().timeIntervalSince1970))] \(message)\n"
  if let data = line.data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

enum InstanceLock {
  private static var fd: Int32 = -1

  static func acquire(path: String) -> Bool {
    fd = open(path, O_CREAT | O_RDWR, 0o600)
    if fd < 0 { return false }
    return flock(fd, LOCK_EX | LOCK_NB) == 0
  }
}

enum Accessibility {
  static func trusted() -> Bool {
    AXIsProcessTrusted()
  }

  @discardableResult
  static func prompt() -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  static func openSettings() {
    let urls = [
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
    ]
    for raw in urls {
      guard let url = URL(string: raw) else { continue }
      if NSWorkspace.shared.open(url) { return }
    }
  }
}

enum Retention {
  static func cutoff(from now: Date) -> Date {
    now.addingTimeInterval(-Double(AppInfo.retentionDays) * 86_400)
  }
}
