import Foundation

/// A parsed block of the in-app Help document (a small, README-tailored Markdown subset).
/// The parser is intentionally line-based and handles only what `README.md` actually uses:
/// headings, paragraphs, lists, fenced code, blockquotes, images, horizontal rules and
/// `<details>` disclosure sections. Decorative HTML (the hero banner, shields.io badges,
/// the download button) is stripped.
enum HelpBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulleted([String])
    case ordered([String])
    case code(String)
    case quote(String)
    case image(file: String, alt: String)
    case rule
    case disclosure(title: String, blocks: [HelpBlock])
}

/// Line-based Markdown → `[HelpBlock]` parser scoped to the project README.
enum HelpMarkdownParser {

    static func parse(_ markdown: String) -> [HelpBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0
        return parseBlocks(lines, &index, stopAtDetailsClose: false)
    }

    /// Parses blocks starting at `index`. When `stopAtDetailsClose` is true (i.e. we are inside a
    /// `<details>` element) it returns as soon as it consumes the matching `</details>`.
    private static func parseBlocks(
        _ lines: [String],
        _ index: inout Int,
        stopAtDetailsClose: Bool
    ) -> [HelpBlock] {
        var blocks: [HelpBlock] = []

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // End of a <details> section.
            if stopAtDetailsClose, line.caseInsensitiveEquals("</details>") {
                index += 1
                return blocks
            }

            // Blank line: paragraph separator.
            if line.isEmpty {
                index += 1
                continue
            }

            // <details> … <summary>Title</summary> … </details>
            if line.lowercased().hasPrefix("<details") {
                index += 1
                let title = consumeSummary(lines, &index)
                let inner = parseBlocks(lines, &index, stopAtDetailsClose: true)
                blocks.append(.disclosure(title: title, blocks: inner))
                continue
            }

            // Decorative / structural HTML lines we don't render.
            if isStrippableHTML(line) {
                index += 1
                continue
            }

            // Fenced code block.
            if line.hasPrefix("```") {
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 } // closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // Horizontal rule.
            if line == "---" || line == "***" || line == "___" {
                blocks.append(.rule)
                index += 1
                continue
            }

            // Heading.
            if let heading = parseHeading(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            // Standalone markdown image: ![alt](path)
            if let image = parseImage(line) {
                blocks.append(image)
                index += 1
                continue
            }

            // Blockquote (collect consecutive `>` lines).
            if line.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    quote.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }

            // Ordered list (collect consecutive `N.` lines).
            if isOrderedItem(line) {
                var items: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isOrderedItem(l) else { break }
                    items.append(stripOrderedMarker(l))
                    index += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            // Bulleted list (collect consecutive `-`/`*`/`+`/`•` lines).
            if isBulletItem(line) {
                var items: [String] = []
                while index < lines.count {
                    let l = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isBulletItem(l) else { break }
                    items.append(stripBulletMarker(l))
                    index += 1
                }
                blocks.append(.bulleted(items))
                continue
            }

            // Paragraph: gather consecutive plain lines.
            var paragraph: [String] = []
            while index < lines.count {
                let l = lines[index].trimmingCharacters(in: .whitespaces)
                if l.isEmpty || l.hasPrefix("#") || l.hasPrefix(">") || l.hasPrefix("```")
                    || l.hasPrefix("<") || isBulletItem(l) || isOrderedItem(l)
                    || l == "---" || parseImage(l) != nil {
                    break
                }
                paragraph.append(l)
                index += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
            } else {
                // Safety net: the current line was none of the recognised block kinds *and* the
                // paragraph collector took nothing (e.g. a stray `<tag>` line not covered by
                // `isStrippableHTML`). Skip it so `index` always advances — otherwise the outer
                // `while` would spin forever and hang the app.
                index += 1
            }
        }

        return blocks
    }

    // MARK: - Line classifiers

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, decodeEntities(text))
    }

    private static func parseImage(_ line: String) -> HelpBlock? {
        // ![alt](path)  — only treat a line that is *only* an image.
        guard line.hasPrefix("!["), let bang = line.range(of: "]("), line.hasSuffix(")") else {
            return nil
        }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<bang.lowerBound])
        let path = String(line[bang.upperBound..<line.index(before: line.endIndex)])
        let file = (path as NSString).lastPathComponent
        return .image(file: file, alt: decodeEntities(alt))
    }

    private static func isBulletItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line.hasPrefix("• ")
    }

    private static func stripBulletMarker(_ line: String) -> String {
        decodeEntities(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        guard let dot = line.firstIndex(of: ".") else { return false }
        let prefix = line[line.startIndex..<dot]
        return !prefix.isEmpty && prefix.allSatisfy(\.isNumber)
            && line.index(after: dot) < line.endIndex
            && line[line.index(after: dot)] == " "
    }

    private static func stripOrderedMarker(_ line: String) -> String {
        guard let dot = line.firstIndex(of: ".") else { return line }
        return decodeEntities(String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
    }

    /// Decorative or structural HTML lines we drop (hero banner, badges, download button).
    private static func isStrippableHTML(_ line: String) -> Bool {
        let l = line.lowercased()
        let tags = [
            "<p", "</p", "<img", "<h1", "<a ", "</a", "<div", "</div", "<br",
            "<picture", "</picture", "<source",
            // Decorative inline-formatting / structural tags used in the README hero banner.
            "<b>", "</b", "<i>", "</i", "<em", "</em", "<strong", "</strong",
            "<sub", "</sub", "<sup", "</sup", "<kbd", "</kbd", "<center", "</center",
            "<span", "</span", "<hr", "<!--",
        ]
        for tag in tags {
            if l.hasPrefix(tag) { return true }
        }
        return false
    }

    private static func consumeSummary(_ lines: [String], _ index: inout Int) -> String {
        while index < lines.count {
            let l = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if let open = l.range(of: "<summary>", options: .caseInsensitive),
               let close = l.range(of: "</summary>", options: .caseInsensitive) {
                let inner = String(l[open.upperBound..<close.lowerBound])
                return decodeEntities(stripInlineTags(inner)).trimmingCharacters(in: .whitespaces)
            }
            if l.isEmpty { continue }
            // A non-summary line: stop consuming (no summary present).
            index -= 1
            break
        }
        return "Details"
    }

    private static func stripInlineTags(_ s: String) -> String {
        var result = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { result.append(ch) }
        }
        return result
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

private extension String {
    func caseInsensitiveEquals(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}
