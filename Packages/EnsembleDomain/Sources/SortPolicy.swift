import Foundation

public enum SortDirection: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending

    public var label: String { self == .ascending ? "Ascending" : "Descending" }
}
