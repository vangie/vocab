import SwiftUI
import VocabCore

/// Click-to-look-up reading: paste a passage, each word/character clickable to look up and add to wordbook.
/// Works for classical Chinese (per-character) as well as English (per-word).
struct ReadingView: View {
    @State private var text = ""
    @State private var selectedWord: String?
    @ObservedObject var lookup = LookupModel.shared
    @ObservedObject var book = WordbookModel.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if text.isEmpty {
                emptyState
            } else {
                ScrollView {
                    clickableText
                        .padding(20)
                }
            }
        }
        .onAppear { loadPasteboard() }
    }

    private var toolbar: some View {
        HStack {
            Text("阅读模式").font(.headline)
            Spacer()
            Button("粘贴") { loadPasteboard() }
                .keyboardShortcut("v", modifiers: .command)
            Button("清空") { text = "" }
        }
        .padding()
        .background(.background.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("粘贴文章，点击单词或汉字查词").foregroundStyle(.secondary)
            Text("⌘V 粘贴 · 点击查词 · 支持中英文").font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var clickableText: some View {
        let tokens = tokenize(text)
        return FlowLayout(spacing: 2) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if token.isWord {
                    Text(token.text)
                        .foregroundStyle(Color.primary)
                        .underline(color: .secondary.opacity(0.3))
                        .clickable(highlight: false, radius: 3) { _ in }
                        .onTapGesture { lookupWord(token.text) }
                } else {
                    Text(token.text).foregroundStyle(.secondary)
                }
            }
        }
        .font(.body)
    }

    private func loadPasteboard() {
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func lookupWord(_ word: String) {
        lookup.search(word)
    }

    /// Tokenize text into words (English/numbers) and non-words (punctuation, spaces).
    /// For CJK text, each character is a separate token (classical Chinese per-character lookup).
    private func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var isCurrentWord = false

        func flush() {
            if !current.isEmpty {
                tokens.append(Token(text: current, isWord: isCurrentWord))
                current = ""
            }
        }

        for char in s {
            let isCJK = ("" + String(char)).unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let isLetter = char.isLetter || char.isNumber
            let isWord = isCJK || isLetter

            if isCJK {
                flush()
                tokens.append(Token(text: String(char), isWord: true))
            } else if isWord != isCurrentWord {
                flush()
                current = String(char)
                isCurrentWord = isWord
            } else {
                current.append(char)
            }
        }
        flush()
        return tokens
    }

    struct Token {
        let text: String
        let isWord: Bool
    }
}

/// Simple flow layout for wrapping text tokens.
private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            self.generateContent(in: geo)
        }
    }

    private func generateContent(in g: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        return ZStack(alignment: .topLeading) {
            content().fixedSize()
                .alignmentGuide(.leading) { d in
                    if abs(width - d.width) > g.size.width {
                        width = 0
                        height -= d.height + spacing
                    }
                    let result = width
                    if d.width < g.size.width {
                        width = 0
                    } else {
                        width -= d.width + spacing
                    }
                    return result
                }
                .alignmentGuide(.top) { _ in
                    let result = height
                    if width == 0 {
                        height = 0
                    }
                    return result
                }
        }
        .frame(width: g.size.width, alignment: .topLeading)
    }
}
