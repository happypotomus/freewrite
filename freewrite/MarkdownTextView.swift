import SwiftUI
import AppKit

struct SlashMenuState {
    var filterText: String
    var selectedIndex: Int
    var screenRect: NSRect
    var slashLocation: Int
    var insertBlock: (SlashBlockType) -> Void
}

class MarkdownNSTextView: NSTextView {
    weak var markdownCoordinator: MarkdownTextView.Coordinator?

    override func keyDown(with event: NSEvent) {
        if markdownCoordinator?.handleSlashKeyEvent(event, in: self) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "b" {
            markdownCoordinator?.toggleBold(in: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if markdownCoordinator?.insertImagesFromPasteboard(.general, in: self) == true {
            return
        }
        super.paste(sender)
    }
}

final class InlinePhotoImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class MarkdownLayoutManager: NSLayoutManager {
    override func setGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) {
        guard let textStorage = textStorage, glyphRange.length > 0 else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            return
        }

        var adjustedProperties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        for index in 0..<glyphRange.length {
            let characterIndex = charIndexes[index]
            guard characterIndex >= 0, characterIndex < textStorage.length else { continue }
            if (textStorage.attribute(.markdownHiddenSyntax, at: characterIndex, effectiveRange: nil) as? Bool) == true {
                adjustedProperties[index].insert(.null)
            }
        }

        adjustedProperties.withUnsafeBufferPointer { adjustedProps in
            super.setGlyphs(
                glyphs,
                properties: adjustedProps.baseAddress!,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
        }
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var pendingInsertion: String?
    var font: NSFont
    var textColor: NSColor
    var lineSpacing: CGFloat
    var colorScheme: ColorScheme
    var backspaceDisabled: Bool
    var imageBaseURL: URL?
    var imageMarkdownProvider: ((NSPasteboard) -> String?)?
    var onPhotoCommand: (() -> Void)?
    var onUserTextEdited: (() -> Void)?
    var onSlashStateChanged: ((SlashMenuState?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = MarkdownTextStorage()
        let layoutManager = MarkdownLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = MarkdownNSTextView(frame: .zero, textContainer: textContainer)
        textView.markdownCoordinator = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator

        context.coordinator.textView = textView
        context.coordinator.textStorage = textStorage
        textStorage.imageBaseURL = imageBaseURL

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        configureTextViewForScrolling(textView, in: scrollView)

        updateStyles(textStorage: textStorage, textView: textView)

        context.coordinator.isUpdatingFromBinding = true
        if !text.isEmpty {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }
        context.coordinator.isUpdatingFromBinding = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let textStorage = textView.textStorage as? MarkdownTextStorage else { return }

        let coordinator = context.coordinator

        // Update styles if font/theme changed
        let needsRestyle = coordinator.cachedFont != font
            || coordinator.cachedColorScheme != colorScheme
        if needsRestyle {
            coordinator.cachedFont = font
            coordinator.cachedColorScheme = colorScheme
            updateStyles(textStorage: textStorage, textView: textView)
            textStorage.reapplyAllFormatting()
        }

        if textStorage.imageBaseURL != imageBaseURL {
            textStorage.imageBaseURL = imageBaseURL
            textStorage.reapplyAllFormatting()
        }

        coordinator.backspaceDisabled = backspaceDisabled
        coordinator.parent = self

        // Sync text from binding if it changed externally
        if !coordinator.isUpdatingFromBinding && textStorage.string != text {
            coordinator.isUpdatingFromBinding = true
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.replaceCharacters(in: fullRange, with: text)
            textStorage.reapplyAllFormatting()
            coordinator.isUpdatingFromBinding = false
        }

        configureTextViewForScrolling(textView, in: scrollView)

        if let insertion = pendingInsertion,
           !insertion.isEmpty,
           coordinator.consumedPendingInsertion != insertion {
            coordinator.consumedPendingInsertion = insertion
            textView.insertText(insertion, replacementRange: textView.selectedRange())
            DispatchQueue.main.async {
                if pendingInsertion == insertion {
                    pendingInsertion = nil
                }
            }
        } else if pendingInsertion == nil {
            coordinator.consumedPendingInsertion = nil
        }

        coordinator.scheduleImageOverlayUpdate()
    }

    private func configureTextViewForScrolling(_ textView: NSTextView, in scrollView: NSScrollView) {
        let contentSize = scrollView.contentSize
        let horizontalInset = textView.textContainerInset.width
        let textContainerWidth = max(0, contentSize.width - (horizontalInset * 2))

        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = contentSize.width
        textView.textContainer?.containerSize = NSSize(
            width: textContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
    }

    private func updateStyles(textStorage: MarkdownTextStorage, textView: NSTextView) {
        let isDark = colorScheme == .dark
        textStorage.styles = MarkdownStyles(
            baseFont: font,
            baseFontSize: font.pointSize,
            isDark: isDark
        )
        textView.font = font
        textView.textColor = textStorage.styles.textColor
        textView.defaultParagraphStyle = textStorage.styles.defaultParagraphStyle
        textView.typingAttributes = textStorage.styles.defaultAttributes
        textView.insertionPointColor = isDark
            ? NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
            : NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        var isUpdatingFromBinding = false
        var textView: NSTextView?
        var textStorage: MarkdownTextStorage?
        var cachedFont: NSFont?
        var cachedColorScheme: ColorScheme?
        var backspaceDisabled = false
        var consumedPendingInsertion: String?
        private let editingEngine = MarkdownEditingEngine()
        private var imageViews: [NSImageView] = []
        private var slashLocation: Int?
        private var isSlashMenuActive = false
        private var slashSelectedIndex: Int = 0
        private var slashFilterText: String = ""
        private static let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", options: [])

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func handleSlashKeyEvent(_ event: NSEvent, in textView: NSTextView) -> Bool {
            guard isSlashMenuActive else { return false }

            let items = SlashBlockType.filtered(by: slashFilterText)
            guard !items.isEmpty else {
                dismissSlashMenu()
                return true
            }

            switch event.keyCode {
            case 126: // Up Arrow
                slashSelectedIndex = max(slashSelectedIndex - 1, 0)
                emitSlashState()
                return true
            case 125: // Down Arrow
                slashSelectedIndex = min(slashSelectedIndex + 1, items.count - 1)
                emitSlashState()
                return true
            case 36, 76: // Return / Enter
                if slashSelectedIndex < items.count {
                    insertBlockType(items[slashSelectedIndex], in: textView)
                }
                return true
            case 53: // Escape
                dismissSlashMenu()
                return true
            default:
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromBinding,
                  let textView = textView,
                  let textStorage = textStorage else { return }
            parent.text = textStorage.string
            parent.onUserTextEdited?()

            updateTypingAttributes()
            editingEngine.normalizeOrderedListsIfNeeded(in: textView)

            if isSlashMenuActive {
                updateSlashFilter()
            }

            scheduleImageOverlayUpdate()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateTypingAttributes()
        }

        private func updateTypingAttributes() {
            guard let textView = textView,
                  let textStorage = textStorage else { return }
            textView.typingAttributes = textStorage.styles.defaultAttributes
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }

            if !editingEngine.shouldAllowChange(in: textView, range: range, replacement: replacement) {
                return false
            }

            // Backspace blocking
            if backspaceDisabled && replacement.isEmpty && range.length > 0 {
                return false
            }

            // Slash command detection
            if replacement == "/" {
                let text = textView.string as NSString
                let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
                let lineStart = lineRange.location
                let textBeforeSlash = text.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
                if textBeforeSlash.allSatisfy({ $0.isWhitespace }) {
                    DispatchQueue.main.async { [weak self] in
                        self?.activateSlashMenu(at: range.location, in: textView)
                    }
                }
            }

            // Dismiss slash menu on certain inputs
            if isSlashMenuActive {
                if replacement == "\n" || replacement == " " {
                    dismissSlashMenu()
                } else if replacement == "" && range.length > 0 {
                    // Deleting — check if we're deleting the slash itself
                    if let slashLoc = slashLocation, range.location <= slashLoc {
                        dismissSlashMenu()
                    }
                }
            }

            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if isSlashMenuActive {
                let items = SlashBlockType.filtered(by: slashFilterText)
                if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    dismissSlashMenu()
                    return true
                }
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    slashSelectedIndex = max(slashSelectedIndex - 1, 0)
                    emitSlashState()
                    return true
                }
                if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    slashSelectedIndex = min(slashSelectedIndex + 1, items.count - 1)
                    emitSlashState()
                    return true
                }
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if slashSelectedIndex < items.count {
                        insertBlockType(items[slashSelectedIndex], in: textView)
                    }
                    return true
                }
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if editingEngine.handleCommand(commandSelector, in: textView) {
                    return true
                }
            }

            if commandSelector == #selector(NSResponder.insertTab(_:))
                || commandSelector == #selector(NSResponder.insertBacktab(_:))
                || commandSelector == #selector(NSResponder.deleteBackward(_:))
                || commandSelector == #selector(NSResponder.deleteForward(_:)) {
                if editingEngine.handleCommand(commandSelector, in: textView) { return true }
            }

            if backspaceDisabled {
                if commandSelector == #selector(NSResponder.deleteBackward(_:))
                    || commandSelector == #selector(NSResponder.deleteForward(_:)) {
                    return true
                }
            }

            return false
        }

        private func activateSlashMenu(at location: Int, in textView: NSTextView) {
            slashLocation = location + 1
            isSlashMenuActive = true
            slashSelectedIndex = 0
            slashFilterText = ""
            emitSlashState()
        }

        private func updateSlashFilter() {
            guard let slashLoc = slashLocation,
                  let textView = textView else { return }
            let currentPos = textView.selectedRange().location
            if currentPos < slashLoc {
                dismissSlashMenu()
                return
            }
            let filterRange = NSRange(location: slashLoc, length: currentPos - slashLoc)
            slashFilterText = (textView.string as NSString).substring(with: filterRange)

            let items = SlashBlockType.filtered(by: slashFilterText)
            if items.isEmpty {
                dismissSlashMenu()
                return
            }
            slashSelectedIndex = min(slashSelectedIndex, items.count - 1)
            emitSlashState()
        }

        private func emitSlashState() {
            guard let slashLoc = slashLocation,
                  let textView = textView,
                  let layoutManager = textView.layoutManager else { return }

            let charIndex = max(0, slashLoc - 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let locationInView = NSPoint(
                x: lineRect.origin.x + textView.textContainerInset.width,
                y: lineRect.maxY + textView.textContainerInset.height
            )
            let locationInWindow = textView.convert(locationInView, to: nil)
            let screenRect: NSRect
            if let window = textView.window {
                screenRect = window.convertToScreen(NSRect(origin: locationInWindow, size: CGSize(width: 1, height: 1)))
            } else {
                screenRect = NSRect(origin: locationInWindow, size: CGSize(width: 1, height: 1))
            }

            let state = SlashMenuState(
                filterText: slashFilterText,
                selectedIndex: slashSelectedIndex,
                screenRect: screenRect,
                slashLocation: slashLoc,
                insertBlock: { [weak self] blockType in
                    self?.insertBlockType(blockType, in: textView)
                }
            )
            parent.onSlashStateChanged?(state)
        }

        func toggleBold(in textView: NSTextView) {
            editingEngine.toggleBold(in: textView)
        }

        func dismissSlashMenu() {
            isSlashMenuActive = false
            slashLocation = nil
            parent.onSlashStateChanged?(nil)
        }

        func insertImagesFromPasteboard(_ pasteboard: NSPasteboard, in textView: NSTextView) -> Bool {
            guard let markdown = parent.imageMarkdownProvider?(pasteboard), !markdown.isEmpty else {
                return false
            }

            textView.insertText(markdown, replacementRange: textView.selectedRange())
            return true
        }

        func scheduleImageOverlayUpdate() {
            DispatchQueue.main.async { [weak self] in
                self?.updateImageOverlays()
            }
        }

        private func updateImageOverlays() {
            imageViews.forEach { $0.removeFromSuperview() }
            imageViews.removeAll()

            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }

            layoutManager.ensureLayout(for: textContainer)

            let nsText = textView.string as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            let matches = Self.imageRegex.matches(in: textView.string, range: fullRange)

            for match in matches {
                let path = nsText.substring(with: match.range(at: 2))
                guard let url = resolveImageURL(path),
                      let image = NSImage(contentsOf: url) else {
                    continue
                }

                let characterRange = NSRange(location: match.range.location, length: 1)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
                guard glyphRange.location < layoutManager.numberOfGlyphs else {
                    continue
                }

                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let displaySize = scaledImageSize(for: image, maxWidth: textContainer.containerSize.width)
                let containerOrigin = textView.textContainerOrigin
                let frame = NSRect(
                    x: containerOrigin.x + lineRect.minX,
                    y: containerOrigin.y + lineRect.minY + max(0, (lineRect.height - displaySize.height) / 2),
                    width: displaySize.width,
                    height: displaySize.height
                )

                let imageView = InlinePhotoImageView(frame: frame)
                imageView.image = image
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.masksToBounds = true
                imageView.layer?.borderWidth = 0.5
                imageView.layer?.borderColor = NSColor.separatorColor.cgColor
                imageView.isEditable = false
                textView.addSubview(imageView)
                imageViews.append(imageView)
            }
        }

        private func resolveImageURL(_ rawPath: String) -> URL? {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fileURL = URL(string: path), fileURL.isFileURL {
                return fileURL
            }
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path)
            }
            return parent.imageBaseURL?.appendingPathComponent(path)
        }

        private func scaledImageSize(for image: NSImage, maxWidth: CGFloat) -> NSSize {
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else {
                return NSSize(width: min(maxWidth, 520), height: 360)
            }

            let maxSize = NSSize(width: min(maxWidth, 520), height: 360)
            let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height, 1)
            return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }

        private func insertBlockType(_ blockType: SlashBlockType, in textView: NSTextView) {
            guard let slashLoc = slashLocation else { return }

            let currentPos = textView.selectedRange().location
            // Delete from the "/" to the current cursor position
            let deleteStart = slashLoc - 1
            let deleteRange = NSRange(location: deleteStart, length: currentPos - deleteStart)

            if blockType == .photo {
                textView.insertText("", replacementRange: deleteRange)
                dismissSlashMenu()
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onPhotoCommand?()
                }
                return
            }

            let prefix = blockType.markdownPrefix
            textView.insertText(prefix, replacementRange: deleteRange)

            dismissSlashMenu()
        }
    }
}
