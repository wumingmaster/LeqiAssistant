import Foundation

struct OrganizerWidgetData: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let preview: String?
        let date: Date?
        let endsAt: Date?
        let allDay: Bool?

        init(id: String, title: String, preview: String?, date: Date?, endsAt: Date? = nil, allDay: Bool? = nil) {
            self.id = id
            self.title = title
            self.preview = preview
            self.date = date
            self.endsAt = endsAt
            self.allDay = allDay
        }

        var expiry: Date? { endsAt ?? date?.addingTimeInterval(60) }
    }

    static let group = "group.party.xiaoyu.glasses.leqiassistant"
    static let fileName = "organizer-widget.json"

    let memos: [Item]?
    let events: [Item]?
    let systemEvents: [Item]?

    init(memos: [Item]?, events: [Item]?, systemEvents: [Item]? = nil) {
        self.memos = memos
        self.events = events
        self.systemEvents = systemEvents
    }

    // Prefer the live phone calendar when authorized. Mixing in a stale mirror
    // could make a calendar event reappear after it is edited or deleted.
    var calendarEvents: [Item]? { systemEvents ?? events }

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent(fileName)
    }

    static func read() -> Self? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write() throws -> Bool {
        guard let file = Self.file else { throw CocoaError(.fileNoSuchFile) }
        if Self.read() == self { return false }
        let data = try JSONEncoder().encode(self)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
}
