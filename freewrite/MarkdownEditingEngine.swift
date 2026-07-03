import AppKit

final class MarkdownEditingEngine {
    private enum DeleteDirection {
        case backward
        case forward
    }

    private struct ListLine {
        let lineRange: NSRange
        let indent: String
        let marker: String
        let continuationPrefix: String
        let content: String
        let numberRangeInLine: NSRange?

        var isOrdered: Bool {
            numberRangeInLine != nil
        }
    }

    private static let imageRegex = MarkdownTextStorage.imageRegex
    private static let boldSpanRegex = try! NSRegularExpression(pattern: "\\*\\*.*?\\*\\*", options: [.dotMatchesLineSeparators])
    private static let bulletLineRegex = try! NSRegularExpression(pattern: "^(\\s*)([-*•])\\s+((?:\\[[ xX]\\]\\s+)?)(.*)$", options: [])
    private static let numberedLineRegex = try! NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s+(.*)$", options: [])

    private var isPerformingAtomicDeletion = false
    private var isRenumbering = false

    func shouldAllowChange(in textView: NSTextView, range: NSRange, replacement: String) -> Bool {
        if isPerformingAtomicDeletion || isRenumbering {
            return true
        }

        if replacement.isEmpty,
           range.length > 0,
           let imageRange = imageMarkdownRange(intersecting: range, in: textView.string) {
            atomicEdit(in: textView, actionName: "Delete Image") {
                textView.insertText("", replacementRange: expandedImageDeletionRange(imageRange, in: textView.string))
            }
            return false
        }

        if range.length > 0,
           replaceBoldSelectionTouchingHiddenSyntax(in: textView, range: range, replacement: replacement) {
            return false
        }

        if replacement.isEmpty,
           range.length > 0,
           deleteBoldSpanIfDeletingLastVisibleCharacter(in: textView, deletionRange: range) {
            return false
        }

        if replacement == " ",
           range.length == 0,
           convertAsteriskListMarker(in: textView, at: range.location) {
            return false
        }

        return true
    }

    func handleCommand(_ commandSelector: Selector, in textView: NSTextView) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if handleInlineMarkerEscape(in: textView) {
                return true
            }
            if handleListContinuation(in: textView) {
                return true
            }
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return indentSelectedListLines(in: textView, outdent: false)
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return indentSelectedListLines(in: textView, outdent: true)
        }

        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            if deleteImageMarkdown(in: textView, direction: .backward) {
                return true
            }
        }

        if commandSelector == #selector(NSResponder.deleteForward(_:)) {
            if deleteImageMarkdown(in: textView, direction: .forward) {
                return true
            }
        }

        return false
    }

    func toggleBold(in textView: NSTextView) {
        let selectedRange = textView.selectedRange()
        let text = textView.string as NSString

        atomicEdit(in: textView, actionName: "Bold") {
            if selectedRange.length > 0 {
                let targetRange = inlineFormattingTargetRange(from: selectedRange, in: text)
                guard targetRange.length > 0 else { return }

                let selectedText = text.substring(with: targetRange)
                if selectedText.hasPrefix("**") && selectedText.hasSuffix("**") && selectedText.count > 4 {
                    let inner = String(selectedText.dropFirst(2).dropLast(2))
                    textView.insertText(inner, replacementRange: targetRange)
                    setInsertionPoint(in: textView, at: targetRange.location + (inner as NSString).length)
                } else if targetRange.location >= 2,
                          targetRange.upperBound + 2 <= text.length,
                          text.substring(with: NSRange(location: targetRange.location - 2, length: 2)) == "**",
                          text.substring(with: NSRange(location: targetRange.upperBound, length: 2)) == "**" {
                    let outerRange = NSRange(location: targetRange.location - 2, length: targetRange.length + 4)
                    let inner = text.substring(with: targetRange)
                    textView.insertText(inner, replacementRange: outerRange)
                    setInsertionPoint(in: textView, at: outerRange.location + (inner as NSString).length)
                } else {
                    let wrapped = "**\(selectedText)**"
                    textView.insertText(wrapped, replacementRange: targetRange)
                    setInsertionPoint(in: textView, at: targetRange.location + (wrapped as NSString).length)
                }
            } else {
                let location = selectedRange.location
                textView.insertText("****", replacementRange: selectedRange)
                textView.setSelectedRange(NSRange(location: location + 2, length: 0))
            }
        }
    }

    func normalizeOrderedListsIfNeeded(in textView: NSTextView) {
        guard !isRenumbering else { return }

        let selectedRange = textView.selectedRange()
        let replacements = orderedListNumberReplacements(in: textView.string)
        guard !replacements.isEmpty else { return }

        isRenumbering = true
        textView.undoManager?.beginUndoGrouping()
        textView.undoManager?.setActionName("Renumber List")
        for replacement in replacements.reversed() {
            textView.insertText(replacement.number, replacementRange: replacement.range)
        }
        textView.setSelectedRange(adjustedRange(selectedRange, after: replacements))
        textView.undoManager?.endUndoGrouping()
        isRenumbering = false
    }

    private func atomicEdit(in textView: NSTextView, actionName: String, perform edit: () -> Void) {
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(actionName)
        edit()
        undoManager?.endUndoGrouping()
    }

    private func deleteImageMarkdown(in textView: NSTextView, direction: DeleteDirection) -> Bool {
        let selectedRange = textView.selectedRange()
        let candidateRange: NSRange

        if selectedRange.length > 0 {
            candidateRange = selectedRange
        } else {
            let location = selectedRange.location
            switch direction {
            case .backward:
                candidateRange = NSRange(location: max(0, location - 1), length: location > 0 ? 1 : 0)
            case .forward:
                candidateRange = NSRange(location: location, length: location < (textView.string as NSString).length ? 1 : 0)
            }
        }

        guard let imageRange = imageMarkdownRange(intersecting: candidateRange, in: textView.string)
            ?? adjacentImageMarkdownRange(from: selectedRange.location, direction: direction, in: textView.string) else {
            return false
        }

        atomicEdit(in: textView, actionName: "Delete Image") {
            isPerformingAtomicDeletion = true
            textView.insertText("", replacementRange: expandedImageDeletionRange(imageRange, in: textView.string))
            isPerformingAtomicDeletion = false
        }
        return true
    }

    private func deleteBoldSpanIfDeletingLastVisibleCharacter(in textView: NSTextView, deletionRange: NSRange) -> Bool {
        guard let spanRange = boldSpanRange(containingVisibleCharactersIn: deletionRange, in: textView.string) else {
            return false
        }

        atomicEdit(in: textView, actionName: "Delete Bold Text") {
            isPerformingAtomicDeletion = true
            textView.insertText("", replacementRange: spanRange)
            isPerformingAtomicDeletion = false
        }
        return true
    }

    private func boldSpanRange(containingVisibleCharactersIn deletionRange: NSRange, in string: String) -> NSRange? {
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        return Self.boldSpanRegex
            .matches(in: string, range: fullRange)
            .first { match in
                guard match.range.length >= 4 else { return false }

                let contentRange = NSRange(location: match.range.location + 2, length: match.range.length - 4)
                let overlap = NSIntersectionRange(contentRange, deletionRange)
                guard overlap.length > 0,
                      deletionRange.location >= contentRange.location,
                      deletionRange.upperBound <= contentRange.upperBound else { return false }

                return overlap.length >= contentRange.length
            }?
            .range
    }

    private func replaceBoldSelectionTouchingHiddenSyntax(in textView: NSTextView, range: NSRange, replacement: String) -> Bool {
        let string = textView.string
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        guard let match = Self.boldSpanRegex.matches(in: string, range: fullRange).first(where: { match in
            guard match.range.length >= 4,
                  range.location >= match.range.location,
                  range.upperBound <= match.range.upperBound else { return false }

            let openRange = NSRange(location: match.range.location, length: 2)
            let closeRange = NSRange(location: match.range.upperBound - 2, length: 2)
            let contentRange = NSRange(location: match.range.location + 2, length: match.range.length - 4)
            let touchesHiddenSyntax = NSIntersectionRange(openRange, range).length > 0
                || NSIntersectionRange(closeRange, range).length > 0
            let touchesVisibleContent = NSIntersectionRange(contentRange, range).length > 0

            return touchesHiddenSyntax && touchesVisibleContent
        }) else {
            return false
        }

        let contentRange = NSRange(location: match.range.location + 2, length: match.range.length - 4)
        let selectedContentRange = NSIntersectionRange(contentRange, range)
        guard selectedContentRange.length > 0 else { return false }

        let beforeRange = NSRange(
            location: contentRange.location,
            length: selectedContentRange.location - contentRange.location
        )
        let afterRange = NSRange(
            location: selectedContentRange.upperBound,
            length: contentRange.upperBound - selectedContentRange.upperBound
        )

        let before = nsString.substring(with: beforeRange)
        let after = nsString.substring(with: afterRange)
        let newContent = "\(before)\(replacement)\(after)"
        let replacementText = newContent.isEmpty ? "" : "**\(newContent)**"
        let caretLocation = newContent.isEmpty
            ? match.range.location
            : match.range.location + 2 + (before as NSString).length + (replacement as NSString).length

        atomicEdit(in: textView, actionName: replacement.isEmpty ? "Delete Bold Text" : "Replace Bold Text") {
            isPerformingAtomicDeletion = true
            textView.insertText(replacementText, replacementRange: match.range)
            textView.setSelectedRange(NSRange(location: caretLocation, length: 0))
            textView.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: match.range.location, length: (replacementText as NSString).length))
            isPerformingAtomicDeletion = false
        }

        return true
    }

    private func imageMarkdownRange(intersecting range: NSRange, in string: String) -> NSRange? {
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        return Self.imageRegex
            .matches(in: string, range: fullRange)
            .first { NSIntersectionRange($0.range, range).length > 0 }
            .map(\.range)
    }

    private func adjacentImageMarkdownRange(from location: Int, direction: DeleteDirection, in string: String) -> NSRange? {
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = Self.imageRegex.matches(in: string, range: fullRange)

        switch direction {
        case .backward:
            return matches.last { match in
                match.range.upperBound <= location
                    && nsString.substring(with: NSRange(location: match.range.upperBound, length: location - match.range.upperBound))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            }?.range
        case .forward:
            return matches.first { match in
                match.range.location >= location
                    && nsString.substring(with: NSRange(location: location, length: match.range.location - location))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            }?.range
        }
    }

    private func expandedImageDeletionRange(_ range: NSRange, in string: String) -> NSRange {
        let nsString = string as NSString
        var location = range.location
        var upperBound = range.upperBound

        while location > 0 {
            let previous = nsString.substring(with: NSRange(location: location - 1, length: 1))
            if previous == "\n" {
                location -= 1
            } else {
                break
            }
        }

        while upperBound < nsString.length {
            let next = nsString.substring(with: NSRange(location: upperBound, length: 1))
            if next == "\n" {
                upperBound += 1
            } else {
                break
            }
        }

        return NSRange(location: location, length: upperBound - location)
    }

    private func convertAsteriskListMarker(in textView: NSTextView, at location: Int) -> Bool {
        let text = textView.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        let textBeforeSpace = text.substring(with: NSRange(location: lineRange.location, length: location - lineRange.location))

        guard let asteriskIndex = textBeforeSpace.lastIndex(of: "*"),
              textBeforeSpace[..<asteriskIndex].allSatisfy({ $0.isWhitespace }),
              textBeforeSpace[textBeforeSpace.index(after: asteriskIndex)...].isEmpty else {
            return false
        }

        let indent = String(textBeforeSpace[..<asteriskIndex])
        let replacementRange = NSRange(location: lineRange.location, length: location - lineRange.location)
        atomicEdit(in: textView, actionName: "Bullet List") {
            textView.insertText("\(indent)• ", replacementRange: replacementRange)
        }
        return true
    }

    private func handleInlineMarkerEscape(in textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location

        if cursor + 2 <= text.length,
           text.substring(with: NSRange(location: cursor, length: 2)) == "**" {
            atomicEdit(in: textView, actionName: "New Line") {
                textView.setSelectedRange(NSRange(location: cursor + 2, length: 0))
                textView.insertText("\n", replacementRange: textView.selectedRange())
            }
            return true
        }

        if cursor + 1 <= text.length,
           text.substring(with: NSRange(location: cursor, length: 1)) == "*" {
            atomicEdit(in: textView, actionName: "New Line") {
                textView.setSelectedRange(NSRange(location: cursor + 1, length: 0))
                textView.insertText("\n", replacementRange: textView.selectedRange())
            }
            return true
        }

        return false
    }

    private func handleListContinuation(in textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        let cursorLocation = textView.selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: cursorLocation, length: 0))
        guard let listLine = parseListLine(in: text, lineRange: lineRange) else {
            return false
        }

        if listLine.content.trimmingCharacters(in: .whitespaces).isEmpty {
            atomicEdit(in: textView, actionName: "Exit List") {
                textView.insertText("\n", replacementRange: lineRange)
                normalizeOrderedListsIfNeeded(in: textView)
            }
            return true
        }

        atomicEdit(in: textView, actionName: "Continue List") {
            if listLine.isOrdered,
               let currentNumber = Int(listLine.marker.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                textView.insertText("\n\(listLine.indent)\(currentNumber + 1). ", replacementRange: textView.selectedRange())
                normalizeOrderedListsIfNeeded(in: textView)
            } else {
                let nextMarker = listLine.marker == "*" ? "•" : listLine.marker
                textView.insertText("\n\(listLine.indent)\(nextMarker) \(listLine.continuationPrefix)", replacementRange: textView.selectedRange())
            }
        }
        return true
    }

    private func indentSelectedListLines(in textView: NSTextView, outdent: Bool) -> Bool {
        let text = textView.string as NSString
        let selectedRange = textView.selectedRange()
        let selectedLineRanges = lineRanges(intersecting: selectedRange, in: text)
        var replacements: [(range: NSRange, text: String)] = []

        for lineRange in selectedLineRanges {
            guard let listLine = parseListLine(in: text, lineRange: lineRange) else {
                continue
            }

            if outdent {
                guard listLine.indent.count >= 4 else { continue }
                replacements.append((range: NSRange(location: lineRange.location, length: 4), text: ""))
            } else {
                replacements.append((range: NSRange(location: lineRange.location, length: 0), text: "    "))
            }
        }

        guard !replacements.isEmpty else { return false }

        atomicEdit(in: textView, actionName: outdent ? "Outdent List" : "Indent List") {
            for replacement in replacements.reversed() {
                textView.insertText(replacement.text, replacementRange: replacement.range)
            }
            let deltaPerLine = outdent ? -4 : 4
            let delta = deltaPerLine * replacements.count
            let newLocation = max(0, selectedRange.location + (outdent ? min(0, deltaPerLine) : 4))
            textView.setSelectedRange(NSRange(location: newLocation, length: max(0, selectedRange.length + delta)))
            normalizeOrderedListsIfNeeded(in: textView)
        }

        return true
    }

    private func orderedListNumberReplacements(in string: String) -> [(range: NSRange, number: String)] {
        let text = string as NSString
        var replacements: [(range: NSRange, number: String)] = []
        var orderedCounters: [String: Int] = [:]

        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            guard let listLine = self.parseListLine(in: text, lineRange: lineRange),
                  listLine.isOrdered,
                  let numberRangeInLine = listLine.numberRangeInLine else {
                orderedCounters.removeAll()
                return
            }

            orderedCounters = orderedCounters.filter { key, _ in
                key.count <= listLine.indent.count
            }

            let expectedNumber = (orderedCounters[listLine.indent] ?? 0) + 1
            orderedCounters[listLine.indent] = expectedNumber

            let currentNumber = text.substring(with: NSRange(
                location: lineRange.location + numberRangeInLine.location,
                length: numberRangeInLine.length
            ))

            if currentNumber != "\(expectedNumber)" {
                replacements.append((
                    range: NSRange(location: lineRange.location + numberRangeInLine.location, length: numberRangeInLine.length),
                    number: "\(expectedNumber)"
                ))
            }
        }

        return replacements
    }

    private func parseListLine(in text: NSString, lineRange: NSRange) -> ListLine? {
        let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let lineNSString = line as NSString
        let matchRange = NSRange(location: 0, length: lineNSString.length)

        if let bulletMatch = Self.bulletLineRegex.firstMatch(in: line, range: matchRange) {
            return ListLine(
                lineRange: lineRange,
                indent: lineNSString.substring(with: bulletMatch.range(at: 1)),
                marker: lineNSString.substring(with: bulletMatch.range(at: 2)),
                continuationPrefix: lineNSString.substring(with: bulletMatch.range(at: 3)),
                content: lineNSString.substring(with: bulletMatch.range(at: 4)),
                numberRangeInLine: nil
            )
        }

        guard let numberedMatch = Self.numberedLineRegex.firstMatch(in: line, range: matchRange) else {
            return nil
        }

        let number = lineNSString.substring(with: numberedMatch.range(at: 2))
        return ListLine(
            lineRange: lineRange,
            indent: lineNSString.substring(with: numberedMatch.range(at: 1)),
            marker: "\(number).",
            continuationPrefix: "",
            content: lineNSString.substring(with: numberedMatch.range(at: 3)),
            numberRangeInLine: numberedMatch.range(at: 2)
        )
    }

    private func lineRanges(intersecting selectedRange: NSRange, in text: NSString) -> [NSRange] {
        let targetRange: NSRange
        if selectedRange.length == 0 {
            targetRange = text.lineRange(for: selectedRange)
        } else {
            targetRange = text.lineRange(for: selectedRange)
        }

        var ranges: [NSRange] = []
        var location = targetRange.location
        while location < targetRange.upperBound {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            ranges.append(lineRange)
            location = lineRange.upperBound
        }
        return ranges
    }

    private func inlineFormattingTargetRange(from selectedRange: NSRange, in text: NSString) -> NSRange {
        var location = selectedRange.location
        var length = selectedRange.length

        while length > 0 {
            let character = text.substring(with: NSRange(location: location, length: 1))
            if character == "\n" || character == "\r" {
                location += 1
                length -= 1
            } else {
                break
            }
        }

        while length > 0 {
            let character = text.substring(with: NSRange(location: location + length - 1, length: 1))
            if character == "\n" || character == "\r" {
                length -= 1
            } else {
                break
            }
        }

        return NSRange(location: location, length: length)
    }

    private func adjustedRange(_ selectedRange: NSRange, after replacements: [(range: NSRange, number: String)]) -> NSRange {
        var location = selectedRange.location
        var length = selectedRange.length

        for replacement in replacements {
            let delta = (replacement.number as NSString).length - replacement.range.length
            if replacement.range.location < location {
                location += delta
            } else if replacement.range.location < selectedRange.upperBound {
                length += delta
            }
        }

        return NSRange(location: max(0, location), length: max(0, length))
    }

    private func setInsertionPoint(in textView: NSTextView, at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
    }
}
