import XCTest
@testable import SonyProtocol

final class FramingTests: XCTestCase {
    func testInitRequestEncoding() {
        // 0c 00 00000002 00 00, checksum 0x0e
        let bytes = Message(type: .command1, sequence: 0, payload: Command.initRequest).encode()
        XCTAssertEqual(bytes, [0x3E, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0E, 0x3C])
    }

    func testEscapingRoundTrip() {
        let msg = Message(type: .command1, sequence: 1, payload: [0x3C, 0x3D, 0x3E, 0x10])
        let encoded = msg.encode()
        // No raw special bytes between header and trailer
        XCTAssertFalse(encoded.dropFirst().dropLast().contains(0x3C))
        XCTAssertFalse(encoded.dropFirst().dropLast().contains(0x3E))
        var parser = FrameParser()
        XCTAssertEqual(parser.feed(encoded), [msg])
    }

    func testParserHandlesSplitAndConcatenatedFrames() {
        let a = Message(type: .ack, sequence: 1, payload: [])
        let b = Message(type: .command1, sequence: 0, payload: [0x69, 0x15, 0x00, 0x01, 0x01, 0x00, 0x14])
        let stream = a.encode() + b.encode()
        var parser = FrameParser()
        XCTAssertEqual(parser.feed(Array(stream[..<5])), [])
        XCTAssertEqual(parser.feed(Array(stream[5...])), [a, b])
    }

    func testBadChecksumIsDropped() {
        var bytes = Message(type: .command1, sequence: 0, payload: [0x01]).encode()
        bytes[bytes.count - 2] &+= 1
        var parser = FrameParser()
        XCTAssertEqual(parser.feed(bytes), [])
    }
}

final class VersionDetectionTests: XCTestCase {
    func testInitReplyLengthSelectsVersion() {
        // WH-1000XM3
        XCTAssertEqual(EventParser.parse([0x01, 0x00, 0x40, 0x10], version: nil), .initReply(.v1))
        // WH-1000XM5 fw 2.4.1 (captured)
        XCTAssertEqual(EventParser.parse([0x01, 0x00, 0x03, 0x00, 0x20, 0x16, 0x00, 0x00], version: nil), .initReply(.v2))
    }

    func testNothingElseParsesBeforeInit() {
        XCTAssertEqual(EventParser.parse([0x23, 0x00, 0x46, 0x01], version: nil), .unknown(0x23))
    }
}

final class V2Tests: XCTestCase {
    func testAmbientParse() {
        // Captured from WH-1000XM5 fw 2.4.1
        XCTAssertEqual(EventParser.parse([0x67, 0x17, 0x01, 0x01, 0x01, 0x00, 0x14], version: .v2),
                       .ambient(AmbientState(mode: .ambient, focusOnVoice: false, level: 20), .v2(inquiredType: 0x17, windByte: false)))
        XCTAssertEqual(EventParser.parse([0x69, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14], version: .v2),
                       .ambient(AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 20), .v2(inquiredType: 0x17, windByte: false)))
        XCTAssertEqual(EventParser.parse([0x67, 0x15, 0x01, 0x00, 0x00, 0x00, 0x05], version: .v2),
                       .ambient(AmbientState(mode: .off, focusOnVoice: false, level: 5), .v2(inquiredType: 0x15, windByte: false)))
    }

    func testAmbientWithWindByte() {
        let layout = AmbientLayout.v2(inquiredType: 0x17, windByte: true)
        let wind = AmbientState(mode: .windNoiseReduction, focusOnVoice: false, level: 10)
        XCTAssertEqual(Command.setAmbient(wind, layout: layout), [0x68, 0x17, 0x01, 0x01, 0x00, 0x03, 0x00, 0x0A])
        XCTAssertEqual(EventParser.parse([0x69, 0x17, 0x01, 0x01, 0x00, 0x03, 0x00, 0x0A], version: .v2), .ambient(wind, layout))
        let nc = AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 10)
        XCTAssertEqual(EventParser.parse(Command.setAmbient(nc, layout: layout).replacingFirst(0x69), version: .v2), .ambient(nc, layout))
    }

    func testAmbientOnlyModel() {
        XCTAssertEqual(EventParser.parse([0x67, 0x22, 0x01, 0x01, 0x00, 0x00, 0x0A], version: .v2),
                       .ambient(AmbientState(mode: .ambient, focusOnVoice: false, level: 10), .v2(inquiredType: 0x22, windByte: false)))
    }

    func testAmbientSetRoundTrips() {
        let s = AmbientState(mode: .ambient, focusOnVoice: true, level: 17)
        let layout = AmbientLayout.v2(inquiredType: 0x17, windByte: false)
        let set = Command.setAmbient(s, layout: layout)
        XCTAssertEqual(set, [0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x11])
        XCTAssertEqual(EventParser.parse(set.replacingFirst(0x69), version: .v2), .ambient(s, layout))
    }

    func testBattery() {
        XCTAssertEqual(EventParser.parse([0x23, 0x00, 0x28, 0x00], version: .v2), .battery(single: BatteryLevel(level: 40, charging: false)))
        XCTAssertEqual(EventParser.parse([0x25, 0x09, 0x50, 0x00, 0x00, 0x00], version: .v2),
                       .batteryDual(left: BatteryLevel(level: 80, charging: false), right: nil))
        XCTAssertEqual(EventParser.parse([0x23, 0x0A, 0x3C, 0x01], version: .v2), .batteryCase(BatteryLevel(level: 60, charging: true)))
    }

    func testSpeakToChat() {
        XCTAssertEqual(Command.setSpeakToChat(true, .v2), [0xF8, 0x0C, 0x00, 0x01])
        XCTAssertEqual(EventParser.parse([0xF9, 0x0C, 0x00, 0x01], version: .v2), .speakToChat(enabled: true))
        XCTAssertEqual(EventParser.parse([0xF7, 0x0C, 0x01, 0x01], version: .v2), .speakToChat(enabled: false))
    }
}

final class V1Tests: XCTestCase {
    func testAmbientSetWithoutWind() {
        let layout = AmbientLayout.v1(windCapable: false)
        XCTAssertEqual(Command.setAmbient(AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 12), layout: layout),
                       [0x68, 0x02, 0x11, 0x00, 0x01, 0x01, 0x00, 0x00])
        XCTAssertEqual(Command.setAmbient(AmbientState(mode: .ambient, focusOnVoice: true, level: 12), layout: layout),
                       [0x68, 0x02, 0x11, 0x00, 0x00, 0x01, 0x01, 0x0C])
        XCTAssertEqual(Command.setAmbient(AmbientState(mode: .off, focusOnVoice: false, level: 12), layout: layout),
                       [0x68, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0C])
    }

    func testAmbientSetWithWind() {
        let layout = AmbientLayout.v1(windCapable: true)
        XCTAssertEqual(Command.setAmbient(AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 5), layout: layout),
                       [0x68, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00])
        XCTAssertEqual(Command.setAmbient(AmbientState(mode: .windNoiseReduction, focusOnVoice: false, level: 5), layout: layout),
                       [0x68, 0x02, 0x11, 0x02, 0x01, 0x01, 0x00, 0x00])
    }

    func testAmbientParse() {
        XCTAssertEqual(EventParser.parse([0x69, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00, 0x00], version: .v1),
                       .ambient(AmbientState(mode: .noiseCancelling, focusOnVoice: false, level: 0), .v1(windCapable: true)))
        XCTAssertEqual(EventParser.parse([0x69, 0x02, 0x01, 0x02, 0x01, 0x01, 0x00, 0x00], version: .v1),
                       .ambient(AmbientState(mode: .windNoiseReduction, focusOnVoice: false, level: 0), .v1(windCapable: true)))
        XCTAssertEqual(EventParser.parse([0x67, 0x02, 0x01, 0x00, 0x00, 0x01, 0x01, 0x0F], version: .v1),
                       .ambient(AmbientState(mode: .ambient, focusOnVoice: true, level: 15), .v1(windCapable: false)))
        XCTAssertEqual(EventParser.parse([0x67, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0F], version: .v1),
                       .ambient(AmbientState(mode: .off, focusOnVoice: false, level: 15), .v1(windCapable: false)))
    }

    func testBattery() {
        XCTAssertEqual(EventParser.parse([0x11, 0x00, 0x46, 0x01], version: .v1), .battery(single: BatteryLevel(level: 70, charging: true)))
        XCTAssertEqual(EventParser.parse([0x13, 0x01, 0x32, 0x00, 0x34, 0x01], version: .v1),
                       .batteryDual(left: BatteryLevel(level: 50, charging: false), right: BatteryLevel(level: 52, charging: true)))
        XCTAssertEqual(Command.getBattery(.v1, kind: .dualAlt), nil)
    }

    func testSpeakToChat() {
        XCTAssertEqual(Command.setSpeakToChat(true, .v1), [0xF8, 0x05, 0x01, 0x01])
        XCTAssertEqual(EventParser.parse([0xF7, 0x05, 0x01, 0x01], version: .v1), .speakToChat(enabled: true))
        XCTAssertEqual(EventParser.parse([0xF9, 0x05, 0x01, 0x00], version: .v1), .speakToChat(enabled: false))
        // WH-1000XM4 answers a GET with 00 in the third byte
        XCTAssertEqual(EventParser.parse([0xF7, 0x05, 0x00, 0x00], version: .v1), .speakToChat(enabled: false))
        XCTAssertEqual(EventParser.parse([0xF7, 0x05, 0x00, 0x01], version: .v1), .speakToChat(enabled: true))
        // The 02 acknowledgement form carries no value
        XCTAssertEqual(EventParser.parse([0xF9, 0x05, 0x02, 0x01], version: .v1), .unknown(0xF9))
    }

    func testEqualizer() {
        XCTAssertEqual(Command.getEqualizer, [0x56, 0x01])
        XCTAssertEqual(Command.setEqualizer(.bright), [0x58, 0x01, 0x10, 0x00])
        // Captured from a WH-1000XM4, firmware 2.5.0
        XCTAssertEqual(EventParser.parse([0x57, 0x01, 0x00, 0x06, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A], version: .v1), .equalizer(.off))
        XCTAssertEqual(EventParser.parse([0x59, 0x01, 0x10, 0x06, 0x09, 0x0A, 0x0F, 0x11, 0x11, 0x13], version: .v1), .equalizer(.bright))
        // A preset this enum doesn't know, and the v2 form (WF-1000XM5), are ignored
        XCTAssertEqual(EventParser.parse([0x57, 0x01, 0x30, 0x06, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A], version: .v1), .unknown(0x57))
        XCTAssertEqual(EventParser.parse([0x57, 0x00, 0xA0, 0x06, 0x14, 0x0B, 0x0A, 0x0D, 0x09, 0x0C], version: .v2), .unknown(0x57))
    }

    func testV1CodesAreNotParsedAsV2() {
        XCTAssertEqual(EventParser.parse([0x11, 0x00, 0x46, 0x01], version: .v2), .unknown(0x11))
    }
}

final class DeviceProfileTests: XCTestCase {
    func testModes() {
        XCTAssertEqual(DeviceProfile.forName("WH-1000XM5").modes(layout: nil), [.noiseCancelling, .ambient, .off])
        XCTAssertEqual(DeviceProfile.forName("WH-1000XM6").modes(layout: nil), [.noiseCancelling, .ambient, .off])
        XCTAssertEqual(DeviceProfile.forName("WH-1000XM4").modes(layout: nil), [.noiseCancelling, .windNoiseReduction, .ambient, .off])
        XCTAssertEqual(DeviceProfile.forName("WF-C510").modes(layout: nil), [.ambient, .off])
        XCTAssertEqual(DeviceProfile.forName("LinkBuds").modes(layout: nil), [])
        XCTAssertEqual(DeviceProfile.forName("LinkBuds S").modes(layout: nil), [.noiseCancelling, .ambient, .off])
    }

    func testWindLearnedFromDevice() {
        XCTAssertEqual(DeviceProfile.forName("WH-9999").modes(layout: .v2(inquiredType: 0x17, windByte: true)),
                       [.noiseCancelling, .windNoiseReduction, .ambient, .off])
    }

    func testEarbudsAndSonyDetection() {
        XCTAssertTrue(DeviceProfile.forName("WF-1000XM5").isEarbuds)
        XCTAssertFalse(DeviceProfile.forName("WH-1000XM5").isEarbuds)
        XCTAssertTrue(DeviceProfile.isSony(name: "WH-1000XM6"))
        XCTAssertFalse(DeviceProfile.isSony(name: "LE_WH-1000XM6"))
        XCTAssertTrue(DeviceProfile.isSony(name: "ULT WEAR"))
        XCTAssertFalse(DeviceProfile.isSony(name: "AirPods Pro"))
    }
}

private extension Array where Element == UInt8 {
    func replacingFirst(_ byte: UInt8) -> [UInt8] {
        var copy = self
        copy[0] = byte
        return copy
    }
}
