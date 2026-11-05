import AppKit
import SonyProtocol

/// `sbtfix --screenshots <dir>` captures the menu in each state, in light and dark mode, to PNGs.
/// Used to produce the images in docs/screenshots. Liquid Glass only renders on screen, so for each
/// state a child process (`--screenshot <state> <light|dark>`) opens the real menu over a plain
/// backdrop and this process captures it with screencapture. The menu draws its switches in their
/// inactive (gray) style, so the sample states keep switches off.
enum Screenshots {
    private static let states: [(name: String, controller: () -> HeadphoneController)] = [
        ("noise-cancelling", { .preview(status: .connected) }),
        ("ambient", { .preview(status: .connected,
                               ambient: AmbientState(mode: .ambient, focusOnVoice: false, level: 14)) }),
        ("off", { .preview(status: .connected, ambient: AmbientState(mode: .off, focusOnVoice: false, level: 20)) }),
        ("wind-xm4", { .preview(status: .connected, name: "WH-1000XM4",
                                ambient: AmbientState(mode: .windNoiseReduction, focusOnVoice: false, level: 20),
                                equalizer: .off) }),
        ("earbuds", { .preview(status: .connected, name: "WF-1000XM5",
                               batteries: Batteries(left: BatteryLevel(level: 80, charging: false),
                                                    right: BatteryLevel(level: 76, charging: false),
                                                    caseBattery: BatteryLevel(level: 45, charging: true))) }),
        ("waiting", { .preview(status: .searching, batteries: Batteries()) }),
        ("connecting", { .preview(status: .connecting, batteries: Batteries()) }),
        ("bluetooth-off", { .preview(status: .failed("Bluetooth is turned off"), batteries: Batteries()) }),
    ]

    /// Set in the child process: the sample controller and appearance to show.
    static let shot: (controller: HeadphoneController, dark: Bool)? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshot"), i + 2 < args.count,
              let state = states.first(where: { $0.name == args[i + 1] }) else { return nil }
        return (state.controller(), args[i + 2] == "dark")
    }()

    /// False if an image couldn't be captured; the reason is printed.
    static func render(to dir: URL) -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            print("Allow your terminal under System Settings > Privacy & Security > Screen Recording, then try again.")
            return false
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var succeeded = true
        for appearance in ["dark", "light"] {
            for state in states {
                let url = dir.appendingPathComponent("\(state.name)-\(appearance).png")
                // A menu opened right after the previous child quit sometimes closes at once; try again.
                if !(1...3).contains(where: { _ in shoot(state.name, appearance, to: url) }) {
                    print("Couldn't capture \(url.lastPathComponent)")
                    succeeded = false
                }
            }
        }
        return succeeded
    }

    /// Runs one child and captures its menu. False if the menu didn't stay open for it.
    private static func shoot(_ state: String, _ appearance: String, to url: URL) -> Bool {
        let child = Process()
        let out = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--screenshot", state, appearance]
        child.standardOutput = out
        guard (try? child.run()) != nil else { return false }
        defer { child.terminate(); child.waitUntilExit() }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        let n = line.split(separator: " ").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard n.count == 4 else { return false }
        // Let it fade in; the window list only shows whether it's still open.
        Thread.sleep(forTimeInterval: 1)
        guard child.isRunning, hasMenuWindow(child.processIdentifier) else { return false }
        return capture(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).insetBy(dx: -28, dy: -28), to: url)
            && child.isRunning
    }

    /// Child process: opens the menu over a plain backdrop and prints its frame (top-left origin) for
    /// the parent, which ends the process once it has captured it.
    static func open(_ menu: NSMenu, dark: Bool) -> Never {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let backdrop = NSWindow(contentRect: NSRect(x: screen.maxX - 460, y: screen.maxY - 680, width: 460, height: 680),
                                styleMask: .borderless, backing: .buffered, defer: false)
        // GitHub's page colors, so the images blend into the README.
        backdrop.backgroundColor = dark ? NSColor(srgbRed: 0x0D / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1) : .white
        backdrop.level = NSWindow.Level(NSWindow.Level.popUpMenu.rawValue - 1)
        backdrop.orderFrontRegardless()
        let topLeft = NSPoint(x: screen.maxX - 420, y: screen.maxY - 40)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        print(topLeft.x, screenHeight - topLeft.y, menu.size.width, menu.size.height)
        fflush(stdout)
        NSApp.activate()
        menu.popUp(positioning: nil, at: topLeft, in: nil)
        exit(0)
    }

    private static func hasMenuWindow(_ pid: pid_t) -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == menuLevel
        }
    }

    /// screencapture exits with 0 even when it fails, so success means the file exists. It goes to a
    /// temporary name first, which keeps the old image if the capture fails.
    private static func capture(_ rect: CGRect, to url: URL) -> Bool {
        let temporary = url.deletingPathExtension().appendingPathExtension("tmp.png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", temporary.path]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return (try? FileManager.default.replaceItemAt(url, withItemAt: temporary)) != nil
    }
}
