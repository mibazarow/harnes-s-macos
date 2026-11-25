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
        /// D7: hash of the canonical request envelope (provider, model, system blocks,
        /// tool schemas). A ratio measured against a different envelope is a different
        /// experiment and must not move this one. Optional: samples written before the
        /// field existed decode as `nil`.
        var envelopeHash: String?

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

    func record(
        providerID: String,
        model: String,
        measured: Int,
        estimated: Int,
        envelopeHash: String = ""
    ) {
        guard measured > 0, estimated > 0 else { return }
        let key = Self.key(providerID, model)
        let sample = Sample(
            measured: measured, estimated: estimated, at: Timestamps.now(),
            envelopeHash: envelopeHash
        )
        cache[Self.cacheKey(key, envelopeHash)] = sample

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
    func drift(providerID: String, model: String, envelopeHash: String = "") -> Drift? {
        let window = (recent[Self.key(providerID, model)] ?? []).filter {
            ($0.envelopeHash ?? "") == envelopeHash
        }
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
        drift: Drift?,
        basis: String = "usage"
    ) -> String {
        let ratio = estimated > 0 ? Double(measured) / Double(estimated) : 0
        var line = "token_estimate est=\(estimated) actual=\(measured) "
            + String(format: "ratio=%.2f", ratio) + " basis=\(basis)"
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
    func scale(providerID: String, model: String, envelopeHash: String = "") -> Double {
        guard let sample = sample(providerID: providerID, model: model, envelopeHash: envelopeHash)
        else { return 1 }
        return Self.clamp(sample.ratio)
    }

    func lastMeasured(providerID: String, model: String, envelopeHash: String = "") -> Int? {
        sample(providerID: providerID, model: model, envelopeHash: envelopeHash)?.measured
    }

    /// The estimate behind `lastMeasured`. Without it the measured number cannot be
    /// scaled to a prompt whose history has changed since (R15.8).
    func lastSample(
        providerID: String,
        model: String,
        envelopeHash: String = ""
    ) -> (measured: Int, estimated: Int)? {
        sample(providerID: providerID, model: model, envelopeHash: envelopeHash)
            .map { ($0.measured, $0.estimated) }
    }

    func reset(providerID: String, model: String) {
        let key = Self.key(providerID, model)
        cache = cache.filter { !$0.key.hasPrefix(key + "#") }
        recent[key] = nil
        guard let database else { return }
        try? database.queue.write { db in
            try db.execute(sql: "DELETE FROM app_state WHERE key = ?", arguments: [key])
        }
    }

    static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, minScale), maxScale)
    }

    /// Only a sample measured against the same envelope counts. Anything else is a
    /// different experiment: the estimate would be scaled by an unrelated request.
    private func sample(providerID: String, model: String, envelopeHash: String) -> Sample? {
        let key = Self.key(providerID, model)
        if let cached = cache[Self.cacheKey(key, envelopeHash)] { return cached }
        // On disk only the last sample survives; it counts only for its own envelope.
        guard let database,
              let raw = try? database.queue.read({ db in
                  try AppStateStore.read(db, key: key)
              }),
              let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Sample.self, from: data),
              (stored.envelopeHash ?? "") == envelopeHash else { return nil }
        cache[Self.cacheKey(key, envelopeHash)] = stored
        return stored
    }

    private static func cacheKey(_ key: String, _ envelopeHash: String) -> String {
        key + "#" + envelopeHash
    }

    private static func key(_ providerID: String, _ model: String) -> String {
        "token.calibration.\(providerID).\(model)"
    }
}
