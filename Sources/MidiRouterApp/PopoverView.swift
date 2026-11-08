import SwiftUI
import AppKit
import MidiRouterCore

/// Quick route on/off + Open Router (spec §UI details).
struct PopoverView: View {
    @ObservedObject var engine: MIDIEngine
    let openRouter: () -> Void
    let openAbout: () -> Void
    let closePopover: () -> Void

    /// The route list grows with the number of ports, then scrolls instead of
    /// overflowing the screen (chrome + footer + margins reserved).
    private var maxRoutesHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(120, screen - 280)
    }

    /// Estimated list height (~40pt per mapping row + spacing) vs the cap.
    private var routesWouldOverflow: Bool {
        let estimated = CGFloat(max(mappingRows.count, 1)) * 40 + 16
        return estimated > maxRoutesHeight
    }

    private struct MappingRow: Identifiable {
        let source: String
        let dest: String
        var id: String { "\(source) → \(dest)" }
    }

    private var mappingRows: [MappingRow] {
        engine.config.currentRoutes.flatMap { route in
            route.destinations.map { MappingRow(source: route.source, dest: $0.name) }
        }
    }

    /// The route rows themselves — hugs its content; wrapped in a ScrollView
    /// by the body only when the list would exceed the screen cap.
    /// One row per mapping: switch first, then "source → dest".
    private var routeListContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(mappingRows) { row in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { engine.mappingEnabled(source: row.source, dest: row.dest) ?? false },
                        set: { engine.setMappingEnabled(source: row.source, dest: row.dest, enabled: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("Mapping \"\(row.source)\" → \"\(row.dest)\" on/off")

                    Text("\(row.source) → \(row.dest)")
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    Text(engine.cellLabel(source: row.source, dest: row.dest))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Mapping \"\(row.source)\" → \"\(row.dest)\" on/off")
                }
            }

            if mappingRows.isEmpty {
                Text("No mappings yet — open the Router.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = engine.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if routesWouldOverflow {
                ScrollView {
                    routeListContent
                }
                .frame(maxHeight: maxRoutesHeight)
            } else {
                routeListContent
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    closePopover()
                    openAbout()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
                .buttonStyle(CompactFooterStyle())
                .help("About mac-midi-router — version, author, license")

                Button {
                    closePopover()
                    openRouter()
                } label: {
                    Label("Router", systemImage: "square.grid.3x3")
                }
                .buttonStyle(CompactFooterStyle())

                Button(role: .destructive) {
                    closePopover()
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(CompactFooterStyle())
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit the app (\u{2318}Q)")
            }
        }
        .padding()
        .frame(width: 300, alignment: .leading)   // fixed width, height hugs content
    }
}

/// Smaller chrome, full-size text: same font as everywhere else, just tighter
/// padding around the label instead of the system's tall bordered button.
private struct CompactFooterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)   // text never shrinks
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(configuration.isPressed ? .primary : .primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.10))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
