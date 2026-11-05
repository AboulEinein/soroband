import Foundation

/// Which moment the island shows, and until when. One moment shows at a time; the others wait,
/// alerts first, then transfers, then the rest, each kind in the order it came. A moment closes
/// `MomentKind.duration` seconds after it opened, or after the pointer left it: the pointer on the
/// island keeps it open. The next one opens `gap` seconds after, so the island closes between
/// them.
///
/// A transfer is one moment per app: its progress updates the open or waiting moment in place;
/// once it has shown, progress waits for no new moment, and only its end (`done`) opens one again.
///
/// Time is passed in (seconds on any steady clock), so the queue is a plain value; the island's
/// controller runs one timer to `nextChange`.
struct MomentQueue: Equatable {
    static let gap: TimeInterval = 0.45
    /// Moments waiting at most; past it the least important, newest, is dropped.
    static let capacity = 8

    private(set) var current: Moment?
    private(set) var waiting: [Moment] = []
    /// When the open moment closes; nil while the pointer keeps it open.
    private(set) var closesAt: TimeInterval?
    /// When the next waiting moment may open, after the island closed.
    private(set) var opensAt: TimeInterval?
    private(set) var hovering = false
    /// Apps whose transfer has shown, until it ends.
    private var shownTransfers: Set<String> = []
    private var nextID = 0

    /// When the queue next changes by itself: `advance` is due then.
    var nextChange: TimeInterval? {
        if current != nil { return closesAt }
        return waiting.isEmpty ? nil : opensAt
    }

    /// Adds `content`, or updates the transfer it continues. Returns whether it is a new moment.
    @discardableResult
    mutating func post(_ content: MomentContent, now: TimeInterval) -> Bool {
        if case .transfer(let app, _, _, _, let done) = content {
            if case .transfer(let open, _, _, _, _) = current?.content, open.id == app.id {
                current?.content = content
                if done { closesAt = hovering ? nil : now + MomentKind.transfer.duration }
                return false
            }
            if let index = waiting.firstIndex(where: { Self.transferApp($0.content) == app.id }) {
                waiting[index].content = content
                return false
            }
            if !done && shownTransfers.contains(app.id) { return false }
            if done && !shownTransfers.contains(app.id) {
                // It ended before it could show: show nothing of a transfer nobody saw start.
                return false
            }
        }
        nextID += 1
        waiting.append(Moment(id: nextID, content: content))
        // Stable: equal priorities keep their order.
        waiting = waiting.enumerated().sorted {
            ($0.element.kind.priority, -$0.offset) > ($1.element.kind.priority, -$1.offset)
        }.map(\.element)
        if waiting.count > Self.capacity { waiting.removeLast() }
        advance(now: now)
        return true
    }

    /// New numbers for the open moment, of the same kind: the peek follows each poll.
    mutating func update(_ content: MomentContent) {
        guard current?.kind == content.kind else { return }
        current?.content = content
    }

    /// Closes the open moment if its time is up, and opens the next one when it may.
    mutating func advance(now: TimeInterval) {
        if current != nil, let closesAt, now >= closesAt { close(now: now) }
        guard current == nil, !waiting.isEmpty, now >= (opensAt ?? now) else { return }
        let moment = waiting.removeFirst()
        current = moment
        opensAt = nil
        closesAt = hovering ? nil : now + moment.kind.duration
        if let app = Self.transferApp(moment.content) {
            if case .transfer(_, _, _, _, true) = moment.content {
                shownTransfers.remove(app)
            } else {
                shownTransfers.insert(app)
            }
        }
    }

    /// The pointer entered or left the island's outline.
    mutating func hover(_ inside: Bool, now: TimeInterval) {
        guard inside != hovering else { return }
        hovering = inside
        guard let current else { return }
        closesAt = inside ? nil : now + current.kind.duration
    }

    /// Closes the open moment now, as its buttons do.
    mutating func dismiss(now: TimeInterval) {
        guard current != nil else { return }
        close(now: now)
        advance(now: now)
    }

    /// Drops every moment of `kind`, open or waiting, when it is turned off or no longer applies.
    mutating func remove(_ kind: MomentKind, now: TimeInterval) {
        waiting.removeAll { $0.kind == kind }
        if current?.kind == kind { dismiss(now: now) }
        // Their ends will not come: an app's next transfer starts afresh.
        if kind == .transfer { shownTransfers.removeAll() }
    }

    private mutating func close(now: TimeInterval) {
        if case .transfer(let app, _, _, _, true) = current?.content { shownTransfers.remove(app.id) }
        current = nil
        closesAt = nil
        opensAt = now + Self.gap
    }

    private static func transferApp(_ content: MomentContent) -> String? {
        if case .transfer(let app, _, _, _, _) = content { return app.id }
        return nil
    }
}
