// Nod ID SDK: pure parsing and ICAO 9303 check-digit validation for the two lines of a TD3 passport (2 x 44 characters).
// Nothing here prints, logs or stores anything. Inputs are local strings that go out of scope when the call returns.
import Foundation

enum MRZParser {
    /// ICAO 9303 check digit: weights 7,3,1 repeating; digits are their value, A-Z are 10-35, '<' is 0.
    static func checkDigit(_ s: String) -> Int? {
        let w = [7, 3, 1]
        var sum = 0
        for (i, u) in s.unicodeScalars.enumerated() {
            let v: Int
            switch u.value {
            case 48...57: v = Int(u.value) - 48
            case 65...90: v = Int(u.value) - 55
            case 60: v = 0
            default: return nil
            }
            sum += v * w[i % 3]
        }
        return sum % 10
    }

    /// Uppercase, drop spaces, map look-alike chevrons to '<', keep only A-Z 0-9 '<'.
    static func normalize(_ raw: String) -> String {
        var out = ""
        for ch in raw.uppercased() {
            switch ch {
            case "«", "‹", "〈", "<": out.append("<")
            case "A"..."Z", "0"..."9": out.append(ch)
            default: continue
            }
        }
        return out
    }

    private static let digitFix: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "G": "6", "B": "8"]
    private static func asDigits<S: Sequence>(_ s: S) -> String? where S.Element == Character {
        var out = ""
        for ch in s {
            if ch.isASCII, ch.isNumber { out.append(ch) } else if let f = digitFix[ch] { out.append(f) } else { return nil }
        }
        return out
    }

    private static func validDate(_ yymmdd: String) -> Bool {
        guard yymmdd.count == 6, let m = Int(yymmdd.dropFirst(2).prefix(2)), let d = Int(yymmdd.suffix(2)) else { return false }
        return (1...12).contains(m) && (1...31).contains(d)
    }

    /// Both lines already normalized to 44 characters. Returns nil unless every check digit matches.
    static func parse(line1: String, line2: String) -> MRZData? {
        guard line1.count == 44, line2.count == 44 else { return nil }
        let a = Array(line1), b = Array(line2)
        guard a[0] == "P" else { return nil }
        // Issuing state: line 1, characters 3 to 5 (index 2 to 4). Letters, '<' padding allowed (e.g. "D<<").
        let state = String(a[2...4])
        guard state.allSatisfy({ $0 == "<" || ($0.isASCII && $0.isLetter) }) else { return nil }
        let docField = String(b[0..<9])
        guard let docCheck = asDigits(b[9...9]), let docCD = Int(docCheck), checkDigit(docField) == docCD else { return nil }
        guard let birth = asDigits(b[13..<19]), let birthCD = asDigits(b[19...19]).flatMap({ Int($0) }),
              checkDigit(birth) == birthCD, validDate(birth) else { return nil }
        guard let expiry = asDigits(b[21..<27]), let expCD = asDigits(b[27...27]).flatMap({ Int($0) }),
              checkDigit(expiry) == expCD, validDate(expiry) else { return nil }
        let doc = docField.replacingOccurrences(of: "<", with: "")
        guard (6...9).contains(doc.count) else { return nil }
        let issuing = state.replacingOccurrences(of: "<", with: "")
        return MRZData(documentNumber: doc, birthYYMMDD: birth, expiryYYMMDD: expiry, issuingState: issuing.isEmpty ? nil : issuing)
    }

    /// Finds a valid line pair in the recognized strings of one frame (top to bottom). Strings are not kept.
    static func find(in lines: [String]) -> MRZData? {
        let n = lines.map(normalize).filter { $0.count == 44 }
        guard n.count >= 2 else { return nil }
        for i in 0..<(n.count - 1) { if let r = parse(line1: n[i], line2: n[i + 1]) { return r } }
        return nil
    }
}

// MARK: access key for the chip (ICAO 9303 part 11)
func icaoCheckDigit(_ s: String) -> Int {
    let w = [7, 3, 1]
    var sum = 0
    for (i, ch) in s.uppercased().enumerated() {
        let v: Int
        if let d = ch.wholeNumberValue, ch.isASCII { v = d }
        else if ch == "<" { v = 0 }
        else if let a = ch.asciiValue, a >= 65 && a <= 90 { v = Int(a) - 55 }
        else { v = 0 }
        sum += v * w[i % 3]
    }
    return sum % 10
}

/// The key that opens the chip: passport number (padded to nine), birth and expiry, each followed by its check digit.
func mrzKey(passportNumber: String, birth: String, expiry: String) -> String {
    let n = passportNumber.uppercased().padding(toLength: 9, withPad: "<", startingAt: 0)
    return n + String(icaoCheckDigit(n)) + birth + String(icaoCheckDigit(birth)) + expiry + String(icaoCheckDigit(expiry))
}
