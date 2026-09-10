import AppKit
import MacToolsCore
import SwiftUI

@MainActor
final class MenuBarOrganizerSettingsWindowController: NSWindowController {
    init(settings: MenuBarOrganizerSettings, controller: MenuBarOrganizerController, icons: MenuBarIconStore) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 660),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Menu Bar Organizer"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 460)
        window.contentViewController = NSHostingController(rootView: MenuBarOrganizerSettingsView(settings: settings, controller: controller, icons: icons))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MenuBarOrganizerSettingsView: View {
    @ObservedObject var settings: MenuBarOrganizerSettings
    @ObservedObject var controller: MenuBarOrganizerController
    @ObservedObject var icons: MenuBarIconStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your menu bar, organized").font(.title2.bold())
                    Text("Keep everyday apps visible. Open the rest from the chevron.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enable organizer", isOn: Binding(get: { settings.isEnabled }, set: { controller.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            .padding(22)
            Divider()
            Form {
                if !controller.isTrusted {
                    Section("Allow Accessibility") {
                        Text("Mac Tools uses Accessibility to find, rearrange, and open menu bar items.")
                        HStack {
                            Button("Allow Accessibility…") { controller.requestAccess(); controller.openPrivacySettings() }
                            Button("Recheck") { controller.refreshAccessStatus() }
                        }
                        Text("Use the installed copy in Applications. The stable signed build needs approval once when replacing an older ad-hoc build.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !icons.hasAccess {
                    Section("Menu Bar Icons") {
                        Text("Show the original menu bar icons in the tray. Screen Recording access is used only for snapshots of the icon windows; images stay in memory on this Mac.")
                            .font(.callout)
                        Button("Allow Menu Bar Icon Capture…") { icons.requestAccess() }
                        Text("App icons are shown until access is allowed.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = controller.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if controller.isArranging {
                    Section("Arrange directly in the menu bar") {
                        Text("Hold ⌘ and drag icons into your preferred order. Items left of │ will be hidden; items right of │ stay visible. Keep the chevron to the right of │.")
                        Button("Done Arranging") { controller.finishArrangement() }
                            .buttonStyle(.borderedProminent).disabled(controller.isBusy)
                    }
                }
                if controller.isTrusted {
                    itemSection("Always Visible", hidden: false)
                    itemSection("Hidden in Dropdown", hidden: true)
                }
                Section {
                    Text("Turning the organizer off or quitting Mac Tools brings all items back. macOS controls the placement of some system icons.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Choices are remembered for apps whose menu bar icons are currently unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if controller.isBusy { ProgressView().controlSize(.small); Text("Arranging…").foregroundStyle(.secondary) }
                else { Text("\(controller.items.count) items · \(controller.hiddenItems.count) hidden").foregroundStyle(.secondary) }
                Spacer()
                Button("Diagnostics") { controller.showDiagnostics() }
                Button("Refresh") { controller.refresh() }.disabled(controller.isBusy)
                Button(controller.isRevealed ? "Hide Now" : "Reveal All") {
                    controller.isRevealed ? controller.hideNow() : controller.revealAll()
                }.disabled(!settings.isEnabled || controller.isBusy || controller.isArranging)
                Button("Arrange in Menu Bar…") { controller.beginArrangement() }
                    .disabled(!settings.isEnabled || !controller.isTrusted || controller.isBusy || controller.isArranging)
            }.padding(16)
        }
        .frame(minWidth: 560, minHeight: 460)
        .task { controller.refresh() }
    }

    private func itemSection(_ title: String, hidden: Bool) -> some View {
        let items = controller.items.filter { settings.isHidden($0.key) == hidden }
        return Section(title) {
            if items.isEmpty {
                Text(hidden ? "Nothing hidden yet. Choose Hide next to an app above." : "No visible items found.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Group {
                        if let icon = item.icon { Image(nsImage: icon).resizable().scaledToFit() }
                        else { Image(systemName: "app.dashed") }
                    }.frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.appName ?? item.title).lineLimit(1)
                        if item.title != item.appName {
                            Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if item.canMove {
                        HStack(spacing: 2) {
                            Button { controller.moveItem(item.key, earlier: true) } label: { Image(systemName: "arrow.left") }
                                .help("Move left").accessibilityLabel("Move \(item.title) left")
                                .disabled(index == 0)
                            Button { controller.moveItem(item.key, earlier: false) } label: { Image(systemName: "arrow.right") }
                                .help("Move right").accessibilityLabel("Move \(item.title) right")
                                .disabled(index == items.count - 1)
                        }.buttonStyle(.borderless).disabled(!settings.isEnabled)
                        Button(hidden ? "Show" : "Hide") { controller.setHidden(!hidden, for: item.key) }
                            .frame(width: 52).accessibilityLabel("\(hidden ? "Show" : "Hide") \(item.title)")
                    } else {
                        Label("System", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(controller.isBusy || !controller.isTrusted)
                .padding(.vertical, 3)
            }
        }
    }
}
