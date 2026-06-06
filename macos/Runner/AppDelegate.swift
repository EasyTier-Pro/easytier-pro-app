import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    if activateRunningInstance() {
      NSApp.terminate(nil)
      return
    }

    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
    return true
  }
}
