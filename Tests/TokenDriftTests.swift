import XCTest
@testable import Harness

/// R31.4: the estimate must be checked against what the provider billed, and the
/// verdict has to be a number in the log, not a feeling.
final class TokenDriftTests: XCTestCase {
    func testDriftIsAveragedOverTheWindow() async {
        let calibration = TokenCalibration(database: nil)
        for _ in 0..<20 {
            await calibration.record(providerID: "p", model: "m", measured: 1_100, estimated: 1_000)
        }
        let drift = await calibration.drift(providerID: "p", model: "m")
        XCTAssertEqual(drift?.samples, 20)
        XCTAssertEqual(drift?.ratio ?? 0, 1.1, accuracy: 0.0001)
        XCTAssertEqual(drift?.deviationPercent ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(drift?.withinTolerance, true)
    }

    func testOnlyTheLastTwentySamplesCount() async {
        let calibration = TokenCalibration(database: nil)
        // One wild early sample must not decide the verdict forever.
        await calibration.record(providerID: "p", model: "m", measured: 3_000, estimated: 1_000)
        for _ in 0..<20 {
            await calibration.record(providerID: "p", model: "m", measured: 1_000, estimated: 1_000)
        }
        let drift = await calibration.drift(providerID: "p", model: "m")
        XCTAssertEqual(drift?.samples, 20)
        XCTAssertEqual(drift?.ratio ?? 0, 1.0, accuracy: 0.0001)
    }

    func testBigDriftIsFlagged() async {
        let calibration = TokenCalibration(database: nil)
        for _ in 0..<5 {
            await calibration.record(providerID: "p", model: "m", measured: 1_400, estimated: 1_000)
        }
        let drift = await calibration.drift(providerID: "p", model: "m")
        XCTAssertEqual(drift?.withinTolerance, false)
    }

    func testLogLineCarriesBothNumbersAndTheVerdict() async {
        let calibration = TokenCalibration(database: nil)
        for _ in 0..<20 {
            await calibration.record(providerID: "p", model: "m", measured: 1_050, estimated: 1_000)
        }
        let drift = await calibration.drift(providerID: "p", model: "m")
        let line = TokenCalibration.logLine(measured: 1_050, estimated: 1_000, drift: drift)
        XCTAssertTrue(line.contains("est=1000"))
        XCTAssertTrue(line.contains("actual=1050"))
        XCTAssertTrue(line.contains("ratio=1.05"))
        XCTAssertTrue(line.contains("avg20=1.05"))
        XCTAssertTrue(line.contains("within_tolerance"))
    }

    func testNoSamplesMeansNoDriftLine() async {
        let calibration = TokenCalibration(database: nil)
        let drift = await calibration.drift(providerID: "p", model: "m")
        XCTAssertNil(drift)
        XCTAssertFalse(
            TokenCalibration.logLine(measured: 10, estimated: 10, drift: nil)
                .contains("within_tolerance")
        )
    }
}
