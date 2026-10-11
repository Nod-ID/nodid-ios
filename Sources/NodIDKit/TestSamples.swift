// Nod ID SDK, test mode (quickstart, decision 55): the three sample passports and the rules applied to them.
// NO passport data exists here: a sample is a letter plus two dates computed from the clock (so tests do not rot).
// No names, no document numbers, no images, no MRZ. Compiled in Debug builds only.
#if DEBUG
import Foundation

enum TestSample: String, CaseIterable, Identifiable {
    case a, b, c
    var id: String { rawValue }
    var letter: String { rawValue.uppercased() }
    var title: String {
        switch self { case .a: return "Sample A"; case .b: return "Sample B"; case .c: return "Sample C" }
    }
    var detail: String {
        switch self {
        case .a: return "Adult, passport valid"
        case .b: return "Under 18"
        case .c: return "Passport expired"
        }
    }

    /// Date of birth and expiry relative to `now`: A is 30 and expires in 5 years, B is 16, C expired yesterday.
    func dates(now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> (birth: Date, expiry: Date) {
        func add(_ c: Calendar.Component, _ n: Int) -> Date { calendar.date(byAdding: c, value: n, to: now) ?? now }
        switch self {
        case .a: return (add(.year, -30), add(.year, 5))
        case .b: return (add(.year, -16), add(.year, 5))
        case .c: return (add(.year, -30), add(.day, -1))
        }
    }
}

enum TestDecision: Equatable {
    case verified
    case notVerified(NotVerifiedReason)
}

enum TestRules {
    /// The same age and expiry arithmetic the live rules use (whole years since birth; expired when expiry is before today).
    static func decide(_ s: TestSample, now: Date, minAge: Int, checkAge: Bool, checkExpiry: Bool,
                       calendar: Calendar = Calendar(identifier: .gregorian)) -> TestDecision {
        let d = s.dates(now: now, calendar: calendar)
        if checkExpiry, calendar.startOfDay(for: d.expiry) < calendar.startOfDay(for: now) { return .notVerified(.expired) }
        if checkAge, minAge > 0 {
            let age = calendar.dateComponents([.year], from: d.birth, to: now).year ?? 0
            if age < minAge { return .notVerified(.underage) }
        }
        return .verified
    }
}
#endif
