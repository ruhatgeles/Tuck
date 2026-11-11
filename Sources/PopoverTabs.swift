import AppKit

/// Menu bar popover content: a "Raf | Pano" switch on top of the two lists.
final class PopoverTabsViewController: NSViewController {
    private let shelfVC: ShelfViewController
    private let clipVC: ClipboardViewController
    private let segment = NSSegmentedControl(labels: ["Raf", "Pano"], trackingMode: .selectOne, target: nil, action: nil)
    private let container = NSView()

    private static let key = "popoverTab"

    init(shelf: ShelfViewController, clipboard: ClipboardViewController) {
        shelfVC = shelf
        clipVC = clipboard
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
        segment.target = self
        segment.action = #selector(switchTab)
        segment.segmentStyle = .automatic
        segment.selectedSegment = UserDefaults.standard.integer(forKey: Self.key)
        segment.setToolTip("Bırakılan dosyalar", forSegment: 0)
        segment.setToolTip("Kopyalama geçmişi", forSegment: 1)

        for v in [segment, container] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            segment.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            segment.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            segment.widthAnchor.constraint(equalToConstant: 200),
            container.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 2),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        addChild(shelfVC)
        addChild(clipVC)
        view = root
        show(segment.selectedSegment)
    }

    @objc private func switchTab() {
        UserDefaults.standard.set(segment.selectedSegment, forKey: Self.key)
        show(segment.selectedSegment)
    }

    func select(_ index: Int) {
        guard isViewLoaded else { UserDefaults.standard.set(index, forKey: Self.key); return }
        segment.selectedSegment = index
        switchTab()
    }

    private func show(_ index: Int) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let vc: NSViewController = index == 1 ? clipVC : shelfVC
        vc.view.frame = container.bounds
        vc.view.autoresizingMask = [.width, .height]
        container.addSubview(vc.view)
        if index == 1 { clipVC.reload(); clipVC.focusSearch() } else { shelfVC.reload() }
    }
}
