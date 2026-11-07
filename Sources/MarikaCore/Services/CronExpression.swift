import Foundation

/// Five-field cron: minute, hour, day of month, month, day of week.
/// Lists, ranges, steps, names and calendar aliases follow https://man.openbsd.org/crontab.5.
public struct CronExpression: Sendable {
    private struct Field: Sendable {
        let values: Set<Int>
        let wildcard: Bool
    }
    private let fields: [Field]

    public enum ValidationError: LocalizedError {
        case invalid(String), noOccurrence
        public var errorDescription: String? {
            switch self {
            case .invalid(let reason): reason
            case .noOccurrence: "This schedule has no matching date in the next eight years."
            }
        }
    }

    public init(_ expression: String) throws {
        let aliases = ["@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
                       "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"]
        let input = expression.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = (aliases[input] ?? input).split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else { throw ValidationError.invalid("Use five cron fields: minute hour day month weekday.") }
        let ranges = [0...59, 0...23, 1...31, 1...12, 0...7]
        let labels = ["minute", "hour", "day", "month", "weekday"]
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        fields = try parts.enumerated().map { index, part in
            var values = Set<Int>()
            let names = index == 3 ? months : (index == 4 ? days : [])
            func number(_ token: Substring) -> Int? {
                if let value = Int(token) { return value }
                return names.firstIndex(of: String(token)).map { $0 + (index == 3 ? 1 : 0) }
            }
            for item in part.split(separator: ",", omittingEmptySubsequences: false) {
                let stepped = item.split(separator: "/", omittingEmptySubsequences: false)
                guard (1...2).contains(stepped.count) else { throw ValidationError.invalid("Invalid \(labels[index]) field.") }
                let step = stepped.count == 2 ? Int(stepped[1]) ?? 0 : 1
                guard step > 0, step <= ranges[index].upperBound + 1 else { throw ValidationError.invalid("Invalid step in \(labels[index]) field.") }
                let bounds: ClosedRange<Int>
                if stepped[0] == "*" { bounds = ranges[index] }
                else {
                    let pair = stepped[0].split(separator: "-", omittingEmptySubsequences: false)
                    guard (1...2).contains(pair.count), let first = number(pair[0]),
                          let last = pair.count == 2 ? number(pair[1]) : (stepped.count == 2 ? ranges[index].upperBound : first),
                          ranges[index].contains(first), ranges[index].contains(last), first <= last
                    else { throw ValidationError.invalid("Invalid \(labels[index]) field: \(part).") }
                    bounds = first...last
                }
                values.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
            }
            if index == 4, values.remove(7) != nil { values.insert(0) }
            return Field(values: values, wildcard: part.hasPrefix("*"))
        }
    }

    /// Missing local times are skipped; repeated local times run once, at their first occurrence.
    public func next(after date: Date, timeZone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var day = calendar.startOfDay(for: date)
        let hours = fields[1].values.sorted(), minutes = fields[0].values.sorted()
        for _ in 0..<(366 * 8) {
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            let dom = fields[2].values.contains(components.day!), dow = fields[4].values.contains(components.weekday! - 1)
            let matchesDay = fields[2].wildcard || fields[4].wildcard ? dom && dow : dom || dow
            if fields[3].values.contains(components.month!), matchesDay {
                for hour in hours {
                    for minute in minutes {
                        var matching = components
                        matching.weekday = nil; matching.hour = hour; matching.minute = minute; matching.second = 0
                        if let next = calendar.nextDate(after: day.addingTimeInterval(-1), matching: matching,
                            matchingPolicy: .strict, repeatedTimePolicy: .first),
                           calendar.isDate(next, inSameDayAs: day), next > date { return next }
                    }
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        throw ValidationError.noOccurrence
    }
}
