import Foundation

struct WorkoutSession: Codable, Identifiable {
    var id: String
    var date: Date
    var label: String
    var entries: [WorkoutEntry]

    init(id: String = UUID().uuidString, date: Date = .now, label: String = "WORKOUT", entries: [WorkoutEntry]) {
        self.id = id; self.date = date; self.label = label; self.entries = entries
    }
}

extension WorkoutSession {
    struct DateParts {
        let month: String    // "MAY"
        let day: String      // "02"
        let weekday: String  // "FRI"
        let short: String    // "05.02"
    }

    var dateParts: DateParts {
        let cal = Calendar.current
        let c = cal.dateComponents([.month, .day, .weekday], from: date)
        let months   = ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"]
        let weekdays = ["SUN","MON","TUE","WED","THU","FRI","SAT"]
        let m = c.month ?? 1; let d = c.day ?? 1; let wd = c.weekday ?? 1
        return DateParts(
            month: months[m - 1],
            day: String(format: "%02d", d),
            weekday: weekdays[wd - 1],
            short: String(format: "%02d.%02d", m, d)
        )
    }

    var topLift: String? { entries.first(where: { $0.weightLbs != nil || $0.weightKg != nil })?.exercise }
}

@Observable
final class SessionStore {
    var sessions: [WorkoutSession] = []

    init() { load() }

    func add(_ session: WorkoutSession) {
        sessions.insert(session, at: 0)
        persist()
    }

    func update(id: String, entries: [WorkoutEntry]) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].entries = entries
        persist()
    }

    /// Sessions with a training day in the given year/month, keyed by day-of-month.
    func sessionsByDay(year: Int, month: Int) -> [Int: WorkoutSession] {
        let cal = Calendar.current
        var result: [Int: WorkoutSession] = [:]
        for s in sessions {
            let c = cal.dateComponents([.year, .month, .day], from: s.date)
            if c.year == year && c.month == month, let day = c.day {
                result[day] = s
            }
        }
        return result
    }

    private let key = "strg.sessions.v1"

    private func persist() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([WorkoutSession].self, from: data) else { return }
        sessions = stored
    }
}
