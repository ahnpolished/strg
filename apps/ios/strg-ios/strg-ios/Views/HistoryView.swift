import SwiftUI

struct HistoryView: View {
    @Binding var showsTabBar: Bool
    @Environment(SessionStore.self) private var store

    @State private var viewYear: Int = Calendar.current.component(.year, from: .now)
    @State private var viewMonth: Int = Calendar.current.component(.month, from: .now)
    @State private var selectedSession: WorkoutSession?

    var body: some View {
        if let session = selectedSession {
            SessionDetailView(
                session: session,
                onBack: {
                    selectedSession = nil
                    showsTabBar = true
                },
                onEdit: { updated in
                    store.update(id: session.id, entries: updated)
                    // Refresh the binding
                    if let i = store.sessions.firstIndex(where: { $0.id == session.id }) {
                        selectedSession = store.sessions[i]
                    }
                }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            calendarBody
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    // MARK: - Calendar body

    private var calendarBody: some View {
        let byDay = store.sessionsByDay(year: viewYear, month: viewMonth)
        let monthSessions = store.sessions
            .filter {
                let c = Calendar.current.dateComponents([.year, .month], from: $0.date)
                return c.year == viewYear && c.month == viewMonth
            }
            .sorted { $0.date > $1.date }

        return ZStack {
            StrgBackground()
            VStack(spacing: 0) {
                // Header
                StrgHeader(trailing: AnyView(
                    Text("HISTORY")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(2.5)
                ))
                .padding(.top, 56)

                // Month nav
                HStack {
                    Button { stepMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Text("\(monthName(viewMonth)) \(viewYear)")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                        .tracking(2)
                    Spacer()

                    Button { stepMonth(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)

                // Calendar grid
                calendarGrid(byDay: byDay)
                    .padding(.horizontal, 18)

                // Session list
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        HStack {
                            Text(monthSessions.isEmpty
                                 ? "NO SESSIONS"
                                 : "\(monthSessions.count) \(monthSessions.count == 1 ? "SESSION" : "SESSIONS")")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.38))
                                .tracking(2.5)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 12)

                        if monthSessions.isEmpty {
                            Text("No workouts logged this month")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.25))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(monthSessions) { session in
                                    SessionRow(session: session) {
                                        withAnimation(.easeInOut(duration: 0.28)) {
                                            selectedSession = session
                                            showsTabBar = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 100)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Calendar grid

    private func calendarGrid(byDay: [Int: WorkoutSession]) -> some View {
        let cal = Calendar.current
        let firstWeekday = cal.component(.weekday, from: Date(year: viewYear, month: viewMonth, day: 1))
        // Design uses Mon-first: Sun=0→6, Mon=1→0, Tue=2→1, ...
        let leadingBlanks = (firstWeekday + 5) % 7
        let daysInMonth = cal.range(of: .day, in: .month, for: Date(year: viewYear, month: viewMonth, day: 1))?.count ?? 30

        return VStack(spacing: 0) {
            // Weekday header
            HStack(spacing: 0) {
                ForEach(["M","T","W","T","F","S","S"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.22))
                        .tracking(1)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 6)

            // Day grid
            let totalCells = leadingBlanks + daysInMonth
            let rows = (totalCells + 6) / 7

            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let cellIdx = row * 7 + col
                        let day = cellIdx - leadingBlanks + 1
                        if day >= 1 && day <= daysInMonth {
                            CalendarDayCell(day: day, session: byDay[day]) { s in
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    selectedSession = s
                                    showsTabBar = false
                                }
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func stepMonth(_ dir: Int) {
        var m = viewMonth + dir
        var y = viewYear
        if m < 1 { m = 12; y -= 1 }
        if m > 12 { m = 1;  y += 1 }
        viewMonth = m; viewYear = y
    }

    private func monthName(_ m: Int) -> String {
        ["JANUARY","FEBRUARY","MARCH","APRIL","MAY","JUNE",
         "JULY","AUGUST","SEPTEMBER","OCTOBER","NOVEMBER","DECEMBER"][m - 1]
    }
}

// MARK: - Calendar day cell

private struct CalendarDayCell: View {
    let day: Int
    let session: WorkoutSession?
    let onTap: (WorkoutSession) -> Void

    var body: some View {
        Button {
            if let s = session { onTap(s) }
        } label: {
            VStack(spacing: 4) {
                Text("\(day)")
                    .font(.system(size: 14, weight: session != nil ? .heavy : .regular, design: .rounded))
                    .foregroundStyle(session != nil ? .white : .white.opacity(0.32))
                    .frame(width: 30, height: 30)
                    .background(
                        session != nil
                        ? Color.white.opacity(0.05)
                        : .clear
                    )
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(
                            session != nil ? Color.white.opacity(0.12) : .clear,
                            lineWidth: 0.5
                        )
                    )
                Circle()
                    .fill(session != nil ? Color.strgAccent : .clear)
                    .frame(width: 5, height: 5)
                    .shadow(color: session != nil ? Color.strgAccent : .clear, radius: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .disabled(session == nil)
    }
}

// MARK: - Session list row

private struct SessionRow: View {
    let session: WorkoutSession
    let onTap: () -> Void

    var body: some View {
        let f = session.dateParts
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Date column
                VStack(spacing: 2) {
                    Text(f.day)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(f.weekday)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                        .tracking(1)
                }
                .frame(minWidth: 42)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 0.5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.label)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .tracking(0.5)
                    Text("\(session.entries.count) exercises · \(session.topLift.map { "top \($0.lowercased())" } ?? "—")")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
                Circle()
                    .fill(Color.strgAccent)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassCard(radius: 20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Date init helper

private extension Date {
    init(year: Int, month: Int, day: Int) {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        self = Calendar.current.date(from: c) ?? .now
    }
}

