import SwiftUI
import AppKit
import MidiRouterCore

/// Quick route on/off + Open Router (spec §UI details).
struct PopoverView: View {
    @ObservedObject var engine: MIDIEngine
    let openRouter: () -> Void
    let openAbout: () -> Void
    let closePopover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = engine.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

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

            Divider()
                HStack {
                    Button {
                        closePopover()
                        openAbout()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                .help("About mac-midi-router — version, author, license")

                Spacer()

                Button(role: .destructive) {
                    closePopover()
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit the app (\u{2318}Q)")
            }
            Button("Open Router…") {
                closePopover()
                openRouter()
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
