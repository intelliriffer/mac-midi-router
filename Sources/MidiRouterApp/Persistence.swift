import Foundation
import Combine
import MidiRouterCore

/// Debounced autosave of engine config + app-support directory helper.
/// Launch loads via PresetStore.load in main.swift (spec §persistence).
final class Persistence {
    private var cancellable: AnyCancellable?

    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("mac-midi-router", isDirectory: true)
    }

    init(engine: MIDIEngine, directory: URL) {
        cancellable = engine.$config
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { state in
                do {
                    try PresetStore.save(state, in: directory)
                } catch {
                    NSLog("PresetStore save failed: \(error)")
                }
            }
    }
}
