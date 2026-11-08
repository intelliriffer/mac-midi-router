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

    /// Estimated list height (~36pt per row + spacing) vs the cap.
    private var routesWouldOverflow: Bool {
        let estimated = CGFloat(max(engine.config.currentRoutes.count, 1)) * 40 + 16
        return estimated > maxRoutesHeight
    }

    /// The route rows themselves — hugs its content; wrapped in a ScrollView
    /// by the body only when the list would exceed the screen cap.
    /// Switch first, then the source name (user preference).
    private var routeListContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(engine.config.currentRoutes, id: \.source) { route in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: {
                            engine.config.currentRoutes
                                .first { $0.source == route.source }?.enabled ?? false
                        },
                        set: {
                            engine.setRouteEnabled(source: route.source, enabled: $0)
                        }))
                    .toggleStyle(.switch)
                    .controlSize(.small)          // smaller switch chrome; label is hidden anyway
                    .labelsHidden()
                    .help("Route \"\(route.source)\" on/off")

                    Text(route.source)
                        .font(.body)               // same size as the footer buttons
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    Menu {
                        if route.destinations.isEmpty {
                            Button("no mappings") { }
                                .disabled(true)
                        }
                        ForEach(route.destinations, id: \.name) { dest in
                            Toggle("\(dest.name) (\(engine.cellLabel(source: route.source, dest: dest.name)))",
                                   isOn: Binding(
                                       get: {
                                           engine.mappingEnabled(source: route.source, dest: dest.name) ?? false
                                       },
                                       set: {
                                           engine.setMappingEnabled(source: route.source,
                                                                    dest: dest.name, enabled: $0)
                                       }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!route.enabled)
                        }
                    } label: {
                        Text("\(route.destinations.count) →")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .opacity(route.enabled ? 1 : 0.4)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Toggle mappings of \"\(route.source)\"")
                }
            }

            if engine.config.currentRoutes.isEmpty {
                Text("No routes yet — open the Router.")
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
