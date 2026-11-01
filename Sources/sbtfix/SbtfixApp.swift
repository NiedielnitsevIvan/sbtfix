import SwiftUI
import Combine
import SonyProtocol

/// A status item with a plain NSMenu that hosts the panel. On macOS 27 MenuBarExtra(.window) often
/// took 1.5-3 s to open after the app was idle; in an A/B test a menu opened at once and most
/// consistently. menuWillOpen is also a reliable "opened" hook, which MenuBarExtra's onAppear isn't.
@main
final class SbtfixApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = HeadphoneController()
    private let menu = NSMenu()
    private let retryItem = NSMenuItem(title: "Retry", action: #selector(retry), keyEquivalent: "")
    private var startupItems: [NSMenuItem] = []
    private var item: NSStatusItem?
    private var icon: AnyCancellable?
    private var retryVisibility: AnyCancellable?

    static func main() {
        let app = SbtfixApp()
        NSApplication.shared.delegate = app
        // NSApplication.delegate is weak.
        withExtendedLifetime(app) { NSApplication.shared.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            Screenshots.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }

        let panel = NSMenuItem()
        let host = NSHostingView(rootView: ControlPanel(controller: controller))
        host.rootView.onResize = { [weak host] in host?.frame.size = $0 }
        host.frame.size = host.fittingSize
        panel.view = host
        menu.addItem(panel)
        menu.addItem(.separator())
        let startup = NSMenu()
        for mode in StartupMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setStartupMode), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            startup.addItem(item)
            startupItems.append(item)
        }
        menu.addItem(withTitle: "On connect", action: nil, keyEquivalent: "").submenu = startup
        menu.addItem(.separator())
        retryItem.target = self
        menu.addItem(retryItem)
        menu.addItem(withTitle: "Quit sbtfix", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        menu.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        self.item = item
        // @Published fires even for an equal value, and each icon change redraws it on every Space,
        // so only set the image when the symbol changes.
        icon = controller.$status.combineLatest(controller.$ambient)
            .map { $0 == .connected ? $1.mode.symbol : "headphones" }
            .removeDuplicates()
            .sink { item.button?.image = NSImage(systemSymbolName: $0, accessibilityDescription: "sbtfix") }
        retryVisibility = controller.$status.sink { [retryItem] in retryItem.isHidden = $0 == .connected }
        // Connect at launch rather than when the menu is first opened.
        controller.start()
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in startupItems {
            item.state = item.representedObject as? StartupMode == controller.startupMode ? .on : .off
        }
        // After the menu is up: refresh() writes to the headphones synchronously. The main queue
        // still runs while the menu is open.
        DispatchQueue.main.async { self.controller.refresh() }
    }

    @objc private func retry() { controller.connect() }

    @objc private func setStartupMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? StartupMode { controller.startupMode = mode }
    }
}

extension AmbientMode {
    var title: String {
        switch self {
        case .noiseCancelling: "Noise Cancelling"
        case .windNoiseReduction: "Wind Reduction"
        case .ambient: "Ambient Sound"
        case .off: "Off"
        }
    }

    var symbol: String {
        switch self {
        case .noiseCancelling: "person.wave.2.fill"
        case .windNoiseReduction: "wind"
        case .ambient: "ear.fill"
        case .off: "headphones"
        }
    }
}

struct ControlPanel: View {
    @ObservedObject var controller: HeadphoneController
    var onResize: (CGSize) -> Void = { _ in }
    @State private var level: Double = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if controller.status == .connected {
                if !controller.availableModes.isEmpty {
                    modePicker
                    if controller.ambient.mode == .ambient { ambientOptions }
                }
                if let speakToChat = controller.speakToChat {
                    Divider()
                    Toggle("Speak-to-Chat", isOn: Binding(
                        get: { speakToChat },
                        set: { controller.setSpeakToChat($0) }))
                }
            } else {
                statusMessage
            }
        }
        .padding(16)
        // Fits the widest battery row (earbuds: L, R and Case at 100%) on one line.
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        // A menu sizes its view item by the view's frame, which NSHostingView doesn't follow when the
        // content grows or shrinks (connecting, switching to Ambient), so report it.
        .onGeometryChange(for: CGSize.self, of: \.size) { onResize($0) }
        .toggleStyle(.switch)
        .onAppear { level = Double(controller.ambient.level) }
        .onChange(of: controller.ambient.level) { _, new in level = Double(new) }
    }

    private var header: some View {
        let b = controller.batteries
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: controller.profile.isEarbuds ? "earbuds" : "headphones").font(.title2)
                Text(controller.deviceName ?? "Sony Headphones").font(.headline).lineLimit(1)
                Spacer()
                if let single = b.single { batteryLabel(nil, single) }
            }
            // Earbuds report up to three levels; give them their own row.
            if b.single == nil && !b.isEmpty {
                HStack(spacing: 12) {
                    if let left = b.left { batteryLabel("L", left) }
                    if let right = b.right { batteryLabel("R", right) }
                    if let c = b.caseBattery { batteryLabel("Case", c) }
                }
            }
        }
    }

    private func batteryLabel(_ prefix: String?, _ battery: BatteryLevel) -> some View {
        let text = [prefix, "\(battery.level)%"].compactMap { $0 }.joined(separator: " ")
        return Label(text, systemImage: battery.charging ? "battery.100.bolt" : batterySymbol(battery.level))
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .foregroundStyle(battery.level <= 20 ? .red : .secondary)
    }

    @ViewBuilder private var modePicker: some View {
        let grid = LazyVGrid(columns: [GridItem(spacing: 8), GridItem(spacing: 8)], spacing: 8) {
            ForEach(controller.availableModes) { mode in
                let selected = controller.ambient.mode == mode
                Button { controller.setMode(mode) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.symbol).font(.title2)
                        Text(mode.title).font(.caption).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .foregroundStyle(selected ? .white : .primary)
                    .modeBackground(selected: selected)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        if #available(macOS 26, *) {
            GlassEffectContainer { grid }
        } else {
            grid
        }
    }

    private var ambientOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ambient level")
                Spacer()
                Text("\(Int(level))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $level, in: 1...20, step: 1)
                .onChange(of: level) { _, new in
                    if Int(new) != controller.ambient.level { controller.setAmbientLevel(Int(new)) }
                }
            Toggle("Focus on voice", isOn: Binding(
                get: { controller.ambient.focusOnVoice },
                set: { controller.setFocusOnVoice($0) }))
        }
    }

    private var statusMessage: some View {
        Group {
            switch controller.status {
            case .searching:
                Text("Waiting for headphones to connect…")
            case .connecting:
                HStack { ProgressView().controlSize(.small); Text("Connecting…") }
            case .failed(let reason):
                Text(reason).foregroundStyle(.red)
            case .connected:
                EmptyView()
            }
        }
        .font(.callout)
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }
}

private extension View {
    /// The selected mode is a solid fill, like Control Center's: a glass tint turns gray in an inactive window,
    /// and the status menu draws its content inactive (see the switches).
    @ViewBuilder func modeBackground(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        if selected {
            background(Color.accentColor, in: shape)
        } else if #available(macOS 26, *) {
            // Liquid Glass adapts to the system's accessibility settings (e.g. Reduce Transparency) by itself.
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(Color.primary.opacity(0.07), in: shape)
        }
    }
}
