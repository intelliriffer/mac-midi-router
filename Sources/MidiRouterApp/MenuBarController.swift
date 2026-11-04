import AppKit
import SwiftUI
import MidiRouterCore

final class MenuBarController: NSObject, NSApplicationDelegate {
    private let engine: MIDIEngine
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var routerWindow: NSWindow?
    private var aboutWindow: NSWindow?

    init(engine: MIDIEngine) {
        self.engine = engine
        super.init()
        // No contentSize: the popover tracks the SwiftUI content — small with
        // few routes, growing as routes are added (capped by PopoverView).
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            engine: engine,
            openRouter: { [weak self] in self?.openRouterWindow() },
            openAbout: { [weak self] in self?.openAboutWindow() },
            closePopover: { [weak self] in self?.popover.performClose(nil) }
        ))
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        // Musical, instantly recognizable menu-bar mark (SF Symbol).
        item.button?.image = NSImage(systemSymbolName: "pianokeys",
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

    /// Called from the popover's "About" row.
    func openAboutWindow() {
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "About mac-midi-router"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AboutView())
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
