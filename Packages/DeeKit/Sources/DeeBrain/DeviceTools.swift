import Contacts
import CoreLocation
import DeeCore
import EventKit
import Foundation
import MapKit

/// Device tools for the cloud voice (calendar, reminders, contacts, location).
/// Each asks for its permission the first time it is used and returns short plain
/// text; a refusal comes back as text the model can say ("you'd need to allow it
/// in Settings"). Results go to OpenAI only when the person asked for them.
public enum DeviceTools {
    /// Every device tool.
    public static func all() -> [any AgentTool] {
        [CalendarEventsTool(), AddCalendarEventTool(), RemindersTool(), AddReminderTool(), FindContactTool(), WhereAmITool()]
    }

    /// Spoken with the result.
    public static let names: Set<String> = ["calendar_events", "add_calendar_event", "reminders", "add_reminder",
                                            "find_contact", "where_am_i"]

    static func parseDate(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    static func spoken(_ d: Date, allDay: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = allDay ? "EEEE d MMMM" : "EEEE d MMMM 'at' h:mm a"
        return f.string(from: d)
    }
}

// MARK: - Calendar

public struct CalendarEventsTool: AgentTool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "calendar_events", description: "List the person's calendar events coming up. Only when they ask about their plans or schedule.", parameters: [
            ToolParameter("days", .integer, "How many days ahead to look (1-14).", required: false),
        ])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { throw ToolError.permissionDenied("the calendar") }
        let days = min(14, max(1, Int(call["days"] ?? "") ?? 2))
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: start)) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(8)
        guard !events.isEmpty else { return "No events in the next \(days) day\(days == 1 ? "" : "s")." }
        return events.map { "- \($0.title ?? "Event"), \(DeviceTools.spoken($0.startDate, allDay: $0.isAllDay))" }
            .joined(separator: "\n")
    }
}

public struct AddCalendarEventTool: AgentTool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "add_calendar_event", description: "Add an event to the person's calendar when they ask.", parameters: [
            ToolParameter("title", .string, "Short title."),
            ToolParameter("start", .string, "Local start, YYYY-MM-DD HH:MM."),
            ToolParameter("minutes", .integer, "Length in minutes (default 60).", required: false),
        ])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let title = try call.require("title")
        guard let start = DeviceTools.parseDate(try call.require("start")) else {
            throw ToolError.invalidArgument("start", "use YYYY-MM-DD HH:MM")
        }
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { throw ToolError.permissionDenied("the calendar") }
        guard let calendar = store.defaultCalendarForNewEvents else { throw ToolError.unavailable("no calendar to add to") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(max(5, Int(call["minutes"] ?? "") ?? 60)) * 60)
        event.calendar = calendar
        do { try store.save(event, span: .thisEvent) } catch { throw ToolError.failed("Couldn't save the event.") }
        return "Added \(title) on \(DeviceTools.spoken(start))."
    }
}

// MARK: - Reminders

public struct RemindersTool: AgentTool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "reminders", description: "List the person's open reminders. Only when they ask about their to-dos.", parameters: [])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else { throw ToolError.permissionDenied("reminders") }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let titles: [String] = await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { reminders in
                c.resume(returning: (reminders ?? []).prefix(10).map { r in
                    let due = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return "- \(r.title ?? "Reminder")" + (due.map { ", due \(DeviceTools.spoken($0))" } ?? "")
                })
            }
        }
        return titles.isEmpty ? "No open reminders." : titles.joined(separator: "\n")
    }
}

public struct AddReminderTool: AgentTool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "add_reminder", description: "Add a reminder when the person asks.", parameters: [
            ToolParameter("title", .string, "What to remind them of."),
            ToolParameter("due", .string, "Optional local due time, YYYY-MM-DD HH:MM.", required: false),
        ])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let title = try call.require("title")
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else { throw ToolError.permissionDenied("reminders") }
        guard let list = store.defaultCalendarForNewReminders() else { throw ToolError.unavailable("no reminders list") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        var said = "Added a reminder: \(title)."
        if let due = DeviceTools.parseDate(call["due"]) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
            said = "Added a reminder: \(title), \(DeviceTools.spoken(due))."
        }
        do { try store.save(reminder, commit: true) } catch { throw ToolError.failed("Couldn't save the reminder.") }
        return said
    }
}

// MARK: - Contacts

public struct FindContactTool: AgentTool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "find_contact", description: "Look up a contact's phone, email or birthday by name.", parameters: [
            ToolParameter("name", .string, "The contact's name."),
        ])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let name = try call.require("name")
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { throw ToolError.permissionDenied("contacts") }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey,
                                       CNContactEmailAddressesKey, CNContactBirthdayKey].map { $0 as CNKeyDescriptor }
        let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        guard !found.isEmpty else { return "No contact called \(name)." }
        return found.prefix(3).map { c in
            var parts = ["\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)]
            if let p = c.phoneNumbers.first?.value.stringValue { parts.append("phone \(p)") }
            if let e = c.emailAddresses.first?.value as String? { parts.append("email \(e)") }
            if let b = c.birthday, let m = b.month, let d = b.day {
                parts.append("birthday \(DateFormatter().monthSymbols[m - 1]) \(d)")
            }
            return "- " + parts.joined(separator: ", ")
        }.joined(separator: "\n")
    }
}

// MARK: - Location

public struct WhereAmITool: AgentTool {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(name: "where_am_i", description: "Find roughly where the person is (town and area) when they ask.", parameters: [])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let location = try await OneShotLocation.fetch()
        let place = await OneShotLocation.describe(location)
        // Only a place name ever leaves the device (the permission text says so):
        // no coordinates, even when no town is found.
        return place ?? "Somewhere I can't name right now."
    }
}

/// One location fix (when-in-use permission), then stops.
@MainActor
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private static var active: Set<OneShotLocation> = []

    static func fetch() async throws -> CLLocation {
        let one = OneShotLocation()
        active.insert(one)
        defer { active.remove(one) }
        return try await withCheckedThrowingContinuation { c in
            one.continuation = c
            one.start()
        }
    }

    private func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.failure(ToolError.permissionDenied("location")))
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ r: Result<CLLocation, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: r)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .notDetermined: break
            case .denied, .restricted: self.finish(.failure(ToolError.permissionDenied("location")))
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in self.finish(.success(l)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(ToolError.unavailable("no location fix right now"))) }
    }

    /// "Near <town, region>" from MapKit's reverse geocoder, or nil.
    static func describe(_ l: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: l),
              let item = try? await request.mapItems.first,
              let city = item.addressRepresentations?.cityWithContext, !city.isEmpty else { return nil }
        return "Near \(city)."
    }
}
