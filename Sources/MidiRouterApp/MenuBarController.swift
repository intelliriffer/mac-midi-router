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
        item.button?.image = NSImage(systemSymbolName: "cable.connector",
                                     accessibilityDescription: "mac-midi-router")
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
