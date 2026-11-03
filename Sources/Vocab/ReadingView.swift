import SwiftUI
import VocabCore

/// Click-to-look-up reading: paste a passage, each word/character clickable to look up and add to wordbook.
/// Works for classical Chinese (per-character) as well as English (per-word).
struct ReadingView: View {
    let text: String
    var onExit: (() -> Void)?
    @ObservedObject var lookup = LookupModel.shared
    @ObservedObject var book = WordbookModel.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView { clickableText.padding(20) }
        }
    }

    private var toolbar: some View {
        HStack {
            Text("阅读模式").font(.headline)
            Spacer()
            Button("返回查词") { onExit?() }.handCursor()
        }
        .padding()
        .background(.background.secondary)
    }

    private var clickableText: some View {
        let tokens = tokenize(text)
        return FlowLayout(spacing: 2) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if token.isWord {
                    Text(token.text)
                        .foregroundStyle(Color.primary)
                        .underline(color: .secondary.opacity(0.3))
                        .onTapGesture { lookupWord(token.text) }
                        .clickable(highlight: false, radius: 3)
                } else {
                    Text(token.text).foregroundStyle(.secondary)
                }
            }
        }
        .font(.body)
    }

    private func lookupWord(_ word: String) {
        lookup.lookUpFromReading(word)
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
            let isCJK = char.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
            let isLetter = char.isLetter || char.isNumber || ((char == "'" || char == "’" || char == "-") && isCurrentWord)
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
