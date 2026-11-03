import Foundation
import MidiRouterCore

let io = RealMIDIIO()
print("SOURCES:      \(io.sourceNames())")
print("DESTINATIONS: \(io.destinationNames())")
RunLoop.main.run()
