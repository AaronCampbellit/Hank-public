import XCTest
@testable import Hank

final class FilePreviewClassifierTests: XCTestCase {
    func testClassifiesTextImageAndPDFFormats() {
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "readme.md"), .text)
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "photo.heic"), .image)
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "document.pdf"), .pdf)
    }

    func testClassifiesCommonMediaAndDocumentFormatsForQuickLook() {
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "clip.mp4"), .quickLookFile)
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "recording.m4a"), .quickLookFile)
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "report.docx"), .quickLookFile)
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "slides.pptx"), .quickLookFile)
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "sheet.xlsx"), .quickLookFile)
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "ebook.epub"), .quickLookFile)
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "archive.zip"), .quickLookFile)
    }

    func testLeavesUnknownFormatsUnsupported() {
        XCTAssertEqual(FilePreviewClassifier.classify(fileName: "firmware.bin"), .unsupported)
    }
}
