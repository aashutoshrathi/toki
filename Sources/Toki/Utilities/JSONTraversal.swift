import Foundation

func sumNumbers(in value: Any, keys: Set<String>) -> Double {
    if let dict = value as? [String: Any] {
        return dict.reduce(0) { total, pair in
            let current = keys.contains(pair.key) ? numericValue(pair.value) : 0
            return total + current + sumNumbers(in: pair.value, keys: keys)
        }
    }
    if let array = value as? [Any] {
        return array.reduce(0) { $0 + sumNumbers(in: $1, keys: keys) }
    }
    return 0
}

func maxNumber(in value: Any, keys: Set<String>) -> Double {
    if let dict = value as? [String: Any] {
        return dict.reduce(0) { currentMax, pair in
            let current = keys.contains(pair.key) ? numericValue(pair.value) : 0
            return max(currentMax, current, maxNumber(in: pair.value, keys: keys))
        }
    }
    if let array = value as? [Any] {
        return array.reduce(0) { max($0, maxNumber(in: $1, keys: keys)) }
    }
    return 0
}

func sumOpenAICostsByCurrency(_ value: Any) -> MoneyTotals {
    var totals = MoneyTotals()
    if let dict = value as? [String: Any] {
        if let amount = dict["amount"] as? [String: Any] {
            let value = numericValue(amount["value"] ?? 0)
            let currency = (amount["currency"] as? String) ?? "USD"
            totals.add(Money(amount: value, currencyCode: currency))
        }
        for child in dict.values {
            totals.add(sumOpenAICostsByCurrency(child))
        }
        return totals
    }
    if let array = value as? [Any] {
        for child in array { totals.add(sumOpenAICostsByCurrency(child)) }
    }
    return totals
}

func sumAnthropicCosts(_ value: Any) -> Double {
    let cents = sumNumbers(in: value, keys: ["amount_cents", "cost_cents"])
    if cents > 0 { return cents / 100 }
    return sumNumbers(in: value, keys: ["cost_usd", "amount_usd", "cost"])
}

func numericValue(_ value: Any) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) ?? 0 }
    return 0
}

func optionalNumber(_ value: Any?) -> Double? {
    guard let value else { return nil }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

func firstValue(_ dict: [String: Any], keys: [String]) -> Any? {
    for key in keys {
        if let value = dict[key] {
            return value
        }
    }
    return nil
}

func firstString(in value: Any, keys: Set<String>) -> String? {
    if let dict = value as? [String: Any] {
        for key in keys {
            if let direct = dict[key] as? String, !direct.isEmpty {
                return direct
            }
            if let array = dict[key] as? [String], !array.isEmpty {
                return array.joined(separator: ", ")
            }
        }
        for child in dict.values {
            if let found = firstString(in: child, keys: keys) {
                return found
            }
        }
    }
    if let array = value as? [Any] {
        for child in array {
            if let found = firstString(in: child, keys: keys) {
                return found
            }
        }
    }
    return nil
}
