import AppKit
import SwiftUI
import MidiRouterCore

final class MenuBarController: NSObject, NSApplicationDelegate {
    private let engine: MIDIEngine
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var routerWindow: NSWindow?

    init(engine: MIDIEngine) {
        self.engine = engine
        super.init()
        popover.contentSize = NSSize(width: 360, height: 340)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            engine: engine,
            openRouter: { [weak self] in self?.openRouterWindow() },
            closePopover: { [weak self] in self?.popover.performClose(nil) }
        ))
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.image = StatusIcon.image()
        item.button?.imageScaling = .scaleProportionallyDown
        statusItem = item
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Called from the popover's "Open Router" button.
    func openRouterWindow() {
        if routerWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                styleMask: [.titled, .resizable, .closable],
                backing: .buffered, defer: false)
            window.title = "MIDI Router"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RouterView(engine: engine))
            routerWindow = window
        }
        routerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Menu-bar status icon: a mini MIDI DIN plug (ring + 5 pins) matching the
/// app icon, drawn as a template image so it adapts to light/dark menu bars.
private enum StatusIcon {
    static func image() -> NSImage {
        let points: CGFloat = 18
        let pixels = 72   // 4x for crisp pin dots at menu-bar size
        let image = NSImage(size: NSSize(width: points, height: points), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = CGFloat(pixels) / points
            ctx.scaleBy(x: scale)
            ctx.setFillColor(NSColor.black.cgColor)

            let c = CGPoint(x: points / 2, y: points / 2)
            // ring
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.9)
            ctx.strokeEllipse(in: CGRect(x: c.x - 6.6, y: c.y - 6.6, width: 13.2, height: 13.2))
            // five pins
            let pinDistance: CGFloat = 3.3
            let pinRadius: CGFloat = 1.05
            for angle in stride(from: -90.0, to: 270.0, by: 72.0) {
                let rad = angle * .pi / 180
                let px = c.x + pinDistance * CGFloat(cos(rad))
                let py = c.y + pinDistance * CGFloat(sin(rad))
                ctx.fillEllipse(in: CGRect(x: px - pinRadius, y: py - pinRadius,
                                           width: pinRadius * 2, height: pinRadius * 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
