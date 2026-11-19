import AppKit

/// 「查看显示选项」浮层：图标大小、列表行高、是否显示隐藏文件。
/// 拖动即时生效（与访达的显示选项一致），不需要确认按钮。
final class DisplayOptionsViewController: NSViewController {

    var onIconSize: ((CGFloat) -> Void)?
    var onRowHeight: ((CGFloat) -> Void)?
    var onShowHidden: ((Bool) -> Void)?

    private let iconSlider = NSSlider()
    private let rowSlider = NSSlider()
    private let iconValue = NSTextField(labelWithString: "")
    private let rowValue = NSTextField(labelWithString: "")
    private let hiddenCheck = NSButton(checkboxWithTitle: "显示隐藏文件".localized, target: nil, action: nil)
    private let resetButton = NSButton()

    private let initialIconSize: CGFloat
    private let initialRowHeight: CGFloat
    private let initialShowHidden: Bool

    init(iconSize: CGFloat, rowHeight: CGFloat, showHidden: Bool) {
        initialIconSize = iconSize
        initialRowHeight = rowHeight
        initialShowHidden = showHidden
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 264, height: 226))
        view = root

        let title = NSTextField(labelWithString: "查看显示选项".localized)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        configure(slider: iconSlider,
                  min: 32, max: 128, value: initialIconSize,
                  action: #selector(iconSizeChanged))
        configure(slider: rowSlider,
                  min: 20, max: 38, value: initialRowHeight,
                  action: #selector(rowHeightChanged))
        updateValueLabels()

        hiddenCheck.title = "显示隐藏文件".localized
        hiddenCheck.font = .systemFont(ofSize: 12)
        hiddenCheck.state = initialShowHidden ? .on : .off
        hiddenCheck.target = self
        hiddenCheck.action = #selector(hiddenChanged)

        resetButton.title = "恢复默认".localized
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: 11)
        resetButton.target = self
        resetButton.action = #selector(resetDefaults)

        let iconHeader = headerRow(title: "图标大小".localized, value: iconValue)
        let rowHeader = headerRow(title: "列表行高".localized, value: rowValue)

        let stack = NSStackView(views: [title, iconHeader, iconSlider, rowHeader, rowSlider, hiddenCheck, resetButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(10, after: iconSlider)
        stack.setCustomSpacing(14, after: rowSlider)
        stack.setCustomSpacing(16, after: hiddenCheck)
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            iconHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            iconSlider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowSlider.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    // MARK: - 控件

    private func configure(slider: NSSlider,
                           min: CGFloat,
                           max: CGFloat,
                           value: CGFloat,
                           action: Selector) {
        slider.minValue = Double(min)
        slider.maxValue = Double(max)
        slider.doubleValue = Double(value)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = action
    }

    private func headerRow(title: String, value: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor

        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .tertiaryLabelColor
        value.alignment = .right

        let row = NSStackView(views: [label, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .equalSpacing
        return row
    }

    private func updateValueLabels() {
        iconValue.stringValue = "\(Int(iconSlider.doubleValue.rounded())) pt"
        rowValue.stringValue = "\(Int(rowSlider.doubleValue.rounded())) pt"
    }

    // MARK: - 动作

    @objc private func iconSizeChanged() {
        updateValueLabels()
        onIconSize?(CGFloat(iconSlider.doubleValue.rounded()))
    }

    @objc private func rowHeightChanged() {
        updateValueLabels()
        onRowHeight?(CGFloat(rowSlider.doubleValue.rounded()))
    }

    @objc private func hiddenChanged() {
        onShowHidden?(hiddenCheck.state == .on)
    }

    @objc private func resetDefaults() {
        iconSlider.doubleValue = Double(Theme.gridIconSize)
        rowSlider.doubleValue = Double(Theme.rowHeight)
        updateValueLabels()
        onIconSize?(Theme.gridIconSize)
        onRowHeight?(Theme.rowHeight)
    }
}
