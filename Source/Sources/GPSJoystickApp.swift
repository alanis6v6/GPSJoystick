import AppKit
import Darwin
import SwiftUI

@main
struct GPSJoystickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("GPS 搖桿", id: "controller") {
            ControllerView(model: delegate.model)
                .frame(minWidth: 880, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1140, height: 735)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SimulatorModel()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if self?.model.handleKey(event) == true {
                return nil
            }
            return event
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshDeviceSupport()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.releaseControls()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waiting = model.prepareToQuit {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return waiting ? .terminateLater : .terminateNow
    }
}
