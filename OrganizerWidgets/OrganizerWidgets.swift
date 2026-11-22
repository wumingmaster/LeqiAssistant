import SwiftUI
import WidgetKit

private enum OrganizerKind: String, CaseIterable {
    case memos
    case schedule

    var name: String { self == .memos ? "眼镜便签" : "眼镜日程" }
    var description: Text {
        switch self {
        case .memos: Text("查看由乐奇助手同步的 Rokid 眼镜便签。")
        case .schedule: Text("查看由乐奇助手同步的 Rokid 眼镜日程。")
        }
    }
    var icon: String { self == .memos ? "note.text" : "calendar" }
    var deepLink: URL? { URL(string: "leqiassistant://" + rawValue) }
}

private struct OrganizerEntry: TimelineEntry {
    let date: Date
    let items: [OrganizerWidgetData.Item]?
}

private struct OrganizerProvider: TimelineProvider {
    let kind: OrganizerKind

    func placeholder(in context: Context) -> OrganizerEntry {
        OrganizerEntry(date: .now, items: [
            .init(id: "sample", title: kind == .memos ? "给今天留一条便签" : "下一项日程",
                  preview: kind == .memos ? "打开乐奇助手同步眼镜上的内容。" : nil,
                  date: kind == .schedule ? .now.addingTimeInterval(3_600) : nil)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (OrganizerEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(.now, data: OrganizerWidgetData.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OrganizerEntry>) -> Void) {
        let data = OrganizerWidgetData.read()
        let now = Date.now
        var dates = [now]
        if kind == .schedule, let events = data?.calendarEvents {
            let updates = Set(events.compactMap(\.expiry).filter { $0 > now })
            dates.append(contentsOf: updates.sorted().prefix(12))
        }
        let entries = dates.map { entry($0, data: data) }
        completion(Timeline(entries: entries, policy: .after((dates.last ?? now).addingTimeInterval(3_600))))
    }

    private func entry(_ date: Date, data: OrganizerWidgetData?) -> OrganizerEntry {
        let items: [OrganizerWidgetData.Item]?
        switch kind {
        case .memos:
            items = data?.memos
        case .schedule:
            items = data?.calendarEvents?.filter { item in
                (item.expiry ?? .distantPast) > date
            }
        }
        return OrganizerEntry(date: date, items: items)
    }
}

private struct OrganizerWidgetView: View {
    let kind: OrganizerKind
    let entry: OrganizerEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(kind.name, systemImage: kind.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let items = entry.items, !items.isEmpty {
                ForEach(items.prefix(family == .systemSmall ? 1 : 2)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline).lineLimit(1)
                        if let date = item.date {
                            Text(item.allDay == true
                                 ? date.formatted(.dateTime.month().day()) + " · 全天"
                                 : date.formatted(.dateTime.month().day().hour().minute()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let preview = item.preview, !preview.isEmpty {
                            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .privacySensitive()
                }
            } else {
                Text(entry.items == nil ? "打开乐奇助手同步" : (kind == .memos ? "暂无便签" : "暂无近期日程"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }
}

@MainActor
private func configuration(for kind: OrganizerKind) -> some WidgetConfiguration {
    StaticConfiguration(kind: "leqi.organizer." + kind.rawValue, provider: OrganizerProvider(kind: kind)) { entry in
        OrganizerWidgetView(kind: kind, entry: entry).widgetURL(kind.deepLink)
    }
    .configurationDisplayName(kind.name)
    .description(kind.description)
    .supportedFamilies([.systemSmall, .systemMedium])
}

private struct MemoWidget: Widget {
    var body: some WidgetConfiguration { configuration(for: .memos) }
}

private struct ScheduleWidget: Widget {
    var body: some WidgetConfiguration { configuration(for: .schedule) }
}

@main
struct OrganizerWidgets: WidgetBundle {
    var body: some Widget {
        MemoWidget()
        ScheduleWidget()
    }
}
