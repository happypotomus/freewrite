import AppKit

extension NSAttributedString.Key {
    static let markdownHiddenSyntax = NSAttributedString.Key("freewrite.markdownHiddenSyntax")
}

struct MarkdownStyles {
    let baseFont: NSFont
    let baseFontSize: CGFloat
    let isDark: Bool

    var textColor: NSColor {
        isDark ? NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
               : NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0)
    }

    var hiddenSyntaxAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor.clear,
            .markdownHiddenSyntax: true
        ]
    }

    var imageAnchorAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor.clear
        ]
    }

    var quoteTextColor: NSColor {
        textColor.withAlphaComponent(0.7)
    }

    var dividerTextColor: NSColor {
        textColor.withAlphaComponent(0.35)
    }

    func headingFont(level: Int) -> NSFont {
        let scale: CGFloat = level == 1 ? 1.6 : level == 2 ? 1.3 : 1.1
        let size = baseFontSize * scale
        let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        return NSFontManager.shared.convert(bold, toSize: size)
    }

    var boldFont: NSFont {
        NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    }

    var italicFont: NSFont {
        NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    }

    var defaultParagraphStyle: NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }

    var listParagraphStyle: NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.firstLineHeadIndent = 8
        style.headIndent = 24
        style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
        return style
    }

    var quoteParagraphStyle: NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.firstLineHeadIndent = 20
        style.headIndent = 20
        return style
    }

    var dividerParagraphStyle: NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = 8
        style.paragraphSpacing = 8
        return style
    }

    var lineSpacing: CGFloat {
        let defaultHeight = baseFont.ascender - baseFont.descender + baseFont.leading
        return (baseFontSize * 1.5) - defaultHeight
    }

    var defaultAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: textColor,
            .paragraphStyle: defaultParagraphStyle
        ]
    }
}

class MarkdownTextStorage: NSTextStorage {
    private let backingStore = NSMutableAttributedString()
    var imageBaseURL: URL?
    var styles = MarkdownStyles(
        baseFont: .systemFont(ofSize: 18),
        baseFontSize: 18,
        isDark: false
    )

    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,3})\\s+(.+)$", options: .anchorsMatchLines)
    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*", options: [.dotMatchesLineSeparators])
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", options: [])
    private static let bulletRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+•])\\s+(.*)$", options: .anchorsMatchLines)
    private static let numberedRegex = try! NSRegularExpression(pattern: "^(\\s*\\d+\\.)\\s+(.*)$", options: .anchorsMatchLines)
    private static let quoteRegex = try! NSRegularExpression(pattern: "^(>)\\s+(.+)$", options: .anchorsMatchLines)
    private static let dividerRegex = try! NSRegularExpression(pattern: "^\\s{0,3}(-{3,}|\\*{3,}|_{3,})\\s*$", options: .anchorsMatchLines)
    private static let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", options: [])

    override var string: String { backingStore.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backingStore.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backingStore.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: str.count - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backingStore.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    override func processEditing() {
        applyFormatting(in: editedRange)
        super.processEditing()
    }

    func reapplyAllFormatting() {
        guard length > 0 else { return }
        applyFormatting(in: NSRange(location: 0, length: length))
    }

    private func applyFormatting(in editedRange: NSRange) {
        guard length > 0 else { return }

        let wholeString = string as NSString
        let paragraphRange = wholeString.paragraphRange(for: editedRange)

        guard paragraphRange.location != NSNotFound, paragraphRange.length > 0 else { return }

        backingStore.setAttributes(styles.defaultAttributes, range: paragraphRange)

        let text = wholeString.substring(with: paragraphRange) as NSString
        let localRange = NSRange(location: 0, length: text.length)

        applyHeadings(text: text, localRange: localRange, offset: paragraphRange.location)
        applyBold(text: text, localRange: localRange, offset: paragraphRange.location)
        applyItalic(text: text, localRange: localRange, offset: paragraphRange.location)
        applyBulletLists(text: text, localRange: localRange, offset: paragraphRange.location)
        applyNumberedLists(text: text, localRange: localRange, offset: paragraphRange.location)
        applyBlockQuotes(text: text, localRange: localRange, offset: paragraphRange.location)
        applyDividers(text: text, localRange: localRange, offset: paragraphRange.location)
        applyImages(text: text, localRange: localRange, offset: paragraphRange.location)
        invalidateLayout(for: paragraphRange)
    }

    private func invalidateLayout(for range: NSRange) {
        layoutManagers.forEach { layoutManager in
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    private func applyHeadings(text: NSString, localRange: NSRange, offset: Int) {
        Self.headingRegex.enumerateMatches(in: text as String, range: localRange) { match, _, _ in
            guard let match = match else { return }
            let hashRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            let level = hashRange.length

            let headingFont = styles.headingFont(level: level)

            let globalContentRange = NSRange(location: contentRange.location + offset, length: contentRange.length)
            backingStore.addAttribute(.font, value: headingFont, range: globalContentRange)

            // Hide the hash marks and the space after them
            let globalHashRange = NSRange(location: hashRange.location + offset, length: hashRange.length + 1)
            backingStore.addAttributes(styles.hiddenSyntaxAttributes, range: globalHashRange)
        }
    }

    private func applyBold(text: NSString, localRange: NSRange, offset: Int) {
        Self.boldRegex.enumerateMatches(in: text as String, range: localRange) { match, _, _ in
            guard let match = match else { return }
            let fullRange = match.range
            let contentRange = match.range(at: 1)

            let globalContentRange = NSRange(location: contentRange.location + offset, length: contentRange.length)
            backingStore.addAttribute(.font, value: styles.boldFont, range: globalContentRange)

            // Hide the ** delimiters
            let openRange = NSRange(location: fullRange.location + offset, length: 2)
            let closeRange = NSRange(location: fullRange.location + fullRange.length - 2 + offset, length: 2)
            backingStore.addAttributes(styles.hiddenSyntaxAttributes, range: openRange)
            backingStore.addAttributes(styles.hiddenSyntaxAttributes, range: closeRange)
        }
    }

    private func applyItalic(text: NSString, localRange: NSRange, offset: Int) {
        Self.italicRegex.enumerateMatches(in: text as String, range: localRange) { match, _, _ in
            guard let match = match else { return }
            let fullRange = match.range
            let contentRange = match.range(at: 1)

            let globalContentRange = NSRange(location: contentRange.location + offset, length: contentRange.length)
            backingStore.addAttribute(.font, value: styles.italicFont, range: globalContentRange)

            // Hide the * delimiters
            let openRange = NSRange(location: fullRange.location + offset, length: 1)
            let closeRange = NSRange(location: fullRange.location + fullRange.length - 1 + offset, length: 1)
            backingStore.addAttributes(styles.hiddenSyntaxAttributes, range: openRange)
            backingStore.addAttributes(styles.hiddenSyntaxAttributes, range: closeRange)
        }
    }

    private func applyBulletLists(text: NSString, localRange: NSRange, offset: Int) {
        Self.bulletRegex.enumerateMatches(in: text as String, range: localRange) { match, _, _ in
            guard let match = match else { return }
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            backingStore.addAttribute(.paragraphStyle, value: styles.listParagraphStyle, range: fullRange)
        }
    }

    private func applyNumberedLists(text: NSString, localRange: NSRange, offset: Int) {
        Self.numberedRegex.enumerateMatches(in: text as String, range: localRange) { match, _, _ in
            guard let match = match else { return }
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            backingStore.addAttribute(.paragraphStyle, value: styles.listParagraphStyle, range: fullRange)
        }
    }

    private func applyBlockQuotes(text: NSString, localRange: NSRange, offset: Int) {
        Self.quoteRegex.enumerateMatches(in: text as String, range: localRange) { match, _, _ in
            guard let match = match else { return }
            let markerRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)

            backingStore.addAttribute(.paragraphStyle, value: styles.quoteParagraphStyle, range: fullRange)

            // Hide the > marker and space
            let globalMarkerRange = NSRange(location: markerRange.location + offset, length: markerRange.length + 1)
            backingStore.addAttributes(styles.hiddenSyntaxAttributes, range: globalMarkerRange)

            let globalContentRange = NSRange(location: contentRange.location + offset, length: contentRange.length)
            backingStore.addAttributes([
                .font: styles.italicFont,
                .foregroundColor: styles.quoteTextColor
            ], range: globalContentRange)
        }
    }

    private func applyDividers(text: NSString, localRange: NSRange, offset: Int) {
        Self.dividerRegex.enumerateMatches(in: text as String, range: localRange) { match, _, _ in
            guard let match = match else { return }
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            backingStore.addAttributes([
                .font: styles.baseFont,
                .foregroundColor: styles.dividerTextColor,
                .paragraphStyle: styles.dividerParagraphStyle
            ], range: fullRange)
        }
    }

    private func applyImages(text: NSString, localRange: NSRange, offset: Int) {
        Self.imageRegex.enumerateMatches(in: text as String, range: localRange) { match, _, _ in
            guard let match = match else { return }

            let path = text.substring(with: match.range(at: 2))
            guard let url = resolveImageURL(path), let image = NSImage(contentsOf: url) else {
                return
            }

            let displaySize = scaledInlineImageSize(for: image)
            let globalRange = NSRange(location: match.range.location + offset, length: match.range.length)
            backingStore.addAttributes([
                .paragraphStyle: imageParagraphStyle(for: displaySize)
            ], range: globalRange)
            backingStore.addAttributes(styles.imageAnchorAttributes, range: NSRange(location: globalRange.location, length: 1))
            if globalRange.length > 1 {
                let hiddenRange = NSRange(location: globalRange.location + 1, length: globalRange.length - 1)
                backingStore.addAttributes(styles.hiddenSyntaxAttributes, range: hiddenRange)
            }
        }
    }

    private func imageParagraphStyle(for imageSize: NSSize) -> NSMutableParagraphStyle {
        let style = styles.defaultParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        style.minimumLineHeight = imageSize.height + 20
        style.maximumLineHeight = imageSize.height + 20
        style.paragraphSpacingBefore = 10
        style.paragraphSpacing = 10
        return style
    }

    private func resolveImageURL(_ rawPath: String) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fileURL = URL(string: path), fileURL.isFileURL {
            return fileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return imageBaseURL?.appendingPathComponent(path)
    }

    private func scaledInlineImageSize(for image: NSImage) -> NSSize {
        let maxSize = NSSize(width: 520, height: 360)
        let imageSize = image.size

        guard imageSize.width > 0, imageSize.height > 0 else {
            return maxSize
        }

        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height, 1)
        return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    // MARK: - Markdown-aware PDF attributed string

    func createPDFAttributedString(from rawText: String) -> NSAttributedString {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = NSMutableAttributedString()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = styles.lineSpacing
        paragraphStyle.paragraphSpacing = 4

        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: styles.baseFont,
            .foregroundColor: NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ]

        for line in trimmed.components(separatedBy: "\n") {
            let processed = processPDFLine(line, defaultAttrs: defaultAttrs, paragraphStyle: paragraphStyle)
            result.append(processed)
            result.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
        }

        return result
    }

    private func processPDFLine(_ line: String, defaultAttrs: [NSAttributedString.Key: Any], paragraphStyle: NSMutableParagraphStyle) -> NSAttributedString {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)

        // Headings: strip the # prefix, render styled
        if let match = Self.headingRegex.firstMatch(in: line, range: range) {
            let level = match.range(at: 1).length
            let content = nsLine.substring(with: match.range(at: 2))
            let headingFont = styles.headingFont(level: level)
            let headingParagraph = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            headingParagraph.paragraphSpacing = level == 1 ? 12 : 8
            return NSAttributedString(string: content, attributes: [
                .font: headingFont,
                .foregroundColor: NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0),
                .paragraphStyle: headingParagraph
            ])
        }

        // Block quotes: strip >, render italic
        if let match = Self.quoteRegex.firstMatch(in: line, range: range) {
            let content = nsLine.substring(with: match.range(at: 2))
            let quoteParagraph = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            quoteParagraph.firstLineHeadIndent = 20
            quoteParagraph.headIndent = 20
            return NSAttributedString(string: content, attributes: [
                .font: styles.italicFont,
                .foregroundColor: NSColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1.0),
                .paragraphStyle: quoteParagraph
            ])
        }

        if Self.dividerRegex.firstMatch(in: line, range: range) != nil {
            let dividerParagraph = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            dividerParagraph.paragraphSpacingBefore = 8
            dividerParagraph.paragraphSpacing = 8
            return NSAttributedString(string: "------------------------------", attributes: [
                .font: styles.baseFont,
                .foregroundColor: NSColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1.0),
                .paragraphStyle: dividerParagraph
            ])
        }

        // Lists: keep the marker, apply indent
        if Self.bulletRegex.firstMatch(in: line, range: range) != nil ||
           Self.numberedRegex.firstMatch(in: line, range: range) != nil {
            let listParagraph = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            listParagraph.firstLineHeadIndent = 8
            listParagraph.headIndent = 24
            let result = NSMutableAttributedString(string: line, attributes: [
                .font: styles.baseFont,
                .foregroundColor: NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0),
                .paragraphStyle: listParagraph
            ])
            applyInlineStyles(to: result)
            return result
        }

        // Normal line: apply inline styles (bold, italic)
        let result = NSMutableAttributedString(string: line, attributes: defaultAttrs)
        applyInlineStyles(to: result)
        return result
    }

    private func applyInlineStyles(to attrString: NSMutableAttributedString) {
        let text = attrString.string
        let range = NSRange(location: 0, length: (text as NSString).length)

        // Bold: replace **text** with bold text (remove markers)
        let boldMatches = Self.boldRegex.matches(in: text, range: range)
        for match in boldMatches.reversed() {
            let contentRange = match.range(at: 1)
            let content = (text as NSString).substring(with: contentRange)
            let boldStr = NSAttributedString(string: content, attributes: [
                .font: styles.boldFont,
                .foregroundColor: attrString.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) ?? NSColor.black,
                .paragraphStyle: attrString.attribute(.paragraphStyle, at: match.range.location, effectiveRange: nil) ?? NSMutableParagraphStyle()
            ])
            attrString.replaceCharacters(in: match.range, with: boldStr)
        }

        // Italic: replace *text* with italic text (remove markers)
        let updatedRange = NSRange(location: 0, length: attrString.length)
        let italicMatches = Self.italicRegex.matches(in: attrString.string, range: updatedRange)
        for match in italicMatches.reversed() {
            let contentRange = match.range(at: 1)
            let content = (attrString.string as NSString).substring(with: contentRange)
            let italicStr = NSAttributedString(string: content, attributes: [
                .font: styles.italicFont,
                .foregroundColor: attrString.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) ?? NSColor.black,
                .paragraphStyle: attrString.attribute(.paragraphStyle, at: match.range.location, effectiveRange: nil) ?? NSMutableParagraphStyle()
            ])
            attrString.replaceCharacters(in: match.range, with: italicStr)
        }
    }
}
