import Foundation
import Testing
@testable import MarikaCore

struct CronExpressionTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func stepsRangesAndListsFindTheNextMinute() throws {
        let cron = try CronExpression("*/15 8-17 * * MON-FRI")
        #expect(try cron.next(after: date("2026-11-06T08:14:10Z"), timeZone: utc) == date("2026-11-06T08:15:00Z"))
        #expect(try cron.next(after: date("2026-11-06T17:45:00Z"), timeZone: utc) == date("2026-11-09T08:00:00Z"))
        #expect(try CronExpression("5,20,40 * * * *").next(after: date("2026-11-06T23:40:00Z"), timeZone: utc) == date("2026-11-07T00:05:00Z"))
        #expect(try CronExpression("@monthly").next(after: date("2026-11-06T08:00:00Z"), timeZone: utc) == date("2026-12-01T00:00:00Z"))
    }

    @Test func dayFieldsUseCronOrSemanticsAndSundayAliases() throws {
        let cron = try CronExpression("0 9 1 * MON")
        #expect(try cron.next(after: date("2026-11-02T10:00:00Z"), timeZone: utc) == date("2026-11-09T09:00:00Z"))
        let sunday = try CronExpression("0 9 * * 7")
        #expect(try sunday.next(after: date("2026-11-06T10:00:00Z"), timeZone: utc) == date("2026-11-08T09:00:00Z"))
        #expect(try CronExpression("0 9 29 FEB *").next(after: date("2026-11-06T10:00:00Z"), timeZone: utc) == date("2028-02-29T09:00:00Z"))
    }

    @Test func timeZonesAndDaylightSavingAreExplicit() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        #expect(try CronExpression("0 9 * * *").next(after: date("2026-11-06T08:00:00Z"), timeZone: newYork) == date("2026-11-06T14:00:00Z"))
        #expect(try CronExpression("30 2 * * *").next(after: date("2026-03-08T05:00:00Z"), timeZone: newYork) == date("2026-03-09T06:30:00Z"))
        let repeatHour = try CronExpression("30 1 * * *")
        #expect(try repeatHour.next(after: date("2026-11-01T04:00:00Z"), timeZone: newYork) == date("2026-11-01T05:30:00Z"))
        #expect(try repeatHour.next(after: date("2026-11-01T05:31:00Z"), timeZone: newYork) == date("2026-11-02T06:30:00Z"))
    }

    @Test func invalidOrImpossibleExpressionsAreRejected() throws {
        for invalid in ["", "* * *", "60 * * * *", "0 24 * * *", "*/0 * * * *", "0 9 * * FUNDAY", "1,,2 * * * *", "0 9 * * 5-1", "@reboot", "* * * * * rm -rf /tmp"] {
            #expect(throws: CronExpression.ValidationError.self) { try CronExpression(invalid) }
        }
        let impossible = try CronExpression("0 9 31 FEB *")
        #expect(throws: CronExpression.ValidationError.self) { try impossible.next(after: date("2026-11-06T08:00:00Z"), timeZone: utc) }
    }

    @Test func oldHourlyJobsDecodeAndCronConfigurationPersists() throws {
        var job = ProjectSchedule(name: "Review", prompt: "Review code", agent: .codex, hours: 3)
        let data = try JSONEncoder().encode(job)
        let old = try JSONDecoder().decode(ProjectSchedule.self, from: data)
        #expect(old.cron == nil)
        #expect(try old.nextOccurrence(after: date("2026-11-06T08:00:00Z")) == date("2026-11-06T11:00:00Z"))
        job.cron = "0 9 * * 1-5"; job.timeZoneID = "Europe/London"
        let restored = try JSONDecoder().decode(ProjectSchedule.self, from: JSONEncoder().encode(job))
        #expect(restored.cron == job.cron)
        #expect(try restored.nextOccurrence(after: date("2026-11-06T10:00:00Z")) == date("2026-11-09T09:00:00Z"))
        job.timeZoneID = "Invalid/Zone"
        #expect(throws: CronExpression.ValidationError.self) { try job.nextOccurrence(after: Date()) }
    }
}
