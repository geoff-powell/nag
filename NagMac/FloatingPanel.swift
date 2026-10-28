import AppKit
import SwiftUI

/// A borderless panel that can take clicks and keyboard focus, for the shield and nag panels.
final class FloatingPanel: NSPanel {
    init(nonactivating: Bool) {
        var style: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        if nonactivating { style.insert(.nonactivatingPanel) }
        super.init(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Replaces the content and resizes to fit it.
    func setContent<Content: View>(_ view: Content, width: CGFloat) {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        setContentSize(NSSize(width: width, height: max(40, size.height)))
    }
}
