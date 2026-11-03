import SwiftUI
import MidiRouterCore

/// Full matrix: rows = MIDI inputs (sticky left column), columns = MIDI
/// outputs. Faint separators between rows and columns. The cell picker
/// (off / all / ch 1…16) is the ONLY way to create a routing.
struct RouterView: View {
    @ObservedObject var engine: MIDIEngine
    @State private var presetName = ""

    private let rowHeight: CGFloat = 30
    private let headerHeight: CGFloat = 36
    /// Column/label widths size themselves to the longest name so nothing is
    /// truncated; hover tooltips always carry the full name as backup.
    private var sourceWidth: CGFloat {
        engine.matrixSources.map(\.count).map { Swift.min(320, Swift.max(190, CGFloat($0) * 7.0 + 16)) }.max() ?? 190
    }
    /// Compact uniform columns; full names live in hover tooltips instead of
    /// stretching the grid (user preference).
    private let destWidth: CGFloat = 66
    private static let hairline = Color.primary.opacity(0.10)

    var body: some View {
        VStack(spacing: 10) {
            if let warning = engine.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    sourceColumn
                    Rectangle()
                        .fill(Color.primary.opacity(0.2))   // column boundary
                        .frame(width: 1)
                    ScrollView(.horizontal) {
                        matrixBody
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            presetsControls
        }
        .padding()
    }

    // MARK: sticky left column (inputs) — never moves horizontally

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            axisCorner
            ForEach(engine.matrixSources, id: \.self) { source in
                sourceLabel(source)
                    .overlay(alignment: .bottom) { rowLine() }
            }
        }
        .frame(width: sourceWidth, alignment: .leading)
    }

    /// Corner marks both axes and their direction, unambiguously:
    /// inputs (MIDI *from*) run down the left, outputs (MIDI *to*) across the top.
    private var axisCorner: some View {
        HStack(spacing: 6) {
            Text("IN — from ↓")
            Spacer()
            Text("OUT — to →")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(width: sourceWidth, height: headerHeight)
        .overlay(alignment: .bottom) { rowLine(strong: true) }
    }

    private func sourceLabel(_ source: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engine.matrixConnectedSources.contains(source) ? .green : .gray)
                .frame(width: 8, height: 8)
            Text(source)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .help(source)
    }

    // MARK: scrolling matrix (outputs header + cells scroll horizontally)

    private var matrixBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            outputHeaderRow
            ForEach(engine.matrixSources, id: \.self) { source in
                cellRow(source: source)
                    .overlay(alignment: .bottom) { rowLine() }
            }
        }
    }

    private var outputHeaderRow: some View {
        HStack(spacing: 0) {
            ForEach(engine.matrixDestinations.indices, id: \.self) { index in
                Text(engine.matrixDestinations[index])
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: destWidth, height: headerHeight)
                    .help(engine.matrixDestinations[index])   // full name on hover
                    .overlay(alignment: .trailing) {
                        columnLine(last: index == engine.matrixDestinations.count - 1)
                    }
            }
        }
        .overlay(alignment: .bottom) { rowLine(strong: true) }
    }

    private func cellRow(source: String) -> some View {
        HStack(spacing: 0) {
            ForEach(engine.matrixDestinations.indices, id: \.self) { index in
                MatrixCell(engine: engine, source: source,
                           dest: engine.matrixDestinations[index])
                    .frame(width: destWidth, height: rowHeight)
                    .overlay(alignment: .trailing) {
                        columnLine(last: index == engine.matrixDestinations.count - 1)
                    }
            }
        }
    }

    // MARK: separators

    private func rowLine(strong: Bool = false) -> some View {
        Rectangle()
            .fill(strong ? Color.primary.opacity(0.2) : Self.hairline)
            .frame(height: 1)
    }

    private func columnLine(last: Bool) -> some View {
        Group {
            if !last && engine.matrixDestinations.count > 1 {
                Rectangle().fill(Self.hairline).frame(width: 1)
            }
        }
    }

    // MARK: presets — compact toolbar, menus must not stretch (fixedSize)

    private var presetsControls: some View {
        HStack(spacing: 8) {
            TextField("New preset name…", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                .onSubmit(savePreset)

            Button("Save Preset", action: savePreset)
                .disabled(saveIsBlocked)

            Menu {
                ForEach(engine.config.presets.keys.sorted(), id: \.self) { name in
                    Button(name) { engine.loadPreset(name) }
                }
            } label: {
                Label("Load", systemImage: "square.and.arrow.down")
            }
            .fixedSize()
            .disabled(engine.config.presets.isEmpty)

            Menu {
                ForEach(engine.config.presets.keys.sorted(), id: \.self) { name in
                    Button(name) { engine.deletePreset(name) }
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .fixedSize()
            .disabled(engine.config.presets.isEmpty)

            Spacer()

            Text(presetSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Load keeps your current on/off switches; routes come from the preset")
        }
        .padding(.horizontal, 4)
    }

    private var saveIsBlocked: Bool {
        presetName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var presetSummary: String {
        let count = engine.config.presets.count
        return count == 0 ? "No presets saved yet" : "\(count) preset\(count == 1 ? "" : "s") saved"
    }

    private func savePreset() {
        guard !saveIsBlocked else { return }
        engine.savePreset(as: presetName)
        presetName = ""
    }
}

struct MatrixCell: View {
    @ObservedObject var engine: MIDIEngine
    let source: String
    let dest: String

    /// Same port on both axes = feedback loop; rendered dead, not selectable.
    private var isSelfRoute: Bool { source == dest }

    var body: some View {
        if isSelfRoute {
            selfRouteCell
                .help("Same port on both sides — self-routing disabled")
        } else {
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
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .padding(.horizontal, 2)
                    .background(cellColor)
                    .cornerRadius(5)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .help("\(source) → \(dest) · \(engine.cellLabel(source: source, dest: dest))\(routeEnabled ? "" : " (route off)")")
        }
    }

    private var selfRouteCell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.02))
            SelfSlash()
                .stroke(Color.primary.opacity(0.18), lineWidth: 1.5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .padding(.horizontal, 2)
    }

    private var isEmpty: Bool {
        engine.cellLabel(source: source, dest: dest) == "—"
    }

    /// The popover's quick on/off lives on the route; cells must reflect it.
    private var routeEnabled: Bool {
        engine.config.currentRoutes
            .first { $0.source == source }?.enabled ?? false
    }

    private var cellColor: Color {
        if isEmpty {
            return Color.primary.opacity(0.03)
        }
        if !routeEnabled {
            return .gray.opacity(0.2)              // route muted off in router
        }
        if !engine.matrixConnectedDestinations.contains(dest) {
            return .gray.opacity(0.45)             // configured, device missing
        }
        return .accentColor.opacity(0.7)           // routed + connected
    }
}

private struct SelfSlash: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 10, y: rect.maxY - 5))
        p.addLine(to: CGPoint(x: rect.maxX - 10, y: rect.minY + 5))
        return p
    }
}
