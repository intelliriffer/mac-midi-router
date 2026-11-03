import SwiftUI
import MidiRouterCore

/// Full matrix: sources × destinations (spec §UI details). Cell picker is the
/// ONLY way to create a routing: off / all / ch 1…16.
struct RouterView: View {
    @ObservedObject var engine: MIDIEngine
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 10) {
            if let warning = engine.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Text("").frame(width: 150, alignment: .leading)
                        ForEach(engine.matrixDestinations, id: \.self) { dest in
                            Text(dest)
                                .font(.footnote)
                                .frame(width: 70)
                                .lineLimit(1)
                        }
                    }
                    ForEach(engine.matrixSources, id: \.self) { source in
                        GridRow {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(engine.matrixConnectedSources.contains(source)
                                          ? .green : .gray)
                                    .frame(width: 8, height: 8)
                                Text(source)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: 140, alignment: .leading)
                            }
                            ForEach(engine.matrixDestinations, id: \.self) { dest in
                                MatrixCell(engine: engine, source: source, dest: dest)
                            }
                        }
                    }
                }
                .padding()
            }

            HStack {
                TextField("Preset name", text: $presetName)
                    .frame(width: 220)
                Button("Save Preset") {
                    engine.savePreset(as: presetName)
                    presetName = ""
                }
                Menu("Load Preset") {
                    let names = engine.config.presets.keys.sorted()
                    if names.isEmpty { Text("None yet") }
                    ForEach(names, id: \.self) { name in
                        Button(name) { engine.loadPreset(name) }
                    }
                }
                Menu("Delete Preset") {
                    let names = engine.config.presets.keys.sorted()
                    if names.isEmpty { Text("None yet") }
                    ForEach(names, id: \.self) { name in
                        Button(name) { engine.deletePreset(name) }
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding()
    }
}

struct MatrixCell: View {
    @ObservedObject var engine: MIDIEngine
    let source: String
    let dest: String

    var body: some View {
        Menu {
            Button("off") {
                engine.setCell(source: source, dest: dest, filter: nil)
            }
            Button("all channels") {
                engine.setCell(source: source, dest: dest, filter: .all)
            }
            Divider()
            ForEach(1...16, id: \.self) { channel in
                Button("ch \(channel)") {
                    engine.setCell(source: source, dest: dest, filter: .channel(channel))
                }
            }
        } label: {
            Text(engine.cellLabel(source: source, dest: dest))
                .font(.system(.footnote, design: .monospaced))
                .frame(width: 66, height: 22)
                .background(cellColor)
                .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
    }

    private var cellColor: Color {
        if engine.cellLabel(source: source, dest: dest) == "—" {
            return Color(nsColor: .controlBackgroundColor)
        }
        if !engine.matrixConnectedDestinations.contains(dest) {
            return .gray.opacity(0.45)             // configured, device missing
        }
        return .accentColor.opacity(0.7)           // routed + connected
    }
}
