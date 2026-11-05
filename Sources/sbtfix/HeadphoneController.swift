import Foundation
import IOBluetooth
import os
import SonyProtocol

struct Batteries: Equatable {
    var single: BatteryLevel?
    var left: BatteryLevel?
    var right: BatteryLevel?
    var caseBattery: BatteryLevel?

    var isEmpty: Bool { single == nil && left == nil && right == nil && caseBattery == nil }
}

/// Mode forced right after the headphones connect.
///
/// WH-1000XM4 always power on in Noise Cancelling (factory behaviour, not configurable)
/// and ignore the NC/AMB button until they are worn. Sending the mode over the control
/// channel does not depend on the wear sensor, so this is the only way to have them in
/// Off / Ambient before they go on your head.
enum StartupMode: String, CaseIterable {
    case keep, off, ambient

    var title: String {
        switch self {
        case .keep: "Keep device setting"
        case .off: "Off"
        case .ambient: "Ambient Sound"
        }
    }

    private static let key = "startupMode"

    static func load() -> StartupMode {
        StartupMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .keep
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: Self.key) }
}

/// Owns the RFCOMM link to the headphones. All IOBluetooth callbacks arrive on the main run loop.
final class HeadphoneController: NSObject, ObservableObject {
    private let log = Logger(subsystem: "io.github.htsecurity.sbtfix", category: "bt")

    enum Status: Equatable {
        case searching
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var deviceName: String?
    @Published private(set) var profile = DeviceProfile()
    @Published private(set) var batteries = Batteries()
    /// Level and focus-on-voice are remembered across launches (see remember(_:)): v1 reports level 0
    /// outside ambient mode, and the startup mode needs them to switch to ambient without resetting them.
    @Published private(set) var ambient = AmbientState(
        mode: .noiseCancelling,
        focusOnVoice: UserDefaults.standard.bool(forKey: HeadphoneController.focusKey),
        level: UserDefaults.standard.object(forKey: HeadphoneController.levelKey) as? Int ?? 10)
    @Published private(set) var ambientLayout: AmbientLayout?
    /// nil until the device answers; stays nil on models without Speak-to-Chat.
    @Published private(set) var speakToChat: Bool?
    /// nil until the device answers; stays nil on models without an equalizer.
    @Published private(set) var equalizer: EqualizerPreset?

    /// Applied once per connection, as soon as the device has reported its ambient state.
    var startupMode: StartupMode = StartupMode.load() {
        didSet { startupMode.save() }
    }

    var availableModes: [AmbientMode] { profile.modes(layout: ambientLayout) }

    private static let levelKey = "ambientLevel"
    private static let focusKey = "focusOnVoice"

    /// Control service UUIDs: v2 (WH-1000XM5 and newer) first, then v1 (XM3/XM4 era).
    private static let serviceUUIDs: [[UInt8]] = [
        [0x95, 0x6C, 0x7B, 0x26, 0xD4, 0x9A, 0x4B, 0xA8, 0xB0, 0x3F, 0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2],
        [0x96, 0xCC, 0x20, 0x3E, 0x50, 0x68, 0x46, 0xAD, 0xB3, 0x2D, 0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA],
    ]

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = FrameParser()
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?

    // The headphones accept one command at a time; the next is sent once the ACK arrives.
    private var queue: [(key: String?, payload: [UInt8])] = []
    private var sequence: UInt8 = 0
    private var awaitingAck = false
    private var ackTimer: Timer?
    private var batteryTimer: Timer?
    private var retryTimer: Timer?
    private var connectingSince: Date?
    /// While the user is changing ambient settings, the device echoes each intermediate value.
    /// Those echoes lag behind the UI, so they're ignored until things settle, then re-read once.
    private var lastAmbientSet = Date.distantPast
    private var ambientSyncTimer: Timer?
    /// Speak-to-Chat replies lag behind a toggle the same way (a read sent before it, an earlier toggle's
    /// echo), so they're ignored for a moment after one.
    private var lastStcSet = Date.distantPast

    /// Detected from the init reply; nothing but init is sent before it's known.
    private var version: ProtocolVersion?
    /// The startup mode waits for the first ambient report so it uses the device's own layout (level and
    /// focus come from remember(_:)). Expires, so a much later report (a button press) can't trigger it.
    private var startupModeDeadline: Date?

    func start() {
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceDidConnect(_:device:)))
        startRetryTimer()
        connect()
    }

    /// Safety net for Bluetooth being switched on and connect events we miss (e.g. while it was off).
    /// Connect events are the fast path (see deviceDidConnect), so it polls slowly and only while disconnected.
    private func startRetryTimer() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.status == .connecting, let since = self.connectingSince, Date().timeIntervalSince(since) > 20 {
                self.log.error("connect timed out")
                self.tearDown()
            }
            guard self.channel == nil, self.status != .connecting else { return }
            self.connect()
        }
        retryTimer?.tolerance = 5
    }

    func connect() {
        guard channel == nil else { return }
        // Runs on every retry tick. @Published fires even for an equal value, and each fire makes the
        // panel re-render, even while the menu is closed, so only assign what actually changed.
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            let off = Status.failed("Bluetooth is turned off")
            if status != off { status = off }
            return
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let sony = paired.filter { DeviceProfile.isSony(name: $0.name ?? "") }
        guard let target = sony.first(where: { $0.isConnected() }) else {
            let idle: Status = sony.isEmpty ? .failed("No paired Sony headphones found") : .searching
            if status != idle { status = idle }
            if deviceName != sony.first?.name { deviceName = sony.first?.name }
            return
        }
        device = target
        deviceName = target.name
        profile = DeviceProfile.forName(target.name ?? "")
        status = .connecting
        connectingSince = Date()
        // The slow retry tick also enforces the 20 s connect timeout; move it so it does so on time.
        retryTimer?.fireDate = Date(timeIntervalSinceNow: 21)

        if let channelID = rfcommChannelID(for: target) {
            openChannel(channelID)
        } else {
            let uuids = Self.serviceUUIDs.map { IOBluetoothSDPUUID(bytes: $0, length: 16) }
            target.performSDPQuery(self, uuids: uuids)
        }
    }

    // MARK: - Commands

    /// Re-reads state from the headphones (e.g. after buttons on the headphones were used).
    func refresh() {
        // While disconnected, re-check now so the panel doesn't show a status up to one slow tick old.
        retryTimer?.fire()
        guard let version, status == .connected else { return }
        if profile.hasAmbientControl {
            if case .v2(let type, _) = ambientLayout {
                enqueue(Command.getAmbient(.v2, inquiredType: type), key: "get-anc")
            } else {
                enqueue(Command.getAmbient(version), key: "get-anc")
            }
        }
        requestBattery()
        enqueue(Command.getSpeakToChat(version), key: "get-stc")
        requestEqualizer()
    }

    func setMode(_ mode: AmbientMode) {
        var s = ambient
        s.mode = mode
        sendAmbient(s)
    }

    func setAmbientLevel(_ level: Int) {
        var s = ambient
        s.level = level
        sendAmbient(s)
    }

    func setFocusOnVoice(_ on: Bool) {
        var s = ambient
        s.focusOnVoice = on
        sendAmbient(s)
    }

    func setSpeakToChat(_ on: Bool) {
        guard let version else { return }
        speakToChat = on
        lastStcSet = Date()
        enqueue(Command.setSpeakToChat(on, version), key: "stc")
    }

    func setEqualizer(_ preset: EqualizerPreset) {
        equalizer = preset
        enqueue(Command.setEqualizer(preset), key: "eq")
    }

    private func sendAmbient(_ s: AmbientState) {
        guard let version else { return }
        ambient = s
        remember(s)
        // If the device hasn't told us its layout yet, fall back to the most common one.
        let layout = ambientLayout ?? (version == .v1
            ? .v1(windCapable: profile.hasWindNoiseReduction)
            : .v2(inquiredType: 0x17, windByte: profile.hasWindNoiseReduction))
        enqueue(Command.setAmbient(s, layout: layout), key: "anc")
        lastAmbientSet = Date()
        ambientSyncTimer?.invalidate()
        ambientSyncTimer = menuSafeTimer(1.0) { [weak self] _ in
            guard let self, let version = self.version else { return }
            if case .v2(let type, _) = layout {
                self.enqueue(Command.getAmbient(.v2, inquiredType: type), key: "get-anc")
            } else {
                self.enqueue(Command.getAmbient(version), key: "get-anc")
            }
        }
    }

    /// Level and focus only mean something in ambient mode, so only ambient states are saved.
    private func remember(_ s: AmbientState) {
        guard s.mode == .ambient else { return }
        UserDefaults.standard.set(s.level, forKey: Self.levelKey)
        UserDefaults.standard.set(s.focusOnVoice, forKey: Self.focusKey)
    }

    /// v1 only: newer models use other preset ids.
    private func requestEqualizer() {
        if version == .v1 { enqueue(Command.getEqualizer, key: "get-eq") }
    }

    private func requestBattery() {
        guard let version else { return }
        for kind in profile.batteryKinds {
            if let payload = Command.getBattery(version, kind: kind) {
                enqueue(payload, key: "battery-\(kind)")
            }
        }
    }

    // MARK: - Connection

    private func rfcommChannelID(for d: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        for bytes in Self.serviceUUIDs {
            let uuid = IOBluetoothSDPUUID(bytes: bytes, length: 16)
            guard let record = d.getServiceRecord(for: uuid) else { continue }
            var id: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&id) == kIOReturnSuccess { return id }
        }
        return nil
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        // A duplicate or stale completion (Retry, timeout) must not open a second channel.
        guard let d = device, d == self.device, channel == nil, self.status == .connecting else { return }
        if let id = rfcommChannelID(for: d) {
            openChannel(id)
        } else {
            self.status = .failed("\(d.name ?? "This device") doesn't expose the Sony control service")
        }
    }

    private func openChannel(_ id: BluetoothRFCOMMChannelID) {
        guard let device else { return }
        var ch: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&ch, withChannelID: id, delegate: self)
        if result == kIOReturnSuccess {
            channel = ch
        } else {
            status = .failed(String(format: "Could not open control channel (0x%08x)", result))
        }
    }

    @objc private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard DeviceProfile.isSony(name: device.name ?? "") else { return }
        // Give the audio profiles a moment to settle before opening RFCOMM.
        // Kept short on purpose: the startup mode must land before the headphones go on.
        // Retried a few times because the retry timer is only a slow safety net.
        for delay in [1.0, 3, 6, 10] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.channel == nil, self.status != .connecting else { return }
                self.connect()
            }
        }
    }

    @objc private func deviceDidDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        tearDown()
    }

    private func tearDown() {
        ackTimer?.invalidate()
        ackTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        ambientSyncTimer?.invalidate()
        ambientSyncTimer = nil
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        disconnectNotification?.unregister()
        disconnectNotification = nil
        queue.removeAll()
        awaitingAck = false
        sequence = 0
        parser = FrameParser()
        version = nil
        startupModeDeadline = nil
        ambientLayout = nil
        batteries = Batteries()
        speakToChat = nil
        equalizer = nil
        status = .searching
        startRetryTimer()
    }

    // MARK: - Messaging

    private func enqueue(_ payload: [UInt8], key: String? = nil) {
        // Coalesce repeated settings (e.g. slider drags) so only the latest value is sent.
        if let key, let i = queue.firstIndex(where: { $0.key == key }) {
            queue[i].payload = payload
        } else {
            queue.append((key, payload))
        }
        pump()
    }

    private func pump() {
        guard !awaitingAck, status == .connected, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        write(Message(type: .command1, sequence: sequence, payload: next.payload).encode())
        awaitingAck = true
        ackTimer?.invalidate()
        ackTimer = menuSafeTimer(1.5) { [weak self] _ in
            self?.awaitingAck = false
            self?.pump()
        }
    }

    /// A one-shot timer that also fires while the menu is open (the run loop is then in event-tracking
    /// mode), so commands sent from the panel aren't held until it closes.
    private func menuSafeTimer(_ interval: TimeInterval, _ block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func write(_ bytes: [UInt8]) {
        guard let channel else { return }
        log.debug("tx \(hex(bytes), privacy: .public)")
        var data = bytes
        data.withUnsafeMutableBytes { buf in
            _ = channel.writeSync(buf.baseAddress, length: UInt16(buf.count))
        }
    }

    private func handle(_ message: Message) {
        switch message.type {
        case .ack:
            sequence = message.sequence
            awaitingAck = false
            ackTimer?.invalidate()
            pump()
        case .command1, .command2:
            log.debug("rx \(hex(message.payload), privacy: .public)")
            write(Message(type: .ack, sequence: 1 &- message.sequence, payload: []).encode())
            apply(EventParser.parse(message.payload, version: version))
        }
    }

    private func apply(_ event: Event) {
        log.debug("event \(String(describing: event), privacy: .public)")
        switch event {
        case .initReply(let v):
            guard version == nil else { return }
            version = v
            log.info("protocol \(String(describing: v), privacy: .public)")
            // 5 s covers the slowest first reply (v2's second GET, after the first one's 1.5 s ACK timeout).
            startupModeDeadline = Date().addingTimeInterval(5)
            requestInitialState(v)
        case let .ambient(state, layout):
            ambientLayout = layout
            let isFirstReport = Date() < startupModeDeadline ?? .distantPast
            startupModeDeadline = nil
            // Don't clobber a change the user is still making (see lastAmbientSet).
            guard !queue.contains(where: { $0.key == "anc" }),
                  Date().timeIntervalSince(lastAmbientSet) > 0.8 else { return }
            var s = state
            // Level and focus only apply in ambient mode (v1 reports level 0 elsewhere): keep the last real ones.
            if s.mode != .ambient {
                s.level = ambient.level
                s.focusOnVoice = ambient.focusOnVoice
            }
            ambient = s
            remember(s)
            if isFirstReport {
                applyStartupMode()
                // It must land before the headphones go on: send it ahead of the battery/Speak-to-Chat reads.
                if let i = queue.firstIndex(where: { $0.key == "anc" }) { queue.insert(queue.remove(at: i), at: 0) }
            }
        case .battery(let level):
            batteries.single = level
        case let .batteryDual(left, right):
            batteries.left = left
            batteries.right = right
        case .batteryCase(let level):
            batteries.caseBattery = level
        case .speakToChat(let enabled):
            guard !queue.contains(where: { $0.key == "stc" }),
                  Date().timeIntervalSince(lastStcSet) > 0.8 else { return }
            speakToChat = enabled
        case .equalizer(let preset):
            equalizer = preset
        case .unknown:
            break
        }
    }

    private func applyStartupMode() {
        guard profile.hasAmbientControl else { return }
        switch startupMode {
        case .keep:
            return
        case .off:
            log.info("startup mode: off")
            setMode(.off)
        case .ambient:
            log.info("startup mode: ambient")
            setMode(.ambient)
        }
    }

    /// The headphones can miss the init request right after connecting (a WH-1000XM4 ignored one sent
    /// ~1 s after its audio link came up), and nothing else is sent until it's answered, so repeat it.
    private func requestInit(attempt: Int = 1) {
        guard version == nil, status == .connected, attempt <= 5 else { return }
        enqueue(Command.initRequest, key: "init")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestInit(attempt: attempt + 1) }
    }

    private func requestInitialState(_ v: ProtocolVersion) {
        if profile.hasAmbientControl {
            switch v {
            case .v1:
                enqueue(Command.getAmbient(.v1))
            case .v2:
                // Firmware differs in which layout it answers (0x15, 0x17 or 0x22; XM5 fw 2.4.1
                // only answers 0x17). Ask with each — the reply tells us which to use for SET.
                for type: UInt8 in profile.hasNoiseCancelling ? [0x17, 0x15] : [0x17, 0x22] {
                    enqueue(Command.getAmbient(.v2, inquiredType: type))
                }
            }
        }
        requestBattery()
        enqueue(Command.getSpeakToChat(v))
        requestEqualizer()
    }
}

extension HeadphoneController: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else {
            channel = nil
            status = .failed(String(format: "Control channel failed to open (0x%08x)", error))
            log.error("channel open failed \(error)")
            startRetryTimer()
            return
        }
        status = .connected
        retryTimer?.invalidate()
        retryTimer = nil
        log.info("control channel open")
        disconnectNotification = device?.register(forDisconnectNotification: self,
                                                  selector: #selector(deviceDidDisconnect(_:device:)))
        // Everything else is requested once the init reply tells us the protocol version.
        requestInit()
        // Battery isn't always pushed; refresh it periodically.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.requestBattery()
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        for message in parser.feed(bytes) {
            handle(message)
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        tearDown()
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - Screenshot support

extension HeadphoneController {
    /// A controller with fixed state and no Bluetooth, used to render README screenshots.
    static func preview(status: Status, name: String = "WH-1000XM5",
                        batteries: Batteries = Batteries(single: BatteryLevel(level: 72, charging: false)),
                        ambient: AmbientState = AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 20),
                        speakToChat: Bool? = false,
                        equalizer: EqualizerPreset? = nil) -> HeadphoneController {
        let c = HeadphoneController()
        c.status = status
        c.deviceName = name
        c.profile = DeviceProfile.forName(name)
        c.batteries = batteries
        c.ambient = ambient
        c.speakToChat = speakToChat
        c.equalizer = equalizer
        return c
    }
}
