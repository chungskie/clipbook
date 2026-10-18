# Agents

Clipbook is a menu-bar clipboard manager for macOS 14 and later. It keeps 30 days of local clipboard history and shows it in a shelf from the bottom of the screen. There is no package manager and no Xcode project. `swiftc` builds one executable, and `scripts/build.sh` wraps it in an app, signs it, and registers a login agent.

People find this project while looking for an open-source Paste alternative, next to shelves such as [Copy](https://github.com/tarikbc/Copy) and [Pesty](https://github.com/momenbasel/pesty). Keep the README accurate when behavior changes. Do not claim pinboards, OCR, iCloud sync, or a paste stack. Clipbook does not have those.

## Layout

- `Sources/Clipbook/` is the whole app. `AppMain.swift` is the `@main` entry.
- `Packaging/Info.plist` is the app bundle metadata. Minimum system version is 14.0. `LSUIElement` hides the Dock icon.
- `scripts/build.sh` compiles, runs `--self-test`, draws the icon, signs, installs to `~/Applications/Clipbook.app`, and bootstraps `~/Library/LaunchAgents/com.schnappi.clipbook.plist`.
- `scripts/ensure-signing-identity.sh` creates a local code-signing certificate named `Clipbook Local` in the login keychain.
- `scripts/makeicon.swift` draws `AppIcon`.
- History lives in `~/Library/Application Support/Clipbook/` (`history.db` plus `payloads/`). Never commit that directory or paste a user’s clipboard into issues, logs, or tests.

## Build and test

```bash
./scripts/build.sh
```

The script fails if the self-test fails. The test binary is `build/Clipbook --self-test`. Tests cover classification, retention, search, dedup, and payload files. They use a temporary directory, not the real history database.

Compile flags that matter: `-swift-version 5`, target `$(uname -m)-apple-macos14.0`, frameworks AppKit, SwiftUI, Carbon, ApplicationServices, and CryptoKit, plus `-lsqlite3` and `-parse-as-library`. Swift 6 language mode rejects the AppKit and Carbon callbacks this app uses.

A second launch of the installed binary exits immediately. It posts the distributed notification `com.schnappi.clipbook.show`, which opens the shelf in the copy that is already running. `Clipbook --show` is the way to open the shelf from a script.

## Behavior to preserve

- Poll `NSPasteboard.general` about every 0.35 seconds. Ignore a pasteboard that carries any concealed, transient, or password-manager type listed in `PasteboardPolicy.ignoredTypes`.
- `com.apple.is-remote-clipboard` means Universal Clipboard. Label the source **Nearby Apple device**, store `sourceDevice` as `continuity`, and retry for a few seconds if the promised data is still empty. Do not pretend to know whether the other device was an iPhone, an iPad, or a Mac.
- Kind priority is image, then files, then a PDF with no text, then a single http(s) or mailto URL, then rich text, then plain text. Drop whitespace-only text.
- Dedup on a SHA-256 of the trimmed text and the preferred image bytes, or the file paths when there is neither. A duplicate moves to the front and keeps the newest payload.
- Keep rows with `copied_at` inside 30 days, and at most 5,000 of the newest. Prune orphaned payload directories.
- Skip `dyn.*` types. Skip oversized payloads instead of truncating images or PDFs. Caps live in `PasteboardPolicy.byteCap`.
- The global hotkey is Carbon `RegisterEventHotKey` for ⌘⇧V. It replaces Paste and Match Style while the app is running. Say so in the README and the About window if you change the shortcut.
- While the shelf is open, a session `CGEvent` tap handles ⌥1–⌥9, arrows, Return, Delete, Esc, and typed search. Creating that tap requires Accessibility. Without it, a click still writes the payload back to the pasteboard and the shelf tells the user to press ⌘V.
- Paste by restoring the stored types, hiding the shelf, activating the previous app, and posting ⌘V. Ignore the pasteboard change that Clipbook itself just wrote.
- The panel is a non-activating `NSPanel` at `popUpMenu` level, on the visible frame of the screen that contains the mouse. `NSHostingView.sizingOptions` must stay empty. The default sizing options grow the panel past the bottom of the screen.
- Load card images on the main thread with `NSImage(data:)` and draw them with `.drawingGroup()`. A background-thread `NSImage` paints blank inside this panel.
- Quit with `NSApp.terminate`, which exits 0. The LaunchAgent uses `KeepAlive` only when the exit was unsuccessful, so a normal quit stays quit. Do not also register `SMAppService`.
- Log kind, byte size, and source name. Never log clipboard text, URLs, or file names.

## Signing and the privacy grant

Sign with the `Clipbook Local` certificate. Its designated requirement is the bundle identifier plus that certificate’s common name, so a rebuild on the same Mac keeps the Device Control and Data Access grant.

An ad-hoc signature (`codesign --sign -`) changes the cdhash every build. macOS then shows the old Clipbook switch as on and still treats the new binary as untrusted. `scripts/build.sh` already refuses to do that when the local certificate exists.

After a grant, the running process may still see `AXIsProcessTrusted()` as false until it is launched again. Restart the LaunchAgent. Do not toggle the system privacy switch from a script.

On macOS 27 the Settings pane is **Device Control and Data Access**. On macOS 14–26 it is **Accessibility**. Both are `kTCCServiceAccessibility`.

## Changing the shelf

`Panel.swift` holds the panel controller and the SwiftUI shelf. Keep cards about 200 points wide in a horizontal scroller. Show the type, an ⌥ badge for the first nine visible cards, the preview, the source, and a relative time. Hover must not move the keyboard selection.

`accessibilityAction` takes `.default` and the action. `NSRunningApplication.activate(from:)` needs a `NSRunningApplication`, which is `.current`, not `NSApp`.

## Privacy for contributors

Sample clipboard text in tests must be obvious fixtures. Delete any demo rows you insert into the real history database before you finish. Do not screenshot a user’s shelf. The picture in `docs/shelf.png` is staged sample content.
