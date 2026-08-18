import AppKit

private final class SwitcherCardView: NSView {
    let index: Int
    var isCardSelected: Bool = false {
        didSet {
            updateSelectionState()
        }
    }

    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    private let iconImageView = NSImageView()
    private let appLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(index: Int, window: WindowItem, frame: NSRect) {
        self.index = index
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        // Large Crisp App Icon
        let iconSize: CGFloat = 58
        let iconX = (frame.width - iconSize) / 2
        iconImageView.frame = NSRect(x: iconX, y: frame.height - iconSize - 12, width: iconSize, height: iconSize)
        iconImageView.image = window.appIcon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: window.appName)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        // App Name + Subtitle Badge (e.g. "Safari • Personal" or "Antigravity IDE • TrackpadGestures")
        let appNameText: String
        if let sub = window.subtitle, !sub.isEmpty {
            appNameText = "\(window.appName) • \(sub)"
        } else {
            appNameText = window.appName
        }
        appLabel.stringValue = appNameText
        appLabel.frame = NSRect(x: 8, y: 44, width: frame.width - 16, height: 16)
        appLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        appLabel.textColor = NSColor(white: 0.75, alpha: 1.0)
        appLabel.alignment = .center
        appLabel.lineBreakMode = .byTruncatingTail
        addSubview(appLabel)

        // Rich Window Title Label (Supports up to 3 lines of clear, full-length text)
        titleLabel.stringValue = window.title
        titleLabel.frame = NSRect(x: 8, y: 6, width: frame.width - 16, height: 36)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        updateSelectionState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(index)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(index)
    }

    private func updateSelectionState() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        if isCardSelected {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 3.0
            layer?.backgroundColor = NSColor(white: 0.35, alpha: 0.7).cgColor
            titleLabel.textColor = .white
            appLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        } else {
            layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
            layer?.borderWidth = 1.0
            layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.5).cgColor
            titleLabel.textColor = NSColor(white: 0.88, alpha: 1.0)
            appLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        }
        CATransaction.commit()
    }
}

final class SwitcherPanel: NSPanel {
    var onCommit: ((WindowItem) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [WindowItem] = []
    private var selectedIndex = 0
    private var cardViews: [SwitcherCardView] = []
    private var gridColumns = 1
    private var gridRows = 1

    private let visualEffectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let cardsContainer = NSView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 20
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        visualEffectView.layer?.borderWidth = 1.0

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = cardsContainer

        visualEffectView.addSubview(scrollView)
        contentView = visualEffectView
    }

    var isActive: Bool {
        isVisible
    }

    var selectedItem: WindowItem? {
        guard !windows.isEmpty, selectedIndex >= 0, selectedIndex < windows.count else { return nil }
        return windows[selectedIndex]
    }

    func show(windows: [WindowItem], initialIndex: Int) {
        guard !windows.isEmpty else { return }

        self.windows = windows
        selectedIndex = min(max(initialIndex, 0), windows.count - 1)

        buildCards()
        updateLayoutAndPosition()
        updateCardHighlights()

        orderFrontRegardless()
    }

    func next() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % windows.count
        updateCardHighlights()
        scrollToSelectedCard()
    }

    func previous() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + windows.count) % windows.count
        updateCardHighlights()
        scrollToSelectedCard()
    }

    func stepGrid(rowDelta: Int, colDelta: Int) {
        guard !windows.isEmpty else { return }

        if colDelta != 0 {
            if colDelta > 0 {
                next()
            } else {
                previous()
            }
            return
        }

        if rowDelta != 0 && gridRows > 1 {
            let currentRow = selectedIndex / gridColumns
            let currentCol = selectedIndex % gridColumns
            let targetRow = (currentRow + rowDelta + gridRows) % gridRows
            let countInTargetRow = min(gridColumns, windows.count - targetRow * gridColumns)
            let targetCol = min(currentCol, countInTargetRow - 1)
            let targetIndex = targetRow * gridColumns + targetCol
            selectedIndex = targetIndex
            updateCardHighlights()
            scrollToSelectedCard()
        }
    }

    func select(index: Int) {
        guard index >= 0 && index < windows.count else { return }
        selectedIndex = index
        updateCardHighlights()
        scrollToSelectedCard()
    }

    func removeSelectedWindow() {
        guard !windows.isEmpty, selectedIndex >= 0, selectedIndex < windows.count else { return }
        windows.remove(at: selectedIndex)
        if windows.isEmpty {
            dismiss()
            return
        }
        selectedIndex = min(selectedIndex, windows.count - 1)
        buildCards()
        updateLayoutAndPosition()
        updateCardHighlights()
        scrollToSelectedCard()
    }

    func removeAllWindows(forApp app: NSRunningApplication) {
        windows.removeAll { $0.app.processIdentifier == app.processIdentifier }
        if windows.isEmpty {
            dismiss()
            return
        }
        selectedIndex = min(selectedIndex, windows.count - 1)
        buildCards()
        updateLayoutAndPosition()
        updateCardHighlights()
        scrollToSelectedCard()
    }

    func dismiss() {
        orderOut(nil)
        cardViews.removeAll()
        cardsContainer.subviews.forEach { $0.removeFromSuperview() }
        windows.removeAll()
        onCancel?()
    }

    func commit() {
        guard !windows.isEmpty else {
            dismiss()
            return
        }
        let item = windows[selectedIndex]
        dismiss()
        onCommit?(item)
    }

    private func buildCards() {
        cardViews.removeAll()
        cardsContainer.subviews.forEach { $0.removeFromSuperview() }

        let cardWidth: CGFloat = 190
        let cardHeight: CGFloat = 155
        let spacing: CGFloat = 14
        let margin: CGFloat = 16

        let totalCount = windows.count
        if totalCount <= 4 {
            gridColumns = totalCount
            gridRows = 1
        } else {
            gridColumns = min(5, Int(ceil(Double(totalCount) / 2.0)))
            gridRows = Int(ceil(Double(totalCount) / Double(gridColumns)))
        }

        let maxCols = min(gridColumns, totalCount)
        let totalGridWidth = margin * 2 + CGFloat(maxCols) * cardWidth + CGFloat(max(0, maxCols - 1)) * spacing
        let totalGridHeight = margin * 2 + CGFloat(gridRows) * cardHeight + CGFloat(max(0, gridRows - 1)) * spacing

        for r in 0..<gridRows {
            let startIndex = r * gridColumns
            let endIndex = min(startIndex + gridColumns, totalCount)
            let countInRow = endIndex - startIndex
            let rowWidth = CGFloat(countInRow) * cardWidth + CGFloat(max(0, countInRow - 1)) * spacing
            let rowXOffset = (totalGridWidth - margin * 2 - rowWidth) / 2

            for c in 0..<countInRow {
                let index = startIndex + c
                let window = windows[index]

                let x = margin + rowXOffset + CGFloat(c) * (cardWidth + spacing)
                let y = margin + CGFloat(gridRows - 1 - r) * (cardHeight + spacing)
                let cardFrame = NSRect(x: x, y: y, width: cardWidth, height: cardHeight)

                let card = SwitcherCardView(index: index, window: window, frame: cardFrame)
                card.onClick = { [weak self] clickedIndex in
                    self?.selectedIndex = clickedIndex
                    self?.commit()
                }
                card.onHover = { [weak self] hoveredIndex in
                    self?.selectedIndex = hoveredIndex
                    self?.updateCardHighlights()
                }

                cardsContainer.addSubview(card)
                cardViews.append(card)
            }
        }

        cardsContainer.frame = NSRect(x: 0, y: 0, width: totalGridWidth, height: totalGridHeight)
    }

    private func updateLayoutAndPosition() {
        let activeScreen = currentActiveScreen()
        let screenVisibleFrame = activeScreen.visibleFrame

        let naturalWidth = cardsContainer.frame.width
        let naturalHeight = cardsContainer.frame.height

        let maxAvailableWidth = screenVisibleFrame.width - 60
        let maxAvailableHeight = screenVisibleFrame.height - 60

        let panelWidth = min(naturalWidth, maxAvailableWidth)
        let panelHeight = min(naturalHeight, maxAvailableHeight)

        visualEffectView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        scrollView.frame = visualEffectView.bounds

        let panelX = screenVisibleFrame.midX - (panelWidth / 2)
        let panelY = screenVisibleFrame.midY - (panelHeight / 2)
        setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)
    }

    private func updateCardHighlights() {
        for (index, card) in cardViews.enumerated() {
            card.isCardSelected = (index == selectedIndex)
        }
    }

    private func scrollToSelectedCard() {
        guard selectedIndex < cardViews.count else { return }
        let targetCard = cardViews[selectedIndex]
        cardsContainer.scrollToVisible(targetCard.frame.insetBy(dx: -16, dy: -16))
    }

    private func currentActiveScreen() -> NSScreen {
        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
