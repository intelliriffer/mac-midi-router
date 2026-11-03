import AppKit
import MidiRouterCore

let supportDir = Persistence.supportDirectory
let engine = MIDIEngine(io: RealMIDIIO(), initialState: PresetStore.load(in: supportDir))
engine.performReconcile()                      // spec: reconcile on launch
let persistence = Persistence(engine: engine, directory: supportDir)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)            // menu bar only, no Dock icon

// Minimal app menu so Quit (⌘Q + menu-bar entry) exists even in accessory mode.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu(title: "mac-midi-router")
appMenu.addItem(NSMenuItem(
    title: "Quit mac-midi-router",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"))
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

let controller = MenuBarController(engine: engine)
app.delegate = controller
controller.installStatusItem()
_ = persistence                                 // keeps dealloc sink alive for the run
app.run()
