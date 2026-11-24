import XCTest
@testable import Ledger

/// M6 周报聚合（§14 新增字节口径 + 周一到周日映射 + 未知项 + moved 不计）。
final class WeeklyAggregatorTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    /// 2026-11-23 是周一（本测试环境日期），用它构造各天。
    private func ts(weekday: Int) -> Double {
        // weekday 1=周日…7=周六；2026-11-23 为周一
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23))!
        let offset = (weekday + 5) % 7  // weekday=2(周一) → 0
        return calendar.date(byAdding: .day, value: offset, to: monday)!.timeIntervalSince1970
    }

    func testWeekdayMapping() {
        XCTAssertEqual(WeeklyAggregator.dayIndex(for: Date(timeIntervalSince1970: ts(weekday: 2)), calendar: calendar), 0)  // 周一
        XCTAssertEqual(WeeklyAggregator.dayIndex(for: Date(timeIntervalSince1970: ts(weekday: 1)), calendar: calendar), 6)  // 周日
        XCTAssertEqual(WeeklyAggregator.dayIndex(for: Date(timeIntervalSince1970: ts(weekday: 7)), calendar: calendar), 5)  // 周六
    }

    func testNewBytesFormula() {
        let changes: [(ts: Double, path: String, appBundleID: String?, kind: String, sizeDelta: Int64)] = [
            (ts: ts(weekday: 2), path: "/x/a", appBundleID: "com.a", kind: "created", sizeDelta: 10),
            (ts: ts(weekday: 2), path: "/x/b", appBundleID: "com.a", kind: "modified", sizeDelta: 5),
            (ts: ts(weekday: 2), path: "/x/c", appBundleID: "com.a", kind: "modified", sizeDelta: -5),  // 负 delta 不计
            (ts: ts(weekday: 2), path: "/x/d", appBundleID: "com.a", kind: "removed", sizeDelta: -7),
            (ts: ts(weekday: 2), path: "/x/e", appBundleID: "com.a", kind: "moved", sizeDelta: 0),
        ]
        let report = WeeklyAggregator.aggregate(changes: changes, newInstallCount: 1, calendar: calendar)
        XCTAssertEqual(report.totalNewBytes, 15)   // 10 + 5 + 0
        XCTAssertEqual(report.removedBytes, 7)     // 副指标
        XCTAssertEqual(report.newInstallCount, 1)
        XCTAssertEqual(report.unknownCount, 0)
    }

    func testUnknownAndCategory() {
        let changes: [(ts: Double, path: String, appBundleID: String?, kind: String, sizeDelta: Int64)] = [
            (ts: ts(weekday: 3), path: "/x/u1", appBundleID: nil, kind: "created", sizeDelta: 20),
            (ts: ts(weekday: 3), path: "/Users/x/Library/Caches/app/y", appBundleID: "com.a", kind: "created", sizeDelta: 30),
        ]
        let report = WeeklyAggregator.aggregate(changes: changes, newInstallCount: 0, calendar: calendar)
        XCTAssertEqual(report.unknownCount, 1)
        XCTAssertEqual(report.dayBytes[1]?["未知"], 20)
        XCTAssertEqual(report.dayBytes[1]?["com.a"], 30)
        XCTAssertEqual(report.dayCategoryBytes[1]?["unknown"], 20)
        XCTAssertEqual(report.dayCategoryBytes[1]?["cache"], 30)
    }

    func testTopAppsOrder() {
        let changes: [(ts: Double, path: String, appBundleID: String?, kind: String, sizeDelta: Int64)] = [
            (ts: ts(weekday: 2), path: "/x/a", appBundleID: "com.small", kind: "created", sizeDelta: 5),
            (ts: ts(weekday: 2), path: "/x/b", appBundleID: "com.big", kind: "created", sizeDelta: 100),
            (ts: ts(weekday: 4), path: "/x/c", appBundleID: "com.big", kind: "created", sizeDelta: 50),
        ]
        let report = WeeklyAggregator.aggregate(changes: changes, newInstallCount: 0, calendar: calendar)
        XCTAssertEqual(report.topApps.map(\.bundleID), ["com.big", "com.small"])
        XCTAssertEqual(report.topApps.first?.bytes, 150)
    }
}
