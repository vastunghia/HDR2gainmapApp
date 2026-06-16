import SwiftUI
import AppKit

/// In-app Help: renders the bundled `README.md` natively (no WebKit). The document is the single
/// source of truth — it is copied into the app bundle at build time and parsed by
/// `HelpMarkdownParser`. Decorative HTML (hero banner, badges) is stripped by the parser.
struct HelpView: View {

    private let blocks: [HelpBlock]

    init() {
        if let url = Bundle.main.url(forResource: "README", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            blocks = HelpMarkdownParser.parse(text)
        } else {
            blocks = [.paragraph("Help content is unavailable.")]
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

/// Renders a single ``HelpBlock``. Recursive (a `<details>` disclosure contains nested blocks).
struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(HelpInline.attributed(text))
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 8 : 2)

        case let .paragraph(text):
            Text(HelpInline.attributed(text))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

        case let .bulleted(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(HelpInline.attributed(item))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .ordered(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(HelpInline.attributed(item))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .code(code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(HelpInline.attributed(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .image(file, alt):
            if let image = Self.bundledImage(file) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(alt)
            }
            // Unresolved images (remote badges, the app icon) render nothing.

        case .rule:
            Divider().padding(.vertical, 4)

        case let .disclosure(title, blocks):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        HelpBlockView(block: inner)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 4)
            } label: {
                Text(title).font(.headline)
            }
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle.weight(.bold)
        case 2: return .title.weight(.bold)
        case 3: return .title2.weight(.semibold)
        case 4: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    private static func bundledImage(_ file: String) -> NSImage? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(
            forResource: name, withExtension: ext, subdirectory: "screenshots"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Inline Markdown (**bold**, *italic*, `code`, [links](url)) → `AttributedString`.
/// Mirrors the inline-rendering approach already used in `TonemapHelpView`.
enum HelpInline {
    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnly)
        )) ?? AttributedString(s)
    }
}
