import AppKit
import SwiftUI

/// The main window, managed by AppKit so notifications, panels and the menu bar can all open it.
/// Nag is a menu bar app; it shows in the Dock only while this window is open.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: MacModel
    private var window: NSWindow?

    init(model: MacModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView().environment(model)))
        window.title = "Nag"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 860, height: 600))
        window.minSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("NagMainWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
