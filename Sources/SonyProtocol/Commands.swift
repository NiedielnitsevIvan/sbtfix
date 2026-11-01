import Foundation

/// Payload builders/parsers for Sony's headphone protocol.
///
/// Two generations exist: v1 (WH-1000XM2–XM4, WF-1000XM3, …) and v2 (WH-1000XM5/XM6,
/// WF-1000XM4/XM5, LinkBuds S, …). The version is detected from the init reply.
/// Byte layouts follow Gadgetbridge's SonyProtocolImplV1/V2; see docs/PROTOCOL.md.
public enum ProtocolVersion: Equatable {
    case v1, v2
}

public enum AmbientMode: String, CaseIterable, Identifiable {
    case noiseCancelling, windNoiseReduction, ambient, off
    public var id: String { rawValue }
}

public struct AmbientState: Equatable {
    public var mode: AmbientMode
    public var focusOnVoice: Bool
    /// 0...20
    public var level: Int

    public init(mode: AmbientMode, focusOnVoice: Bool, level: Int) {
        self.mode = mode
        self.focusOnVoice = focusOnVoice
        self.level = level
    }
}

/// How a device encodes its ambient-sound payload. Learned from its replies.
public enum AmbientLayout: Equatable {
    case v1(windCapable: Bool)
    /// `inquiredType` is 0x15, 0x17 or 0x22 (ambient-only models); `windByte` adds a byte for wind reduction.
    case v2(inquiredType: UInt8, windByte: Bool)

    public var supportsWind: Bool {
        switch self {
        case .v1(let wind): wind
        case .v2(_, let wind): wind
        }
    }
}

public struct BatteryLevel: Equatable {
    public var level: Int
    public var charging: Bool

    public init(level: Int, charging: Bool) {
        self.level = level
        self.charging = charging
    }
}

public enum BatteryKind: CaseIterable {
    case single, dual, dualAlt, caseBattery
}

public enum Command {
    public static let initRequest: [UInt8] = [0x00, 0x00]

    // MARK: Ambient sound / noise cancelling

    /// v2 firmware differs in which layout it answers, so callers may probe several types.
    public static func getAmbient(_ version: ProtocolVersion, inquiredType: UInt8 = 0x17) -> [UInt8] {
        switch version {
        case .v1: [0x66, 0x02]
        case .v2: [0x66, inquiredType]
        }
    }

    public static func setAmbient(_ s: AmbientState, layout: AmbientLayout) -> [UInt8] {
        let level = UInt8(clamping: max(0, min(20, s.level)))
        let voice: UInt8 = s.focusOnVoice ? 0x01 : 0x00
        switch layout {
        case .v1(let windCapable):
            let modeByte: UInt8
            switch s.mode {
            case .noiseCancelling: modeByte = windCapable ? 0x02 : 0x01
            case .windNoiseReduction: modeByte = 0x01
            case .ambient, .off: modeByte = 0x00
            }
            let usesLevel = s.mode == .ambient || s.mode == .off
            return [0x68, 0x02, s.mode == .off ? 0x00 : 0x11, windCapable ? 0x02 : 0x00,
                    modeByte, 0x01, voice, usesLevel ? level : 0x00]
        case .v2(let inquiredType, let windByte):
            var p: [UInt8] = [0x68, inquiredType, 0x01,
                              s.mode == .off ? 0x00 : 0x01,
                              s.mode == .ambient ? 0x01 : 0x00]
            if windByte { p.append(s.mode == .windNoiseReduction ? 0x03 : 0x02) }
            p += [voice, level]
            return p
        }
    }

    // MARK: Battery

    /// Returns nil when the kind doesn't exist in that protocol version.
    public static func getBattery(_ version: ProtocolVersion, kind: BatteryKind) -> [UInt8]? {
        switch (version, kind) {
        case (.v1, .single): [0x10, 0x00]
        case (.v1, .dual): [0x10, 0x01]
        case (.v1, .caseBattery): [0x10, 0x02]
        case (.v1, .dualAlt): nil
        case (.v2, .single): [0x22, 0x00]
        case (.v2, .dual): [0x22, 0x09]
        case (.v2, .dualAlt): [0x22, 0x01]
        case (.v2, .caseBattery): [0x22, 0x0A]
        }
    }

    // MARK: Speak-to-Chat

    public static func getSpeakToChat(_ version: ProtocolVersion) -> [UInt8] {
        switch version {
        case .v1: [0xF6, 0x05]
        case .v2: [0xF6, 0x0C]
        }
    }

    public static func setSpeakToChat(_ enabled: Bool, _ version: ProtocolVersion) -> [UInt8] {
        switch version {
        case .v1: [0xF8, 0x05, 0x01, enabled ? 0x01 : 0x00]
        // v2 is inverted: 0x00 means enabled.
        case .v2: [0xF8, 0x0C, enabled ? 0x00 : 0x01, 0x01]
        }
    }
}

public enum Event: Equatable {
    case initReply(ProtocolVersion)
    case ambient(AmbientState, AmbientLayout)
    case battery(single: BatteryLevel)
    case batteryDual(left: BatteryLevel?, right: BatteryLevel?)
    case batteryCase(BatteryLevel)
    case speakToChat(enabled: Bool)
    case unknown(UInt8)
}

public enum EventParser {
    /// `version` is nil until the init reply has been seen.
    public static func parse(_ p: [UInt8], version: ProtocolVersion?) -> Event {
        guard let code = p.first else { return .unknown(0xFF) }
        if code == 0x01 {
            // v1 replies with 4 bytes (e.g. 01 00 40 10), v2 with 8 (e.g. 01 00 03 00 20 16 00 00).
            return .initReply(p.count == 4 ? .v1 : .v2)
        }
        guard let version else { return .unknown(code) }
        let parsed: Event?
        switch (version, code) {
        case (.v1, 0x67), (.v1, 0x69): parsed = parseAmbientV1(p)
        case (.v2, 0x67), (.v2, 0x69): parsed = parseAmbientV2(p)
        case (.v1, 0x11), (.v1, 0x13): parsed = parseBattery(p, single: 0x00, dual: [0x01], case: 0x02)
        case (.v2, 0x23), (.v2, 0x25): parsed = parseBattery(p, single: 0x00, dual: [0x01, 0x09], case: 0x0A)
        case (.v1, 0xF7), (.v1, 0xF9):
            // Third byte is 00 in replies (WH-1000XM4: F7 05 00 00) and 01 in notifications. Setting it also
            // sends an 02 form (preview state, not the setting).
            parsed = p.count == 4 && p[1] == 0x05 && p[2] <= 0x01 ? .speakToChat(enabled: p[3] == 0x01) : nil
        case (.v2, 0xF7), (.v2, 0xF9):
            parsed = p.count >= 3 && p[1] == 0x0C ? .speakToChat(enabled: p[2] == 0x00) : nil
        default: parsed = nil
        }
        return parsed ?? .unknown(code)
    }

    private static func parseAmbientV1(_ p: [UInt8]) -> Event? {
        guard p.count == 8, p[1] == 0x02 else { return nil }
        let windCapable = p[3] == 0x02
        let mode: AmbientMode
        switch (p[2] != 0x00, windCapable, p[4]) {
        case (false, _, _): mode = .off
        case (true, _, 0x00): mode = .ambient
        case (true, false, 0x01), (true, true, 0x02): mode = .noiseCancelling
        case (true, true, 0x01): mode = .windNoiseReduction
        default: return nil
        }
        guard p[7] <= 20 else { return nil }
        return .ambient(AmbientState(mode: mode, focusOnVoice: p[6] == 0x01, level: Int(p[7])), .v1(windCapable: windCapable))
    }

    private static func parseAmbientV2(_ p: [UInt8]) -> Event? {
        guard (6...8).contains(p.count), [0x15, 0x17, 0x22].contains(p[1]) else { return nil }
        let windByte = p[1] == 0x17 && p.count > 7
        let mode: AmbientMode
        if p[3] == 0x00 {
            mode = .off
        } else if p[1] == 0x22 {
            mode = .ambient  // model without noise cancelling
        } else if windByte && (p[5] == 0x03 || p[5] == 0x05) {
            mode = .windNoiseReduction
        } else {
            mode = p[4] == 0x01 ? .ambient : .noiseCancelling
        }
        let level = p[p.count - 1]
        guard level <= 20 else { return nil }
        let state = AmbientState(mode: mode, focusOnVoice: p[p.count - 2] == 0x01, level: Int(level))
        return .ambient(state, .v2(inquiredType: p[1], windByte: windByte))
    }

    private static func parseBattery(_ p: [UInt8], single: UInt8, dual: [UInt8], case caseCode: UInt8) -> Event? {
        guard p.count >= 4 else { return nil }
        let first = BatteryLevel(level: Int(p[2]), charging: p[3] == 0x01)
        if p[1] == single { return .battery(single: first) }
        if p[1] == caseCode { return .batteryCase(first) }
        if dual.contains(p[1]), p.count >= 6 {
            // A level of 0 means that earbud isn't connected.
            let right = BatteryLevel(level: Int(p[4]), charging: p[5] == 0x01)
            return .batteryDual(left: first.level > 0 ? first : nil, right: right.level > 0 ? right : nil)
        }
        return nil
    }
}
