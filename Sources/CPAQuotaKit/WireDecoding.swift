import Foundation

enum WireJSON: Sendable, Equatable {
    case object([String: WireJSON])
    case array([WireJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    static func decode(_ data: Data) throws -> WireJSON {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CPAError(.invalidResponse)
        }
        return convert(parsed)
    }

    private static func convert(_ any: Any) -> WireJSON {
        if let dictionary = any as? [String: Any] {
            var result: [String: WireJSON] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                result[key] = convert(value)
            }
            return .object(result)
        }
        if let array = any as? [Any] {
            return .array(array.map(convert))
        }
        if let string = any as? String {
            return .string(string)
        }
        if type(of: any) == Bool.self, let flag = any as? Bool {
            return .bool(flag)
        }
        if let number = any as? NSNumber {
            // JSON booleans bridge to NSNumber; objCType "c" distinguishes them from numbers.
            if String(cString: number.objCType) == "c" {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let flag = any as? Bool {
            return .bool(flag)
        }
        return .null
    }

    var objectEntries: [String: WireJSON]? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary
    }

    var arrayItems: [WireJSON]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    var integerValue: Int? {
        switch self {
        case .number(let value):
            guard value.isFinite else { return nil }
            return Int(exactly: value)
        case .string(let text):
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    func lookup(_ key: String) -> WireJSON? {
        guard case .object(let dictionary) = self else { return nil }
        if let value = dictionary[key] { return value }
        let needle = key.lowercased()
        for (candidate, value) in dictionary where candidate.lowercased() == needle {
            return value
        }
        return nil
    }

    func lookup(_ keys: [String]) -> WireJSON? {
        for key in keys {
            if let value = lookup(key), value != .null { return value }
        }
        return nil
    }

    func objectAt(_ keys: String...) -> WireJSON? {
        guard let value = lookup(keys), case .object = value else { return nil }
        return value
    }

    func arrayAt(_ keys: String...) -> [WireJSON]? {
        guard let value = lookup(keys), case .array(let items) = value else { return nil }
        return items
    }

    func stringAt(_ keys: String...) -> String? {
        WireJSON.scalarString(lookup(keys))
    }

    func numberAt(_ keys: String...) -> Double? {
        WireJSON.scalarNumber(lookup(keys))
    }

    func boolAt(_ keys: String...) -> Bool? {
        WireJSON.scalarBool(lookup(keys))
    }

    func dateAt(_ keys: String...) -> Date? {
        WireJSON.scalarDate(lookup(keys))
    }

    static func scalarString(_ value: WireJSON?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            return text
        case .number(let number):
            return formatNumber(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        default:
            return nil
        }
    }

    static func scalarNumber(_ value: WireJSON?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            return number.isFinite ? number : nil
        case .string(let text):
            guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  number.isFinite else { return nil }
            return number
        case .object:
            return scalarNumber(value.lookup(["val", "value"]))
        default:
            return nil
        }
    }

    static func scalarBool(_ value: WireJSON?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let flag):
            return flag
        case .number(let number):
            if number == 1 { return true }
            if number == 0 { return false }
            return nil
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    static func scalarDate(_ value: WireJSON?) -> Date? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            return WireDate.epochDate(number)
        case .string(let text):
            return WireDate.parse(text)
        default:
            return nil
        }
    }

    var foundationObject: Any {
        switch self {
        case .object(let dictionary):
            var result: [String: Any] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                result[key] = value.foundationObject
            }
            return result
        case .array(let items):
            return items.map { $0.foundationObject }
        case .string(let text):
            return text
        case .number(let number):
            return number
        case .bool(let flag):
            return flag
        case .null:
            return NSNull()
        }
    }

    private static func formatNumber(_ number: Double) -> String {
        guard number.isFinite else { return "" }
        if number.rounded() == number, let integer = Int64(exactly: number) {
            return String(integer)
        }
        return String(number)
    }
}

func nonEmptyWireString(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

enum WireDate {
    // Keep decoded instants inside the RFC 3339 year 1...9999 calendar range.
    private static let minimumEpoch: TimeInterval = -62_135_596_800
    private static let maximumEpoch: TimeInterval = 253_402_300_800

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    static func epochDate(_ seconds: TimeInterval) -> Date? {
        guard seconds.isFinite, seconds >= minimumEpoch, seconds < maximumEpoch else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    static func date(byAdding delay: TimeInterval, to base: Date) -> Date? {
        guard delay.isFinite, delay >= 0 else { return nil }
        return epochDate(base.timeIntervalSince1970 + delay)
    }

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(":"), !trimmed.contains("T"), !trimmed.contains("t"),
           trimmed.contains(where: { $0.isNumber }),
           let seconds = Double(trimmed), seconds.isFinite {
            return epochDate(seconds)
        }
        return parseRFC3339(trimmed)
    }

    static func retryAfter(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
            return date(byAdding: seconds, to: now)
        }
        if let date = parseHTTPDate(trimmed) { return date }
        return trimmed.contains("T") ? parse(trimmed) : nil
    }

    private static func parseRFC3339(_ text: String) -> Date? {
        guard let separator = text.firstIndex(where: { $0 == "T" || $0 == "t" || $0 == " " }) else {
            return nil
        }
        let datePart = text[..<separator]
        var timePart = String(text[text.index(after: separator)...])
        guard !timePart.isEmpty else { return nil }

        var offsetSeconds = 0
        var hasTimeZone = false
        if let last = timePart.last, last == "Z" || last == "z" {
            timePart.removeLast()
            hasTimeZone = true
        } else if let signIndex = timePart.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            guard let offset = parseOffset(String(timePart[signIndex...])) else { return nil }
            offsetSeconds = offset
            timePart = String(timePart[..<signIndex])
            hasTimeZone = true
        }
        guard hasTimeZone else { return nil }

        var fraction = 0.0
        if let dot = timePart.firstIndex(of: ".") {
            let fractionText = String(timePart[timePart.index(after: dot)...])
            guard !fractionText.isEmpty, fractionText.allSatisfy({ $0.isNumber }),
                  let parsed = Double("0." + fractionText) else { return nil }
            fraction = parsed
            timePart = String(timePart[..<dot])
        }

        let dateParts = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard dateParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]) else {
            return nil
        }
        let timeParts = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard timeParts.count == 3,
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2]) else {
            return nil
        }
        return makeDate(year: year, month: month, day: day,
                        hour: hour, minute: minute, second: second,
                        fraction: fraction, offsetSeconds: offsetSeconds)
    }

    private static func parseOffset(_ text: String) -> Int? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let body = text.dropFirst()
        let parts = body.split(separator: ":")
        let hours: Int
        let minutes: Int
        if parts.count == 2 {
            guard let parsedHours = Int(parts[0]), let parsedMinutes = Int(parts[1]) else { return nil }
            hours = parsedHours
            minutes = parsedMinutes
        } else if parts.count == 1 {
            let digits = parts[0]
            if digits.count == 4 {
                guard let parsedHours = Int(digits.prefix(2)), let parsedMinutes = Int(digits.suffix(2)) else {
                    return nil
                }
                hours = parsedHours
                minutes = parsedMinutes
            } else if digits.count >= 1 && digits.count <= 2 {
                guard let parsedHours = Int(digits) else { return nil }
                hours = parsedHours
                minutes = 0
            } else {
                return nil
            }
        } else {
            return nil
        }
        guard (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
        let total = hours * 3600 + minutes * 60
        return sign == "-" ? -total : total
    }

    private static func parseHTTPDate(_ text: String) -> Date? {
        let spaced = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if spaced.count == 5,
           let month = months[spaced[1].lowercased()],
           let day = Int(spaced[2]),
           let year = Int(spaced[4]),
           let time = timeParts(spaced[3]) {
            return makeDate(year: year, month: month, day: day,
                            hour: time.hour, minute: time.minute, second: time.second,
                            fraction: 0, offsetSeconds: 0)
        }

        var remainder = text
        if let comma = remainder.firstIndex(of: ",") {
            remainder = String(remainder[remainder.index(after: comma)...])
        }
        let tokens = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let dayToken = tokens.first else { return nil }
        if dayToken.contains("-") {
            guard tokens.count == 3, isSupportedHTTPZone(tokens[2]) else { return nil }
            let parts = dayToken.split(separator: "-")
            guard parts.count == 3,
                  let day = Int(parts[0]),
                  let month = months[parts[1].lowercased()],
                  let rawYear = Int(parts[2]),
                  let time = timeParts(tokens[1]) else { return nil }
            let year = rawYear < 100 ? (rawYear >= 70 ? 1900 + rawYear : 2000 + rawYear) : rawYear
            return makeDate(year: year, month: month, day: day,
                            hour: time.hour, minute: time.minute, second: time.second,
                            fraction: 0, offsetSeconds: 0)
        }
        guard tokens.count == 5, isSupportedHTTPZone(tokens[4]) else { return nil }
        guard let day = Int(dayToken),
              let month = months[tokens[1].lowercased()],
              let year = Int(tokens[2]),
              let time = timeParts(tokens[3]) else { return nil }
        return makeDate(year: year, month: month, day: day,
                        hour: time.hour, minute: time.minute, second: time.second,
                        fraction: 0, offsetSeconds: 0)
    }

    // HTTP-date requires GMT; UTC is accepted only as an explicit alias.
    private static func isSupportedHTTPZone(_ token: Substring) -> Bool {
        switch token.lowercased() {
        case "gmt", "utc": return true
        default: return false
        }
    }

    private static func timeParts(_ text: Substring) -> (hour: Int, minute: Int, second: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Int(parts[2]) else {
            return nil
        }
        return (hour, minute, second)
    }

    private static func makeDate(year: Int, month: Int, day: Int,
                                 hour: Int, minute: Int, second: Int,
                                 fraction: Double, offsetSeconds: Int) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              day <= daysInMonth(year: year, month: month) else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days) * 86_400
            + Double(hour * 3_600 + minute * 60 + second)
            - Double(offsetSeconds)
            + fraction
        return epochDate(seconds)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    // Calendar conversion uses 1970-01-01 as UTC day zero.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era * 146_097 + dayOfEra - 719_468)
    }
}

enum PayloadDecoder {
    static func inventory(_ data: Data, now: Date) throws -> DecodedInventory {
        let root = try WireJSON.decode(data)
        let files: [WireJSON]
        switch root {
        case .array(let items):
            files = items
        case .object:
            guard let items = root.arrayAt("files") else { throw CPAError(.invalidResponse) }
            files = items
        default:
            throw CPAError(.invalidResponse)
        }

        var seen = Set<String>()
        var entries: [AccountEntry] = []
        entries.reserveCapacity(files.count)
        for file in files {
            let entry = try makeEntry(from: file, now: now)
            guard seen.insert(entry.account.id).inserted else { throw CPAError(.invalidResponse) }
            entries.append(entry)
        }
        return DecodedInventory(entries: entries, observedAt: root.dateAt("observed_at", "observedAt"))
    }

    static func providers(_ data: Data) throws -> Set<String> {
        let root = try WireJSON.decode(data)
        let items: [WireJSON]
        switch root {
        case .array(let list):
            items = list
        case .object:
            guard let list = root.arrayAt("providers") else { throw CPAError(.invalidResponse) }
            items = list
        default:
            throw CPAError(.invalidResponse)
        }

        var result = Set<String>()
        for item in items {
            switch item {
            case .string(let provider):
                if let name = nonEmptyWireString(provider) { result.insert(name.lowercased()) }
            case .object:
                if let name = nonEmptyWireString(item.stringAt("provider")) {
                    result.insert(name.lowercased())
                }
                if let supported = item.arrayAt("supported_providers", "supportedProviders") {
                    for candidate in supported {
                        if let name = nonEmptyWireString(WireJSON.scalarString(candidate)) {
                            result.insert(name.lowercased())
                        }
                    }
                }
            default:
                continue
            }
        }
        return result
    }

    static func unwrapAPICall(_ data: Data, now: Date) throws -> Data {
        let root = try WireJSON.decode(data)
        guard case .object = root,
              let statusValue = root.lookup(["status_code", "statusCode"]),
              let status = statusValue.integerValue else {
            throw CPAError(.invalidResponse)
        }

        guard (200..<300).contains(status) else {
            let retryAfter = retryDate(from: root.lookup(["header", "headers"]), now: now)
            let kind: CPAError.Kind
            switch status {
            case 401, 403: kind = .upstreamUnauthorized
            case 429: kind = .rateLimited
            default: kind = .upstreamFailure
            }
            throw CPAError(kind, layer: .upstream, statusCode: status, retryAfter: retryAfter)
        }

        guard let body = root.lookup(["body"]) else { throw CPAError(.invalidResponse) }
        switch body {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bodyData = trimmed.data(using: .utf8) else { throw CPAError(.invalidResponse) }
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: bodyData, options: [.fragmentsAllowed])
            } catch {
                throw CPAError(.invalidResponse)
            }
            guard parsed is [String: Any] || parsed is [Any] else { throw CPAError(.invalidResponse) }
            return bodyData
        case .object, .array:
            do {
                return try JSONSerialization.data(withJSONObject: body.foundationObject, options: [])
            } catch {
                throw CPAError(.invalidResponse)
            }
        default:
            throw CPAError(.invalidResponse)
        }
    }

    private static func retryDate(from header: WireJSON?, now: Date) -> Date? {
        guard let header, case .object(let entries) = header else { return nil }
        var rawValue: WireJSON?
        for (key, value) in entries where key.lowercased() == "retry-after" {
            rawValue = value
            break
        }
        guard let rawValue else { return nil }
        let values: [String]
        if case .array(let items) = rawValue {
            values = items.compactMap { WireJSON.scalarString($0) }
        } else {
            values = [WireJSON.scalarString(rawValue)].compactMap { $0 }
        }
        for value in values {
            if let date = WireDate.retryAfter(value, now: now) { return date }
        }
        return nil
    }

    private static func makeEntry(from file: WireJSON, now: Date) throws -> AccountEntry {
        guard case .object = file else { throw CPAError(.invalidResponse) }

        let authIndex = nonEmptyWireString(file.stringAt("auth_index", "authIndex", "AuthIndex"))
        let name = nonEmptyWireString(file.stringAt("name"))
        let rawID = nonEmptyWireString(file.stringAt("id"))
        guard let identifier = rawID ?? name ?? authIndex else { throw CPAError(.invalidResponse) }

        let provider = nonEmptyWireString(file.stringAt("provider", "type")) ?? "unknown"
        let email = nonEmptyWireString(file.stringAt("email"))
        let label = nonEmptyWireString(file.stringAt("label"))
        let statusText = nonEmptyWireString(file.stringAt("status"))
        let disabledFlag = file.boolAt("disabled", "is_disabled", "isDisabled")
        let isDisabled = disabledFlag ?? (statusText?.lowercased() == "disabled")
        let isUnavailable = file.boolAt("unavailable", "is_unavailable", "isUnavailable") ?? false
        let status = statusText ?? (isDisabled ? "disabled" : "unknown")
        let supportsQuota = file.boolAt("supports_quota", "supportsQuota")
            ?? (nonEmptyWireString(file.stringAt("quota_provider", "quotaProvider")) != nil)

        let identity = identityObject(for: file)
        let codexAccountID = nonEmptyWireString(identity?.stringAt("chatgpt_account_id", "chatgptAccountId"))
        let plan = nonEmptyWireString(identity?.stringAt("plan_type", "planType"))

        let account = CPAAccount(
            id: identifier,
            authIndex: authIndex,
            provider: provider,
            displayName: label ?? email ?? name ?? identifier,
            email: email,
            status: status,
            isDisabled: isDisabled,
            isUnavailable: isUnavailable,
            supportsPluginQuota: supportsQuota,
            plan: plan
        )
        let passive = PassiveQuotaParser.snapshot(from: file, account: account, fetchedAt: now)
        return AccountEntry(account: account, codexAccountID: codexAccountID, passiveSnapshot: passive)
    }

    private static func identityObject(for file: WireJSON) -> WireJSON? {
        if let token = file.objectAt("id_token", "idToken") { return token }
        for containerKey in ["metadata", "attributes"] {
            guard let container = file.objectAt(containerKey) else { continue }
            if let token = container.objectAt("id_token", "idToken") { return token }
            if container.stringAt("chatgpt_account_id", "chatgptAccountId") != nil
                || container.stringAt("plan_type", "planType") != nil {
                return container
            }
        }
        return nil
    }
}
