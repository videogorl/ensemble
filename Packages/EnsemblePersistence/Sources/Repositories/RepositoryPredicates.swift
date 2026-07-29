import CoreData
import Foundation

enum RepositoryPredicates {
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

    static func sourceScopedOrphan(sourceKey: String, validRatingKeys: Set<String>) -> NSPredicate {
        let sourcePredicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
        guard !validRatingKeys.isEmpty else { return sourcePredicate }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            sourcePredicate,
            NSPredicate(format: "NOT (ratingKey IN %@)", Array(validRatingKeys))
        ])
    }

    static func ratingKey(_ ratingKey: String, sourceCompositeKey: String?) -> NSPredicate {
        guard let sourceCompositeKey else {
            return NSPredicate(format: "ratingKey == %@", ratingKey)
        }

        return NSPredicate(
            format: "ratingKey == %@ AND sourceCompositeKey == %@",
            ratingKey,
            sourceCompositeKey
        )
    }

}
