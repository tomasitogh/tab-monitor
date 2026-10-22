import XCTest
@testable import TabMonitor

/// Los bytes de ejemplo de PROTOCOL.md; los tests de Android usan los mismos.
final class ProtocolTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        Data(s.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    private func message(_ header: String, _ json: String) -> Data {
        hex(header) + Data(json.utf8)
    }

    func testVideoFrame() {
        let nal = hex("00 00 00 01 67 42 00 1F 00 00 00 01 68 CE 3C 80 00 00 00 01 65 88 84")
        let expected = hex("01 00 00 00 20 01 00 00 00 00 00 0F 42 40") + nal
        XCTAssertEqual(Wire.video(keyframe: true, captureMicros: 1_000_000, annexB: nal), expected)
    }

    func testConfig() {
        let expected = message("11 00 00 00 3E", #"{"codec":"h264","w":2560,"h":1600,"fps":60,"bitrate":35000000}"#)
        XCTAssertEqual(Wire.config(codec: "h264", w: 2560, h: 1600, fps: 60, bitrate: 35_000_000), expected)
    }

    func testPong() {
        XCTAssertEqual(Wire.pong(ts: 123456, mac: 987654), message("14 00 00 00 1A", #"{"ts":123456,"mac":987654}"#))
    }

    func testIncoming() throws {
        let hello = message("10 00 00 00 CB",
                            #"{"w":2560,"h":1600,"dpi":262.5,"model":"TB-J706F","android":"12","id":"3f9a0c1e","decoder":"OMX.qcom.video.decoder.avc","maxDecode":{"w":3840,"h":2160,"fps":60,"w60":2560,"h60":1600,"bitrate":100000000}}"#)
        let key = hex("12 00 00 00 00")
        let ping = message("13 00 00 00 0D", #"{"ts":123456}"#)
        let stats = message("15 00 00 00 4B",
                            #"{"fps":59.8,"latencyMs":{"avg":38.2,"p95":51.0},"decodeMs":6.1,"dropped":0}"#)
        let all = hello + key + ping + stats

        // De a un byte, para probar que arma mensajes partidos.
        var parser = Wire.Parser()
        var got: [Wire.Incoming] = []
        for byte in all { got += try parser.feed(Data([byte])) }

        XCTAssertEqual(got.count, 4)
        guard case .hello(let h) = got[0] else { return XCTFail("esperaba hello") }
        XCTAssertEqual(h.w, 2560)
        XCTAssertEqual(h.h, 1600)
        XCTAssertEqual(h.model, "TB-J706F")
        XCTAssertEqual(h.maxDecode?.fps, 60)
        XCTAssertEqual(h.dpi, 262.5)
        XCTAssertEqual(h.id, "3f9a0c1e")
        XCTAssertEqual(h.maxDecode?.w60, 2560)
        XCTAssertEqual(h.maxDecode?.bitrate, 100_000_000)
        guard case .key = got[1] else { return XCTFail("esperaba key") }
        guard case .ping(let p) = got[2] else { return XCTFail("esperaba ping") }
        XCTAssertEqual(p.ts, 123456)
        guard case .stats(let s) = got[3] else { return XCTFail("esperaba stats") }
        XCTAssertEqual(s.latencyMs?.p95, 51.0)
        XCTAssertEqual(s.dropped, 0)
    }

    func testUnknownTypeIsSkipped() throws {
        var parser = Wire.Parser()
        let got = try parser.feed(hex("7F 00 00 00 02 AA BB 12 00 00 00 00"))
        XCTAssertEqual(got.count, 1)
        guard case .key = got[0] else { return XCTFail("esperaba key") }
    }

    func testTooLargeIsAnError() {
        var parser = Wire.Parser()
        XCTAssertThrowsError(try parser.feed(hex("01 01 00 00 01")))
    }
}
