import Foundation
import XCTest
@testable import HermesKit

/// The file half of the chat: what a name means, what a bot's workspace link is, and what the cache
/// is keyed by. The views are a source-scan test's business; the rules a row depends on are here.
final class OfficeAttachmentTests: XCTestCase {

    // MARK: Kinds

    func testTheThreeOfficeTypesAreNamedFromTheSuffix() {
        XCTAssertEqual(AttachmentKind(name: "quarterly.pdf"), .pdf)
        XCTAssertEqual(AttachmentKind(name: "brief.docx"), .word)
        XCTAssertEqual(AttachmentKind(name: "budget.xlsx"), .spreadsheet)
        XCTAssertEqual(AttachmentKind(name: "screenshot.PNG"), .image)
        XCTAssertEqual(AttachmentKind(name: "archive.zip"), .other)
        XCTAssertEqual(AttachmentKind(name: "no-extension"), .other)
    }

    func testTheOfficeExtensionsAreTheOnesThePickersOffer() {
        XCTAssertEqual(AttachmentKind.officeExtensions, ["pdf", "docx", "xlsx"])
    }

    func testEveryKindHasItsOwnSymbolAndNoTwoAreTheDocFallback() {
        let symbols = AttachmentKind.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertEqual(AttachmentKind.pdf.symbolName, "doc.richtext")
        XCTAssertEqual(AttachmentKind.spreadsheet.symbolName, "tablecells")
    }

    // MARK: A link in a message body

    func testARelativeWorkspacePathIsALink() {
        let link = WorkspaceFileLink(text: "/v1/workspace/cody/file?path=reports%2Fq3.xlsx")
        XCTAssertEqual(link?.profile, "cody")
        XCTAssertEqual(link?.path, "reports/q3.xlsx", "the query's path is percent-decoded once")
        XCTAssertEqual(link?.name, "q3.xlsx")
        XCTAssertNil(link?.size)
        XCTAssertEqual(link?.location,
                       AttachmentLocation.workspaceFile(profile: "cody", path: "reports/q3.xlsx"))
    }

    func testAnAbsoluteUrlIsALinkAndCarriesItsSize() {
        let link = WorkspaceFileLink(text: "https://casa.example.ts.net/v1/workspace/cody/file?path=out/report.pdf&size=2048")
        XCTAssertEqual(link?.profile, "cody")
        XCTAssertEqual(link?.path, "out/report.pdf")
        XCTAssertEqual(link?.size, 2048)
    }

    func testALinkCannotWalkOutOfTheWorkspace() {
        XCTAssertNil(WorkspaceFileLink(text: "/v1/workspace/cody/file?path=../../etc/passwd"))
        XCTAssertNil(WorkspaceFileLink(text: "/v1/workspace/cody/file?path=/etc/passwd"))
        XCTAssertNil(WorkspaceFileLink(text: "/v1/workspace/cody/files?path=a.pdf"), "the list route is not a file")
        XCTAssertNil(WorkspaceFileLink(text: "/v1/workspace/cody/file"), "no path, no file")
        XCTAssertNil(WorkspaceFileLink(text: "https://casa.example.ts.net/v1/update"))
    }

    func testAMarkdownLinkKeepsItsLabelAndBecomesARow() {
        let body = "The numbers are in [the report](https://casa/v1/workspace/cody/file?path=out%2Fq3.xlsx&size=4096). Anything else?"
        let scan = WorkspaceLinkScan.scan(body)
        XCTAssertEqual(scan.links.count, 1)
        XCTAssertEqual(scan.links.first?.name, "q3.xlsx")
        XCTAssertEqual(scan.prose, "The numbers are in the report. Anything else?")
    }

    func testABareUrlLeavesTheSentenceAndNoGap() {
        let body = "Done — here it is:\n\nhttps://casa/v1/workspace/cody/file?path=notes.pdf\n\nTell me if it reads right."
        let scan = WorkspaceLinkScan.scan(body)
        XCTAssertEqual(scan.links.map(\.name), ["notes.pdf"])
        XCTAssertEqual(scan.prose, "Done — here it is:\n\nTell me if it reads right.")
    }

    func testTwoLinksAreTwoRowsInOrder() {
        let body = "[a](https://casa/v1/workspace/cody/file?path=a.docx) and [b](https://casa/v1/workspace/cody/file?path=b.xlsx)"
        let scan = WorkspaceLinkScan.scan(body)
        XCTAssertEqual(scan.links.map(\.name), ["a.docx", "b.xlsx"])
        XCTAssertEqual(scan.prose, "a and b")
    }

    func testAProseWithoutLinksIsUntouched() {
        let body = "Nothing on disk. See `/v1/workspace/cody` for the list."
        let scan = WorkspaceLinkScan.scan(body)
        XCTAssertTrue(scan.links.isEmpty)
        XCTAssertEqual(scan.prose, body, "a list route in backticks is not a file link")
    }

    func testATrailingFullStopIsNotPartOfTheName() {
        let scan = WorkspaceLinkScan.scan("Read /v1/workspace/cody/file?path=notes.pdf.")
        XCTAssertEqual(scan.links.first?.name, "notes.pdf")
    }

    // MARK: The cache and the fetch

    func testAnUploadIsCachedUnderAKeyThatNamesItsProfile() {
        let location = AttachmentLocation.uploaded(profile: "cody", name: "report.pdf")
        XCTAssertEqual(location.displayName, "report.pdf", "the transcript quotes this name")
        XCTAssertTrue(location.cacheKey.hasPrefix("upload-"),
                      "the key is a fingerprint of profile + name")
        XCTAssertNotEqual(location.cacheKey, "report.pdf",
                          "a bare-name key let one profile answer another's file")
        XCTAssertNotEqual(location.cacheKey,
                          AttachmentLocation.uploaded(profile: "jason", name: "report.pdf").cacheKey)
        XCTAssertEqual(location.kind, .pdf)
    }

    func testAWorkspaceFileIsKeyedByItsPathAndKeepsItsSuffix() {
        let first = AttachmentLocation.workspaceFile(profile: "cody", path: "out/report.xlsx")
        let second = AttachmentLocation.workspaceFile(profile: "cody", path: "archive/report.xlsx")
        XCTAssertNotEqual(first.cacheKey, second.cacheKey,
                          "two folders may hold a file of the same name")
        XCTAssertTrue(first.cacheKey.hasSuffix(".xlsx"), "Quick Look reads the viewer from the suffix")
        XCTAssertEqual(first.cacheKey,
                       AttachmentLocation.workspaceFile(profile: "cody", path: "out/report.xlsx").cacheKey,
                       "stable between launches")
        XCTAssertEqual(first.displayName, "report.xlsx")
    }

    func testA404IsTheQuietNotReadyStateAndNothingElseIs() {
        XCTAssertTrue(AttachmentFetchError.notReady.isNotReady)
        XCTAssertTrue(AttachmentFetchError.refused(404).isNotReady)
        XCTAssertFalse(AttachmentFetchError.refused(500).isNotReady)
        XCTAssertFalse(AttachmentFetchError.notConfigured.isNotReady)
    }
}
