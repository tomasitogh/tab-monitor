import XCTest
@testable import TabMonitor

final class DisplayPlanTests: XCTestCase {
    private func hello(_ w: Int, _ h: Int, dpi: Double?, w60: Int? = nil, h60: Int? = nil, bitrate: Int? = nil,
                       id: String? = nil) -> Wire.Hello {
        let max = (w60 != nil || bitrate != nil)
            ? Wire.Hello.MaxDecode(w: 4096, h: 2304, fps: 60, w60: w60, h60: h60, bitrate: bitrate) : nil
        return Wire.Hello(w: w, h: h, dpi: dpi, model: nil, android: nil, id: id, decoder: nil, maxDecode: max)
    }

    private func plan(_ hello: Wire.Hello, _ size: DisplayPlan.Size = .larger,
                      _ quality: DisplayPlan.Quality = .sharp) -> DisplayPlan {
        DisplayPlan(hello: hello, size: size, quality: quality)
    }

    /// La P11 Pro tiene que quedar exactamente como antes de este cambio.
    func testP11ProIsUnchanged() {
        let h = hello(2560, 1600, dpi: 262.5, w60: 2560, h60: 1600, bitrate: 100_000_000)
        let sharp = plan(h)
        XCTAssertEqual([sharp.widthPt, sharp.heightPt, sharp.scale], [1280, 800, 2])
        XCTAssertEqual([sharp.streamWidth, sharp.streamHeight], [2560, 1600])
        XCTAssertEqual(sharp.bitrate, 35_000_000)
        let fast = plan(h, .larger, .fast)
        XCTAssertEqual([fast.streamWidth, fast.streamHeight], [1920, 1200])
        XCTAssertEqual(fast.bitrate, 35_000_000)
        // Un hello viejo (sin dpi ni maxDecode) da lo mismo, y también el dpi que informa de verdad
        // (320, el escalón de densidad; el panel tiene 262).
        XCTAssertEqual(plan(hello(2560, 1600, dpi: nil)), plan(h))
        XCTAssertEqual(plan(hello(2560, 1600, dpi: 320.2, w60: 2560, h60: 1600, bitrate: 100_000_000)), plan(h))
    }

    /// Galaxy Tab S6 Lite: 2000×1200 en 10,4" (224 dpi).
    func testGalaxyTabS6Lite() {
        let h = hello(2000, 1200, dpi: 224.3)
        let larger = plan(h)
        XCTAssertEqual([larger.widthPt, larger.heightPt, larger.scale], [1000, 600, 2])
        XCTAssertEqual([larger.streamWidth, larger.streamHeight], [2000, 1200])
        let fast = plan(h, .larger, .fast)
        XCTAssertEqual([fast.streamWidth, fast.streamHeight], [1500, 900])
        let more = plan(h, .moreSpace)
        XCTAssertEqual([more.widthPt, more.heightPt, more.scale], [1250, 750, 2])
        XCTAssertEqual([more.streamWidth, more.streamHeight], [2000, 1200])
    }

    /// Tablet chica de 8" a 1280×800 (189 dpi): ni 2× (640 pt) ni 1× (1280 pt) dan un texto razonable.
    func testSmallLowResTabletIsScaled() {
        let p = plan(hello(1280, 800, dpi: 189))
        XCTAssertEqual(p.scale, 2)
        XCTAssertEqual([p.widthPt, p.heightPt], [812, 508])
        XCTAssertEqual([p.streamWidth, p.streamHeight], [1280, 800])
    }

    /// Tablet de 10,6" a 1280×800 (142 dpi): 1× queda en el rango y no se reescala.
    func testLowResTabletAtOneX() {
        let p = plan(hello(1280, 800, dpi: 142))
        XCTAssertEqual([p.widthPt, p.heightPt, p.scale], [1280, 800, 1])
        XCTAssertEqual([p.streamWidth, p.streamHeight], [1280, 800])
    }

    /// Si el decoder no llega a 60 fps a la resolución de la pantalla, se transmite menos.
    func testStreamCappedByDecoder() {
        let p = plan(hello(2560, 1600, dpi: 274, w60: 1920, h60: 1200, bitrate: 20_000_000))
        XCTAssertEqual([p.widthPt, p.heightPt], [1280, 800])
        XCTAssertEqual([p.streamWidth, p.streamHeight], [1920, 1200])
        XCTAssertEqual(p.bitrate, 20_000_000)
        let fast = plan(hello(2560, 1600, dpi: 274, w60: 1920, h60: 1200), .larger, .fast)
        XCTAssertEqual([fast.streamWidth, fast.streamHeight], [1440, 900])
    }

    /// Una pantalla que llega vertical se trata como horizontal.
    func testPortraitHelloIsLandscape() {
        XCTAssertEqual(plan(hello(1200, 2000, dpi: 224.3)), plan(hello(2000, 1200, dpi: 224.3)))
    }

    func testSerialPerTablet() {
        XCTAssertEqual(plan(hello(2560, 1600, dpi: nil)).serial, 1)
        let a = plan(hello(2560, 1600, dpi: nil, id: "3f9a0c1e")).serial
        let b = plan(hello(2560, 1600, dpi: nil, id: "0badcafe")).serial
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, 0)
        XCTAssertEqual(a, DisplayPlan.serial(for: "3f9a0c1e"))
    }
}
