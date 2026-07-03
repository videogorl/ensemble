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
}
