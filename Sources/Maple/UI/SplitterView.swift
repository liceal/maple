import AppKit

/// 可拖动的分隔条。
/// 平时完全透明（只露出底色的一道 1pt 细缝），指针进入时只换调整光标，
/// 不做任何描边或高亮，保持界面简洁。
final class SplitterView: NSView {

    enum Axis {
        /// 竖向分隔条：左右拖动。
        case vertical
        /// 横向分隔条：上下拖动。
        case horizontal
    }

    var axis: Axis = .vertical
    /// 按下（开始拖动）。
    var onDragBegan: (() -> Void)?
    /// 从按下点算起的总位移，向右 / 向下为正。
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    private var hoverArea: NSTrackingArea?
    private var dragOrigin: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if AppSettings.cornerScheme == .cards { return }
        // 居中画一道设备像素级 1px 发丝线，与列表列线、侧栏分隔线视觉一致，
        // 让分隔条可见、好抓（平时完全透明，只在中间留这条细缝）。
        let scale = (window?.screen?.backingScaleFactor) ?? 1
        let lineW = 1.0 / scale
        NSColor.separatorColor.setFill()
        if axis == .vertical {
            let x = ((bounds.width / 2) * scale).rounded() / scale
            NSRect(x: x, y: 0, width: lineW, height: bounds.height).fill()
        } else {
            let y = ((bounds.height / 2) * scale).rounded() / scale
            NSRect(x: 0, y: y, width: bounds.width, height: lineW).fill()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func mouseDown(with event: NSEvent) {
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        dragOrigin = event.locationInWindow
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        // 用「窗口坐标下的总位移」而不是 NSEvent.deltaX/deltaY：
        // 窗口坐标一定向右、向上为正，换算成「向右 / 向下」不会被坐标翻转或设备差异弄反。
        let dx = event.locationInWindow.x - dragOrigin.x
        let dy = dragOrigin.y - event.locationInWindow.y
        let translation = axis == .vertical ? dx : dy
        guard abs(translation) > 0.01 else { return }
        onDrag?(translation)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}
