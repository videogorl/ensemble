#if os(iOS)
import SwiftUI
import UIKit

/// Native momentum and cell reuse, with CoverFlow transforms derived from the live offset.
struct StageFlowCarousel<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
    let items: [Item]
    let selectedID: Item.ID?
    let hidesSelectedItem: Bool
    let itemView: (Item) -> Content
    let title: (Item) -> String
    let onSelection: (Item) -> Void
    let onActivate: (Item) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(configuration: self)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(self)
    }

    final class Controller: UICollectionViewController {
        var configuration: StageFlowCarousel
        private let flowLayout = StageFlowCollectionLayout()
        private var itemIDs: [Item.ID] = []
        private var pendingSelection = true
        private var lastSize = CGSize.zero
        private var isUpdating = false

        init(configuration: StageFlowCarousel) {
            self.configuration = configuration
            super.init(collectionViewLayout: flowLayout)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.backgroundColor = .clear
            collectionView.showsHorizontalScrollIndicator = false
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.decelerationRate = .fast
            collectionView.register(Cell.self, forCellWithReuseIdentifier: "artwork")
            update(configuration)
        }

        func update(_ configuration: StageFlowCarousel) {
            self.configuration = configuration
            guard isViewLoaded else { return }
            isUpdating = true
            defer { isUpdating = false }
            let ids = configuration.items.map(\.id)
            if itemIDs != ids {
                itemIDs = ids
                pendingSelection = true
                collectionView.reloadData()
            }
            flowLayout.hiddenIndex = configuration.hidesSelectedItem ? selectedIndex : nil
            flowLayout.invalidateLayout()
            if pendingSelection || (!collectionView.isTracking && !collectionView.isDecelerating && selectedIndex != centeredIndex) {
                collectionView.layoutIfNeeded()
                restoreSelection()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard collectionView.bounds.size != lastSize || pendingSelection else { return }
            lastSize = collectionView.bounds.size
            isUpdating = true
            restoreSelection()
            isUpdating = false
        }

        private var selectedIndex: Int {
            configuration.items.firstIndex { $0.id == configuration.selectedID } ?? 0
        }

        private var centeredIndex: Int {
            StageFlowLayoutModel.snappedIndex(
                for: Double(collectionView.contentOffset.x / flowLayout.itemSpacing),
                itemCount: configuration.items.count
            )
        }

        private func restoreSelection() {
            guard collectionView.bounds.width > 0 else { return }
            pendingSelection = false
            collectionView.setContentOffset(CGPoint(x: CGFloat(selectedIndex) * flowLayout.itemSpacing, y: 0), animated: false)
        }

        override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            configuration.items.count
        }

        override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "artwork", for: indexPath) as! Cell
            let item = configuration.items[indexPath.item]
            cell.configure(configuration.itemView(item), owner: self)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = configuration.title(item)
            cell.accessibilityIdentifier = "stageflow.item.\(indexPath.item)"
            cell.accessibilityTraits = .button
            return cell
        }

        override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            let item = configuration.items[indexPath.item]
            if indexPath.item == centeredIndex {
                configuration.onActivate(item)
            } else {
                collectionView.setContentOffset(CGPoint(x: CGFloat(indexPath.item) * flowLayout.itemSpacing, y: 0), animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }

        override func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isUpdating, !pendingSelection, configuration.items.indices.contains(centeredIndex) else { return }
            let item = configuration.items[centeredIndex]
            if item.id != configuration.selectedID { configuration.onSelection(item) }
        }

        override func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            let index = StageFlowLayoutModel.snappedIndex(
                for: Double(targetContentOffset.pointee.x / flowLayout.itemSpacing),
                itemCount: configuration.items.count
            )
            targetContentOffset.pointee.x = CGFloat(index) * flowLayout.itemSpacing
        }

        final class Cell: UICollectionViewCell {
            private var host: UIHostingController<Content>?

            func configure(_ content: Content, owner: UIViewController) {
                if let host {
                    host.rootView = content
                } else {
                    let host = UIHostingController(rootView: content)
                    owner.addChild(host)
                    host.view.backgroundColor = .clear
                    host.view.isUserInteractionEnabled = false
                    contentView.addSubview(host.view)
                    host.didMove(toParent: owner)
                    self.host = host
                }
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                host?.view.frame = contentView.bounds
            }
        }
    }
}

final class StageFlowCollectionLayout: UICollectionViewLayout {
    var hiddenIndex: Int?
    private var viewport: CGSize { collectionView?.bounds.size ?? .zero }
    private var itemSize: CGFloat { max(1, min(viewport.height * 0.62, viewport.width * 0.34) - 7) }
    var itemSpacing: CGFloat { max(1, itemSize * 0.78) }
    private var itemCount: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }

    override var collectionViewContentSize: CGSize {
        CGSize(width: viewport.width + CGFloat(max(0, itemCount - 1)) * itemSpacing, height: viewport.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView, itemCount > 0 else { return [] }
        let position = Double(collectionView.contentOffset.x / itemSpacing)
        // Include the wings beyond the viewport so reused cards enter from offscreen.
        let radius = Int(ceil((viewport.width / 2 + itemSize) / StageFlowLayoutMetrics.default.wingSpacing)) + 2
        let center = StageFlowLayoutModel.snappedIndex(for: position, itemCount: itemCount)
        return (max(0, center - radius)...min(itemCount - 1, center + radius)).compactMap {
            layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let collectionView else { return nil }
        let position = Double(collectionView.contentOffset.x / itemSpacing)
        let layout = StageFlowLayoutModel.layout(for: Double(indexPath.item) - position, metrics: .default)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.size = CGSize(width: itemSize, height: itemSize)
        attributes.center = CGPoint(x: collectionView.bounds.midX + layout.xOffset, y: viewport.height * 0.45)
        var transform = CATransform3DIdentity
        transform.m34 = -0.58 / itemSize
        transform = CATransform3DRotate(transform, CGFloat(layout.rotation) * .pi / 180, 0, 1, 0)
        attributes.transform3D = CATransform3DScale(transform, layout.scale, layout.scale, 1)
        attributes.zIndex = Int(layout.zIndex * 100)
        attributes.isHidden = hiddenIndex == indexPath.item
        return attributes
    }
}
#endif
