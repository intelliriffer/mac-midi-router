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
    private var routeListContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(engine.config.currentRoutes, id: \.source) { route in
                HStack {
                    Toggle(route.source, isOn: Binding(
                        get: {
                            engine.config.currentRoutes
                                .first { $0.source == route.source }?.enabled ?? false
                        },
                        set: {
                            engine.setRouteEnabled(source: route.source, enabled: $0)
                        }))
                    .toggleStyle(.switch)
                    Spacer()
                    Text("\(route.destinations.count) →")
                        .foregroundStyle(.secondary)
                        .opacity(route.enabled ? 1 : 0.4)
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
                .help("About mac-midi-router — version, author, license")

                Button {
                    closePopover()
                    openRouter()
                } label: {
                    Label("Router", systemImage: "square.grid.3x3")
                }

                Button(role: .destructive) {
                    closePopover()
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit the app (\u{2318}Q)")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
