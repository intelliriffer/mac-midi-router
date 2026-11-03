import AppKit
import MidiRouterCore

let supportDir = Persistence.supportDirectory
let engine = MIDIEngine(io: RealMIDIIO(), initialState: PresetStore.load(in: supportDir))
engine.performReconcile()                      // spec: reconcile on launch
let persistence = Persistence(engine: engine, directory: supportDir)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)            // menu bar only, no Dock icon
let controller = MenuBarController(engine: engine)
app.delegate = controller
controller.installStatusItem()
_ = persistence                                 // keeps dealloc sink alive for the run
app.run()
