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

/// D7: a sample from a different request envelope is a different experiment.
final class EnvelopeCalibrationTests: XCTestCase {
    func testSamplesFromDifferentEnvelopesDoNotMix() async {
        let calibration = TokenCalibration(database: nil)
        await calibration.record(providerID: "p", model: "m", measured: 2_000,
                                 estimated: 1_000, envelopeHash: "A")
        await calibration.record(providerID: "p", model: "m", measured: 1_000,
                                 estimated: 1_000, envelopeHash: "B")

        let a = await calibration.scale(providerID: "p", model: "m", envelopeHash: "A")
        let b = await calibration.scale(providerID: "p", model: "m", envelopeHash: "B")
        let unknown = await calibration.scale(providerID: "p", model: "m", envelopeHash: "C")

        XCTAssertEqual(a, 1.6, accuracy: 0.001, "A масштабируется только своим замером")
        XCTAssertEqual(b, 1.0, accuracy: 0.001)
        XCTAssertEqual(unknown, 1.0, "без своего замера — только оценка")
    }

    func testDriftIgnoresOtherEnvelopes() async {
        let calibration = TokenCalibration(database: nil)
        for _ in 0..<3 {
            await calibration.record(providerID: "p", model: "m", measured: 1_500,
                                     estimated: 1_000, envelopeHash: "A")
        }
        await calibration.record(providerID: "p", model: "m", measured: 1_000,
                                 estimated: 1_000, envelopeHash: "B")

        let driftA = await calibration.drift(providerID: "p", model: "m", envelopeHash: "A")
        XCTAssertEqual(driftA?.samples, 3)
        XCTAssertEqual(driftA?.ratio ?? 0, 1.5, accuracy: 0.001)
    }

    func testLogLineNamesTheBasis() {
        let line = TokenCalibration.logLine(measured: 900, estimated: 1_000, drift: nil,
                                            basis: "estimated")
        XCTAssertTrue(line.contains("basis=estimated"), line)
    }
}
