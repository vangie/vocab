import Foundation

/// The study day rolls over at 02:00 local time: activity before 2 am counts toward the previous day
/// (rings, streak, daily goals, 今天的任务完成了).
public enum StudyDay {
    public static let rolloverHours = 2
    /// A moment shifted so that calendar-day functions give the study day.
    public static func shifted(_ d: Date) -> Date { d.addingTimeInterval(-Double(rolloverHours) * 3600) }
    /// Midnight of the calendar date naming the study day `d` belongs to.
    public static func day(_ d: Date, _ cal: Calendar = .current) -> Date { cal.startOfDay(for: shifted(d)) }
    /// "yyyy-MM-dd" of the study day.
    public static func key(_ d: Date, _ cal: Calendar = .current) -> String { DailyLog.key(day(d, cal), cal) }
    public static func same(_ a: Date, _ b: Date, _ cal: Calendar = .current) -> Bool { day(a, cal) == day(b, cal) }
}
