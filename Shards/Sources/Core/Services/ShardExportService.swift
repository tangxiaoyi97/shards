import AppKit
import Foundation

@MainActor
final class ShardExportService {
    static let shared = ShardExportService()

    private init() {}

    func exportPlainText(_ text: String, to destinationURL: URL) throws {
        try text.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    func exportPDF(text: String, title: String?, to destinationURL: URL) throws {
        let attributedString = styledDocument(text: text, title: title)
        let pageWidth: CGFloat = 760
        let horizontalPadding: CGFloat = 56
        let verticalPadding: CGFloat = 56
        let textWidth = pageWidth - horizontalPadding * 2

        let textContainer = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()
        let textStorage = NSTextStorage(attributedString: attributedString)
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let canvasSize = CGSize(
            width: pageWidth,
            height: max(usedRect.height + verticalPadding * 2, 840)
        )

        let exportView = NSView(frame: CGRect(origin: .zero, size: canvasSize))
        exportView.wantsLayer = true
        exportView.layer?.backgroundColor = NSColor.white.cgColor

        let previewTextView = NSTextView(frame: CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: textWidth,
            height: canvasSize.height - verticalPadding * 2
        ))
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = false
        previewTextView.textContainerInset = .zero
        previewTextView.textContainer?.lineFragmentPadding = 0
        previewTextView.textStorage?.setAttributedString(attributedString)
        previewTextView.sizeToFit()
        exportView.addSubview(previewTextView)

        let pdfData = exportView.dataWithPDF(inside: exportView.bounds)
        try pdfData.write(to: destinationURL, options: .atomic)
    }

    private func styledDocument(text: String, title: String?) -> NSAttributedString {
        let document = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 12

        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.paragraphSpacing = 18
            document.append(NSAttributedString(
                string: title + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 26, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: titleStyle
                ]
            ))
        }

        document.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        ))

        return document
    }
}
