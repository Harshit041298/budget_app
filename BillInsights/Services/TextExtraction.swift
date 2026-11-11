import Foundation
import PDFKit
import Vision
import UIKit

/// Gets text out of PDFs and images, entirely on-device.
enum TextExtraction {
    enum Failure: LocalizedError {
        case unreadablePDF
        case noText
        var errorDescription: String? {
            switch self {
            case .unreadablePDF: return "The PDF couldn't be opened (is it password protected?)."
            case .noText: return "No text could be found in this document."
            }
        }
    }

    /// Uses the PDF's embedded text (CIBC e-statements have it); falls back to
    /// OCR for scanned pages.
    static func text(fromPDF url: URL) async throws -> String {
        guard let doc = PDFDocument(url: url) else { throw Failure.unreadablePDF }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if embedded.count > 40 {
                pages.append(embedded)
            } else {
                let image = render(page: page)
                pages.append(try await ocr(image))
            }
        }
        let text = pages.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noText }
        return text
    }

    static func render(page: PDFPage, scale: CGFloat = 2.5) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    /// Apple Vision OCR. Observations are regrouped into visual lines so that
    /// a description and its amount on the far right end up on one line.
    static func ocr(_ image: UIImage) async throws -> String {
        guard let cg = image.cgImage else { throw Failure.noText }
        let orientation = cgOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-CA", "en-US", "fr-CA"]
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
            try handler.perform([request])
            let observations = request.results ?? []
            return TextExtraction.groupIntoLines(observations.compactMap { obs in
                obs.topCandidates(1).first.map { (text: $0.string, box: obs.boundingBox) }
            })
        }.value
    }

    static func ocr(images: [UIImage]) async throws -> String {
        var parts: [String] = []
        for image in images { parts.append(try await ocr(image)) }
        return parts.joined(separator: "\n")
    }

    /// Vision's boxes use normalised coordinates with origin bottom-left.
    static func groupIntoLines(_ items: [(text: String, box: CGRect)]) -> String {
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(text: String, box: CGRect)]] = []
        for item in sorted {
            if let lastIndex = lines.indices.last,
               let ref = lines[lastIndex].first,
               abs(ref.box.midY - item.box.midY) < max(ref.box.height, item.box.height) * 0.6 {
                lines[lastIndex].append(item)
            } else {
                lines.append([item])
            }
        }
        return lines.map { line in
            line.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ")
        }.joined(separator: "\n")
    }

    static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
