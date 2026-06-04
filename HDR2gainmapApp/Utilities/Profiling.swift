import QuartzCore   // CACurrentMediaTime (monotonic clock)

/// Lightweight console timing for diagnosing the image-selection path.
/// Marked `nonisolated` because it is called from `@concurrent`/`nonisolated` contexts as well as
/// the main actor (with `-default-isolation MainActor`, free types would otherwise be MainActor).
nonisolated enum Prof {
    /// Master switch — flip to `true` to re-enable profiling output to the console.
    static let enabled = false

    /// Start a timer. Returns an opaque timestamp to pass back to `toc`.
    @inline(__always) static func tic() -> Double { CACurrentMediaTime() }

    /// Print the elapsed time since `start` for `label`.
    static func toc(_ label: String, _ start: Double) {
        guard enabled else { return }
        let ms = (CACurrentMediaTime() - start) * 1000
        print(String(format: "⏱️ PROF %@ — %.1f ms", label, ms))
    }
}
