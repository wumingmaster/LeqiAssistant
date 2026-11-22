import Combine
import EventKit
import EventKitUI
import SwiftUI
import WidgetKit

@MainActor
final class SystemCalendar: ObservableObject {
    @Published private(set) var access = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var message: String?
    @Published private(set) var requestingAccess = false

    let store = EKEventStore()
    private var visibleMonth = Date.now
    private var changes: AnyCancellable?

    init() {
        changes = NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    var canEdit: Bool { access == .fullAccess && store.defaultCalendarForNewEvents != nil }

    func requestAccess() async {
        guard !requestingAccess else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        do {
            _ = try await store.requestFullAccessToEvents()
            message = nil
            refresh()
        } catch {
            message = "未能获取日历权限。请在 iPhone 设置中检查日历访问权限。"
            refresh()
        }
    }

    func showMonth(_ month: Date) {
        visibleMonth = month
        refresh()
    }

    func refresh() {
        access = EKEventStore.authorizationStatus(for: .event)
        let calendar = Calendar.autoupdatingCurrent
        if access == .fullAccess, let month = calendar.dateInterval(of: .month, for: visibleMonth) {
            events = events(from: month.start, to: month.end)
        } else {
            events = []
        }

        let old = OrganizerWidgetData.read()
        guard access == .fullAccess || old?.systemEvents != nil else { return }

        var agenda: [OrganizerWidgetData.Item]?
        if access == .fullAccess,
           let end = calendar.date(byAdding: .month, value: 2, to: .now) {
            let now = Date.now
            agenda = events(from: now, to: end).prefix(100).enumerated().map { position, event in
                OrganizerWidgetData.Item(
                    id: "calendar-\(event.eventIdentifier ?? String(position))-\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "未命名日程",
                    preview: nil,
                    date: event.startDate,
                    endsAt: event.endDate,
                    allDay: event.isAllDay
                )
            }
        }
        do {
            let data = OrganizerWidgetData(memos: old?.memos, events: old?.events, systemEvents: agenda)
            if try data.write() { WidgetCenter.shared.reloadTimelines(ofKind: "leqi.organizer.schedule") }
            if message == "暂时无法更新日程小组件。" { message = nil }
        } catch {
            if access == .fullAccess { message = "暂时无法更新日程小组件。" }
        }
    }

    private func events(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.compareStartDate(with: $1) == .orderedAscending }
    }
}

struct SystemCalendarView: View {
    @ObservedObject var calendar: SystemCalendar
    @Environment(\.openURL) private var openURL
    @State private var month = Date.now
    @State private var editor: EditorSelection?

    var body: some View {
        List {
            if calendar.access == .fullAccess {
                Section {
                    DatePicker("查看月份", selection: $month, displayedComponents: .date)
                        .datePickerStyle(.compact)
                    if calendar.events.isEmpty {
                        Text("本月暂无日程").foregroundStyle(.secondary)
                    }
                    ForEach(Array(calendar.events.enumerated()), id: \.offset) { _, event in
                        Button {
                            editor = EditorSelection(event: event)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title ?? "未命名日程").foregroundStyle(.primary)
                                Text(when(event)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!event.calendar.allowsContentModifications)
                    }
                } footer: {
                    Text("这里修改的是 iPhone 系统日历。要在眼镜查看，请在 Rokid AI App 开启手机日历同步。")
                }
            } else {
                Section {
                    if calendar.access == .notDetermined || calendar.access == .writeOnly {
                        Button("允许读写日历") { Task { await calendar.requestAccess() } }
                            .disabled(calendar.requestingAccess)
                    } else if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button("前往设置") { openURL(settings) }
                    }
                } footer: {
                    Text("开启「完全访问」后，可浏览、新增、编辑和删除 iPhone 系统日程。")
                }
            }

            if let message = calendar.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("iPhone 系统日历")
        .toolbar {
            if calendar.canEdit {
                Button("新增日程", systemImage: "plus") { editor = EditorSelection(event: nil) }
            }
        }
        .onAppear { calendar.showMonth(month) }
        .onChange(of: month) { _, newMonth in calendar.showMonth(newMonth) }
        .sheet(item: $editor) { selection in
            CalendarEditor(store: calendar.store, event: selection.event, day: month) {
                editor = nil
                calendar.refresh()
            }
        }
    }

    private func when(_ event: EKEvent) -> String {
        if event.isAllDay {
            return event.startDate.formatted(date: .abbreviated, time: .omitted) + " · 全天"
        }
        return event.startDate.formatted(date: .abbreviated, time: .shortened)
    }

    private struct EditorSelection: Identifiable {
        let id = UUID()
        let event: EKEvent?
    }
}

private struct CalendarEditor: UIViewControllerRepresentable {
    let store: EKEventStore
    let event: EKEvent?
    let day: Date
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        editor.eventStore = store
        editor.editViewDelegate = context.coordinator
        if let event {
            editor.event = event
        } else {
            let event = EKEvent(eventStore: store)
            event.calendar = store.defaultCalendarForNewEvents
            let calendar = Calendar.autoupdatingCurrent
            let hour = calendar.component(.hour, from: .now)
            event.startDate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
            event.endDate = event.startDate.addingTimeInterval(3_600)
            editor.event = event
        }
        return editor
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish()
        }
    }
}
