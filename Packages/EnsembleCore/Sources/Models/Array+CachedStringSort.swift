import Foundation

extension Array where Element: Identifiable, Element.ID == String {
    func sortedByCachedStringKey(_ key: (Element) -> String, ascending: Bool) -> [Element] {
        map { ($0, key($0)) }
            .sorted {
                let result = $0.1.localizedStandardCompare($1.1)
                if result == .orderedSame {
                    return $0.0.id < $1.0.id
                }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            .map(\.0)
    }

    func sortedByComparableKey<Value: Comparable>(_ key: (Element) -> Value, ascending: Bool) -> [Element] {
        sorted {
            let left = key($0)
            let right = key($1)
            if left == right {
                return $0.id < $1.id
            }
            return ascending ? left < right : left > right
        }
    }

    /// Sorts present values before missing values in either direction and uses a stable identity for ties.
    func sortedByOptionalComparableKey<Value: Comparable>(
        _ key: (Element) -> Value?,
        stableID: (Element) -> String,
        ascending: Bool
    ) -> [Element] {
        sorted {
            switch (key($0), key($1)) {
            case let (.some(left), .some(right)):
                guard left != right else { return stableID($0) < stableID($1) }
                return ascending ? left < right : left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return stableID($0) < stableID($1)
            }
        }
    }
}
