import SwiftUI

enum SlashBlockType: String, CaseIterable, Identifiable {
    case heading1 = "Heading 1"
    case heading2 = "Heading 2"
    case heading3 = "Heading 3"
    case bulletList = "Bullet List"
    case numberedList = "Numbered List"
    case quote = "Quote"
    case divider = "Divider"
    case photo = "Photo"
    case todo = "Todo"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .heading1: return "textformat.size.larger"
        case .heading2: return "textformat.size"
        case .heading3: return "textformat.size.smaller"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .quote: return "text.quote"
        case .divider: return "minus"
        case .photo: return "photo"
        case .todo: return "checklist"
        }
    }

    var markdownPrefix: String {
        switch self {
        case .heading1: return "# "
        case .heading2: return "## "
        case .heading3: return "### "
        case .bulletList: return "- "
        case .numberedList: return "1. "
        case .quote: return "> "
        case .divider: return "---\n"
        case .photo: return ""
        case .todo: return "- [ ] "
        }
    }

    static func filtered(by text: String) -> [SlashBlockType] {
        if text.isEmpty { return allCases }
        let lower = text.lowercased()
        return allCases.filter { $0.rawValue.lowercased().contains(lower) }
    }
}

struct SlashCommandMenu: View {
    let filterText: String
    let selectedIndex: Int
    let colorScheme: ColorScheme
    let onSelect: (SlashBlockType) -> Void

    @State private var hoveredIndex: Int? = nil

    private var filteredItems: [SlashBlockType] {
        SlashBlockType.filtered(by: filterText)
    }

    var body: some View {
        let items = filteredItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button(action: { onSelect(item) }) {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .frame(width: 20)
                                .foregroundColor(itemTextColor)
                            Text(item.rawValue)
                                .foregroundColor(itemTextColor)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(itemBackground(at: index))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredIndex = hovering ? index : nil
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .frame(width: 200)
            .background(colorScheme == .light ? Color(NSColor.controlBackgroundColor) : Color(NSColor.darkGray))
            .cornerRadius(8)
            .shadow(color: Color.black.opacity(0.15), radius: 8, y: 4)
            .onChange(of: selectedIndex) { _, _ in
                hoveredIndex = nil
            }
        }
    }

    private func itemBackground(at index: Int) -> Color {
        if index == hoveredIndex || (hoveredIndex == nil && index == selectedIndex) {
            return colorScheme == .light ? Color.gray.opacity(0.12) : Color.white.opacity(0.1)
        }
        return .clear
    }

    private var itemTextColor: Color {
        colorScheme == .light ? Color.primary : Color.white
    }
}
