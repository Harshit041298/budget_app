import SwiftUI
import SwiftData
import PhotosUI
import VisionKit
import UniformTypeIdentifiers
import BillCore

struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(ImportService.self) private var importer
    @State private var showFiles = false
    @State private var showScanner = false
    @State private var photoItems: [PhotosPickerItem] = []

    private static let fileTypes: [UTType] = [
        .pdf, .commaSeparatedText, .plainText, .image, .jpeg, .png, .heic,
        UTType(filenameExtension: "csv") ?? .commaSeparatedText
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showFiles = true } label: {
                        ImportOption(title: "Files (PDF, CSV, images)",
                                     subtitle: "CIBC e-statements, CIBC CSV downloads, Amazon order history",
                                     systemImage: "folder.fill", color: .blue)
                    }
                    if VNDocumentCameraViewController.isSupported {
                        Button { showScanner = true } label: {
                            ImportOption(title: "Scan paper bill or receipt",
                                         subtitle: "Uses the camera + on-device text recognition",
                                         systemImage: "doc.viewfinder.fill", color: .orange)
                        }
                    }
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .images) {
                        ImportOption(title: "Photos & screenshots",
                                     subtitle: "Screenshots of bills, e-receipts or order confirmations",
                                     systemImage: "photo.on.rectangle.angled", color: .green)
                    }
                } header: {
                    Text("Add documents")
                } footer: {
                    Text("Everything is processed on this iPhone. Nothing is uploaded.")
                }
                .disabled(importer.isImporting)

                if importer.isImporting {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(importer.status).font(.subheadline)
                        }
                    }
                }

                if !importer.summaries.isEmpty {
                    Section("Recent imports") {
                        ForEach(importer.summaries) { s in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(s.filename).bold().lineLimit(1)
                                    if s.usedAI { Image(systemName: "sparkles").foregroundStyle(.purple) }
                                }
                                Text("\(s.kind.displayName) · \(s.added) added" +
                                     (s.duplicates > 0 ? " · \(s.duplicates) duplicates skipped" : "") +
                                     (s.linkedOrders > 0 ? " · \(s.linkedOrders) Amazon orders matched" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(s.warnings, id: \.self) { w in
                                    Label(w, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }

                Section("Where to get your data") {
                    DisclosureGroup("CIBC transactions (most accurate)") {
                        Text("""
                        1. Sign in to CIBC Online Banking on a browser.
                        2. Open an account → "Download transactions".
                        3. Choose a date range and the "Spreadsheet (CSV)" format.
                        4. Save to Files, then import here. Repeat for each account/card.
                        """).font(.footnote)
                    }
                    DisclosureGroup("CIBC PDF statements") {
                        Text("""
                        In the CIBC app: Accounts → pick an account → "Statements" (eStatements). \
                        Open a statement, tap Share → "Bill Insights" or Save to Files. \
                        Credit card and chequing statements are both supported.
                        """).font(.footnote)
                    }
                    DisclosureGroup("Amazon purchases") {
                        Text("""
                        To see *what* you bought (not just "AMAZON.CA $84.17"):
                        1. On amazon.ca go to Account → "Request Your Data" and request "Your Orders".
                        2. Amazon emails a zip; open it in Files and import Retail.OrderHistory.1.csv.
                        Orders are matched to your card charges automatically. Screenshots of order \
                        pages also work, using the on-device AI.
                        """).font(.footnote)
                    }
                    DisclosureGroup("Other bills") {
                        Text("Phone, internet, hydro and other bills can be imported as PDFs, screenshots or camera scans.")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Import")
            .fileImporter(isPresented: $showFiles, allowedContentTypes: Self.fileTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await importer.importFiles(urls, context: context) }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    let name = "Scan \(Date().formatted(date: .abbreviated, time: .shortened))"
                    Task { await importer.importImages(images, name: name, context: context) }
                } onCancel: {
                    showScanner = false
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for (i, item) in items.enumerated() {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                            await importer.importImages([image], name: "Photo \(i + 1) \(Date().formatted(date: .abbreviated, time: .omitted))",
                                                        context: context)
                        }
                    }
                    photoItems = []
                }
            }
        }
    }
}

private struct ImportOption: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// VisionKit's document camera (auto edge detection, perspective correction).
struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onScan(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}
