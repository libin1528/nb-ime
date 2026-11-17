import Foundation

final class PasteClock {
    var now: TimeInterval = 0
    private var jobs: [(at: TimeInterval, work: () -> Void)] = []

    func later(_ delay: TimeInterval, _ work: @escaping () -> Void) { jobs.append((now + delay, work)) }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let i = jobs.indices.min(by: { jobs[$0].at < jobs[$1].at }), jobs[i].at <= end + 0.000001 {
            let job = jobs.remove(at: i)
            now = job.at
            job.work()
        }
        now = end
    }
}
