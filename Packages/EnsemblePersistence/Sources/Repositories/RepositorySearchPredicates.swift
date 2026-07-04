import Foundation

enum RepositorySearchPredicates {
    static func tokenized(query: String, fieldNames: [String]) -> NSPredicate {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return NSPredicate(value: false)
        }

        let tokenPredicates = tokens.map { token in
            NSCompoundPredicate(orPredicateWithSubpredicates:
                fieldNames.map { field in
                    NSPredicate(format: "%K CONTAINS[cd] %@", field, token)
                }
            )
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: tokenPredicates)
    }
}
