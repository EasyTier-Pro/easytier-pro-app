import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var reopenNotificationName: Notification.Name {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "easytier-pro-app"
    return Notification.Name("\(bundleIdentifier).reopenMainWindow")
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    if activateRunningInstance() {
      NSApp.terminate(nil)
      return
    }

    super.applicationWillFinishLaunching(notification)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleReopenNotification(_:)),
      name: reopenNotificationName,
      object: Bundle.main.bundleIdentifier
    )
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      showMainWindow()
    }

    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func activateRunningInstance() -> Bool {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
      return false
    }

    let currentProcessId = ProcessInfo.processInfo.processIdentifier
    guard let runningApp = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).first(where: { $0.processIdentifier != currentProcessId }) else {
      return false
    }

    runningApp.unhide()
    runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    DistributedNotificationCenter.default().postNotificationName(
      reopenNotificationName,
      object: bundleIdentifier,
      userInfo: nil,
      deliverImmediately: true
    )
    return true
  }

  @objc private func handleReopenNotification(_ notification: Notification) {
    showMainWindow()
  }

  private func showMainWindow() {
    DispatchQueue.main.async {
      self.mainFlutterWindow?.deminiaturize(nil)
      self.mainFlutterWindow?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
