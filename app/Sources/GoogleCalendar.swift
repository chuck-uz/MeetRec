// Чтение событий Google Calendar (все выбранные календари аккаунта).
import Foundation

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
    let meetLink: String?

    var isNow: Bool {
        let now = Date()
        return start.addingTimeInterval(-300) <= now && now <= end
    }
}

final class GoogleCalendarClient {
    static let shared = GoogleCalendarClient()
    private let iso = ISO8601DateFormatter()

    /// События на ближайшие `hours` часов по всем выбранным календарям.
    func upcomingEvents(hours: Double = 12) async throws -> [CalendarEvent] {
        let token = try await GoogleAuth.shared.validAccessToken()
        var events: [CalendarEvent] = []
        for calendarID in try await selectedCalendarIDs(token: token) {
            events += try await fetchEvents(calendarID: calendarID, token: token, hours: hours)
        }
        var seen = Set<String>()
        return events
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.start < $1.start }
    }

    // MARK: - API

    private func selectedCalendarIDs(token: String) async throws -> [String] {
        struct CalendarList: Decodable {
            struct Item: Decodable {
                let id: String
                let selected: Bool?
                let primary: Bool?
            }
            let items: [Item]?
        }
        let data = try await get(
            "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader",
            token: token)
        let list = try JSONDecoder().decode(CalendarList.self, from: data)
        let items = list.items ?? []
        let chosen = items.filter { $0.selected == true || $0.primary == true }
        return (chosen.isEmpty ? items : chosen).map(\.id)
    }

    private func fetchEvents(calendarID: String, token: String, hours: Double) async throws -> [CalendarEvent] {
        struct EventList: Decodable {
            struct Item: Decodable {
                struct When: Decodable {
                    let dateTime: String?
                    let date: String?
                }
                struct Attendee: Decodable {
                    let email: String?
                    let displayName: String?
                    let responseStatus: String?
                    let selfKey: Bool?
                    enum CodingKeys: String, CodingKey {
                        case email, displayName, responseStatus
                        case selfKey = "self"
                    }
                }
                let id: String
                let summary: String?
                let start: When?
                let end: When?
                let attendees: [Attendee]?
                let hangoutLink: String?
                let status: String?
            }
            let items: [Item]?
        }

        let timeMin = iso.string(from: Date().addingTimeInterval(-600))
        let timeMax = iso.string(from: Date().addingTimeInterval(hours * 3600))
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(percentEncode(calendarID))/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: timeMin),
            .init(name: "timeMax", value: timeMax),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "15"),
        ]
        let data = try await get(comps.url!.absoluteString, token: token)
        let list = try JSONDecoder().decode(EventList.self, from: data)

        return (list.items ?? []).compactMap { item in
            guard item.status != "cancelled",
                  let startString = item.start?.dateTime, // события без dateTime — на весь день, пропускаем
                  let endString = item.end?.dateTime,
                  let start = parseDate(startString),
                  let end = parseDate(endString) else { return nil }
            // Не показываем встречи, от которых пользователь отказался.
            if let attendees = item.attendees,
               attendees.first(where: { $0.selfKey == true })?.responseStatus == "declined" {
                return nil
            }
            return CalendarEvent(
                id: item.id,
                title: item.summary?.trimmingCharacters(in: .whitespaces) ?? "Без названия",
                start: start,
                end: end,
                attendees: (item.attendees ?? []).compactMap { $0.displayName ?? $0.email },
                meetLink: item.hangoutLink)
        }
    }

    private func get(_ urlString: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MeetRecError("Google Calendar API: \(body.prefix(200))")
        }
        return data
    }

    private func parseDate(_ string: String) -> Date? {
        iso.date(from: string)
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
