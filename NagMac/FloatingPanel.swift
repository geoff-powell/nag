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

    /// Replaces the content and resizes to fit it. The hosting view is reused, so when the new content
    /// has the same type as the old, SwiftUI keeps its state and running animations across updates.
    func setContent<Content: View>(_ view: Content, width: CGFloat) {
        let root = AnyView(view.frame(width: width))
        let hosting: NSHostingView<AnyView>
        if let existing = contentView as? NSHostingView<AnyView> {
            existing.rootView = root
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: root)
            contentView = hosting
        }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        setContentSize(NSSize(width: width, height: max(40, size.height)))
    }
}
