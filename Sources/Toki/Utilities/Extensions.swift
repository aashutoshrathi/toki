import Foundation

extension Calendar {
    func startOfCurrentMonth() -> Date {
        dateInterval(of: .month, for: Date())?.start ?? startOfDay(for: Date())
    }
}

extension JSONDecoder {
    static var toki: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var toki: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
