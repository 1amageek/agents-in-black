import Foundation
import Observation

@MainActor
@Observable
final class RuntimeAnnouncementCenter {
    var current: RuntimeAnnouncement?

    private var queue: [RuntimeAnnouncement] = []
    private var autoDismissTask: Task<Void, Never>?
    private var recentPresentationTimes: [String: Date] = [:]

    private let dedupeInterval: TimeInterval = 1.0

    func enqueue(_ announcement: RuntimeAnnouncement) {
        if shouldDropDuplicate(announcement) {
            return
        }

        if current == nil {
            present(announcement)
            return
        }

        queue.append(announcement)
    }

    func dismissCurrent() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        current = nil

        if !queue.isEmpty {
            let next = queue.removeFirst()
            present(next)
        }
    }

    func clear() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        queue = []
        current = nil
        recentPresentationTimes = [:]
    }

    private func present(_ announcement: RuntimeAnnouncement) {
        current = announcement
        recentPresentationTimes[announcement.dedupeKey] = Date()

        guard let delay = announcement.autoDismissDelay else {
            return
        }

        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            await MainActor.run {
                guard let self else { return }
                guard self.current?.id == announcement.id else { return }
                self.dismissCurrent()
            }
        }
    }

    private func shouldDropDuplicate(_ announcement: RuntimeAnnouncement) -> Bool {
        trimExpiredDedupeEntries(now: Date())

        if current?.dedupeKey == announcement.dedupeKey {
            return true
        }

        if queue.contains(where: { $0.dedupeKey == announcement.dedupeKey }) {
            return true
        }

        if let latest = recentPresentationTimes[announcement.dedupeKey] {
            let age = Date().timeIntervalSince(latest)
            if age < dedupeInterval {
                return true
            }
        }

        return false
    }

    private func trimExpiredDedupeEntries(now: Date) {
        for (key, date) in recentPresentationTimes where now.timeIntervalSince(date) >= dedupeInterval {
            recentPresentationTimes.removeValue(forKey: key)
        }
    }
}
