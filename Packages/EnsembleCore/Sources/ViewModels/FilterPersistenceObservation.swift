import Combine
import Foundation

extension FilterPersistence {
    static func observe<P: Publisher>(
        _ publisher: P,
        key viewType: String,
        storingIn cancellables: inout Set<AnyCancellable>
    ) where P.Output == FilterOptions, P.Failure == Never {
        publisher
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { save($0, for: viewType) }
            .store(in: &cancellables)
    }
}
