import Foundation

/// Compares the app's local token estimate with what the provider actually reported.
///
/// Three numbers lived side by side and none was ever checked against reality:
/// `TokenEstimator` for compaction, `ContextComposer.plan` for the window, and
/// `prompt_tokens` from the provider. The estimator is deliberately pessimistic, but the
/// error still drifts with the model and the mix of Russian, code and tool output. The
/// ratio is kept per provider and model and applied wherever "does it fit" is decided.
actor TokenCalibration {
    struct Sample: Codable, Sendable {
        var measured: Int
        var estimated: Int
        var at: String

        var ratio: Double {
            guard estimated > 0 else { return 1 }
            return Double(measured) / Double(estimated)
        }
    }

    /// Outside this range the sample is treated as noise (a request that carried an
    /// attachment the estimator cannot see, a provider that counts images differently)
    /// rather than as a reason to shrink or grow the working window by a third.
    static let minScale = 0.75
    static let maxScale = 1.6

    private let database: AppDatabase?
    private var cache: [String: Sample] = [:]
    /// R31.4: the last samples per provider and model. A single ratio is one request's
    /// accident; twenty of them show whether the estimator drifts steadily or spikes.
    private var recent: [String: [Sample]] = [:]
    static let driftWindow = 20
    /// Above this, the estimate is wrong enough to matter: the window and the
    /// compaction trigger are both computed from it.
    static let driftTolerancePercent = 15.0

    init(database: AppDatabase?) {
        self.database = database
    }

    func record(providerID: String, model: String, measured: Int, estimated: Int) {
        guard measured > 0, estimated > 0 else { return }
        let key = Self.key(providerID, model)
        let sample = Sample(measured: measured, estimated: estimated, at: Timestamps.now())
        cache[key] = sample

        var window = recent[key] ?? []
        window.append(sample)
        if window.count > Self.driftWindow {
            window.removeFirst(window.count - Self.driftWindow)
        }
        recent[key] = window

        guard let database,
              let data = try? JSONEncoder().encode(sample),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? database.queue.write { db in
            try AppStateStore.write(db, key: key, value: raw)
        }
    }

    struct Drift: Equatable, Sendable {
        let samples: Int
        /// Average of measured / estimated over the window.
        let ratio: Double
        /// `abs(ratio - 1)` in percent.
        let deviationPercent: Double

        var withinTolerance: Bool { deviationPercent <= driftTolerancePercent }
    }

    /// R31.4: how far the local estimate sits from what the provider billed, averaged
    /// over the last `driftWindow` requests for this model.
    func drift(providerID: String, model: String) -> Drift? {
        let window = recent[Self.key(providerID, model)] ?? []
        guard !window.isEmpty else { return nil }
        let ratios = window.map(\.ratio)
        let average = ratios.reduce(0, +) / Double(ratios.count)
        return Drift(
            samples: ratios.count,
            ratio: average,
            deviationPercent: abs(average - 1) * 100
        )
    }

    /// One line for `latency.log`: the last request's numbers plus the window verdict.
    static func logLine(
        measured: Int,
        estimated: Int,
        drift: Drift?
    ) -> String {
        let ratio = estimated > 0 ? Double(measured) / Double(estimated) : 0
        var line = "token_estimate est=\(estimated) actual=\(measured) "
            + String(format: "ratio=%.2f", ratio)
        if let drift {
            line += String(
                format: " avg%d=%.2f dev=%.0f%%",
                drift.samples, drift.ratio, drift.deviationPercent
            )
            line += drift.withinTolerance ? " within_tolerance" : " over_tolerance"
        }
        return line
    }

    /// Multiplier for local estimates. 1 when nothing has been measured yet.
    func scale(providerID: String, model: String) -> Double {
        guard let sample = sample(providerID: providerID, model: model) else { return 1 }
        return Self.clamp(sample.ratio)
    }

    func lastMeasured(providerID: String, model: String) -> Int? {
        sample(providerID: providerID, model: model)?.measured
    }

    /// The estimate behind `lastMeasured`. Without it the measured number cannot be
    /// scaled to a prompt whose history has changed since (R15.8).
    func lastSample(providerID: String, model: String) -> (measured: Int, estimated: Int)? {
        sample(providerID: providerID, model: model).map { ($0.measured, $0.estimated) }
    }

    func reset(providerID: String, model: String) {
        let key = Self.key(providerID, model)
        cache[key] = nil
        recent[key] = nil
        guard let database else { return }
        try? database.queue.write { db in
            try db.execute(sql: "DELETE FROM app_state WHERE key = ?", arguments: [key])
        }
    }

    static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, minScale), maxScale)
    }

    private func sample(providerID: String, model: String) -> Sample? {
        let key = Self.key(providerID, model)
        if let sample = cache[key] { return sample }
        guard let database else { return nil }

        let raw: String? = try? database.queue.read { db in
            try AppStateStore.read(db, key: key)
        }
        guard let raw, let data = raw.data(using: .utf8),
              let sample = try? JSONDecoder().decode(Sample.self, from: data) else { return nil }
        cache[key] = sample
        return sample
    }

    private static func key(_ providerID: String, _ model: String) -> String {
        "token.calibration.\(providerID).\(model)"
    }
}
