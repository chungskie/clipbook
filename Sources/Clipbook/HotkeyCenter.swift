import AppKit
import Carbon
import Foundation

final class HotkeyCenter {
  var onPress: (() -> Void)?
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  func register() {
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let installed = InstallEventHandler(
      GetApplicationEventTarget(),
      Self.handler,
      1,
      &spec,
      Unmanaged.passUnretained(self).toOpaque(),
      &handler
    )
    if installed != noErr {
      log("hotkey handler failed \(installed)")
      return
    }
    let hotKeyID = EventHotKeyID(signature: OSType(0x434C5042), id: 1)
    let modifiers = UInt32(cmdKey | shiftKey)
    let registered = RegisterEventHotKey(
      UInt32(kVK_ANSI_V),
      modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    if registered != noErr {
      log("RegisterEventHotKey failed \(registered)")
    } else {
      log("hotkey registered")
    }
  }

  private static let handler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    center.onPress?()
    return noErr
  }
}

final class KeyTap {
  private var port: CFMachPort?
  private var source: CFRunLoopSource?
  var onKey: (CGEvent) -> Bool = { _ in false }

  func start() {
    guard port == nil else { return }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: Self.callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      log("keyboard tap unavailable")
      return
    }
    self.port = port
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
  }

  func stop() {
    if let port {
      CGEvent.tapEnable(tap: port, enable: false)
    }
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    port = nil
    source = nil
  }

  private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let userInfo {
        let tap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
        if let port = tap.port {
          CGEvent.tapEnable(tap: port, enable: true)
        }
      }
      return Unmanaged.passUnretained(event)
    }
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    if tap.onKey(event) {
      return nil
    }
    return Unmanaged.passUnretained(event)
  }
}

enum PasteKeystroke {
  static func send() {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    source.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval
    )
    let key = CGKeyCode(kVK_ANSI_V)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    else { return }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }
}
