import Foundation
import Testing
@testable import I20Core

func makeTempBook() throws -> (Book, URL) {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "i20test-\(UUID().uuidString)")
    let root = tmp.appending(path: "i20_book")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (Book(root: root), tmp)
}

@Suite struct BookTests {
    @Test func writeReadRoundTrip() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = Data("hello".utf8)
        try book.writeAtomic("log/refuels/a.json", data)
        #expect(try book.read("log/refuels/a.json") == data)
        #expect(book.exists("log/refuels/a.json"))
        try book.writeAtomic("log/refuels/a.json", Data("two".utf8))
        #expect(try book.read("log/refuels/a.json") == Data("two".utf8))
        #expect(try book.list("log/refuels") == ["a.json"])
        #expect(try book.allFiles(under: "log") == ["log/refuels/a.json"])
        try book.delete("log/refuels/a.json")
        #expect(!book.exists("log/refuels/a.json"))
    }

    @Test func outsideRootRejected() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for bad in ["../x", "a/../../x", "/etc/passwd", "a/.."] {
            #expect(throws: BookError.outsideRoot(bad)) { try book.writeAtomic(bad, Data()) }
            #expect(throws: BookError.outsideRoot(bad)) { try book.read(bad) }
            #expect(throws: BookError.outsideRoot(bad)) { try book.delete(bad) }
            #expect(!book.exists(bad))
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.appending(path: "x").path))
        // url() can never point outside the root
        #expect(book.url("../x").path.hasPrefix(book.root.path))
    }

    @Test func placeholderCountsAsPresent() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = book.root.appending(path: "raw/days/v")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: ".20261020.json.icloud"))
        try Data("{}".utf8).write(to: dir.appending(path: "20261021.json"))
        try Data().write(to: dir.appending(path: ".DS_Store"))
        #expect(book.exists("raw/days/v/20261020.json"))
        #expect(try book.list("raw/days/v") == ["20261020.json", "20261021.json"])
        #expect(try book.allFiles(under: "raw") == ["raw/days/v/20261020.json", "raw/days/v/20261021.json"])
        #expect(throws: BookError.notDownloaded("raw/days/v/20261020.json")) { try book.read("raw/days/v/20261020.json") }
    }

    @Test func ensureDownloadedWaitsForPlaceholderToVanish() async throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = book.root.appending(path: "raw")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let placeholder = dir.appending(path: ".d.json.icloud")
        try Data().write(to: placeholder)
        // Simulated iCloud: after 300 ms the real file replaces the placeholder.
        _ = Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            try Data("{\"ok\":1}".utf8).write(to: dir.appending(path: "d.json"))
            try FileManager.default.removeItem(at: placeholder)
        }
        try await book.ensureDownloaded("raw/d.json", timeout: 5)
        #expect(try book.read("raw/d.json") == Data("{\"ok\":1}".utf8))
    }

    @Test func ensureDownloadedTimesOutAndMissingThrows() async throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data().write(to: book.root.appending(path: ".p.json.icloud"))
        // Off iCloud the start-download call fails; that error is surfaced on timeout, not swallowed.
        do { try await book.ensureDownloaded("p.json", timeout: 0.3); Issue.record("should throw") }
        catch BookError.downloadFailed(let rel, _) { #expect(rel == "p.json") }
        await #expect(throws: BookError.notDownloaded("none.json")) { try await book.ensureDownloaded("none.json", timeout: 0.3) }
        try Data("x".utf8).write(to: book.root.appending(path: "here.json"))
        try await book.ensureDownloaded("here.json", timeout: 0.1)
    }

    @Test func unreachableRootThrows() throws {
        let (book, tmp) = try makeTempBook()
        try FileManager.default.removeItem(at: tmp)
        #expect(throws: BookError.unreachable) { try book.writeAtomic("log/refuels/a.json", Data("x".utf8)) }
        #expect(throws: BookError.unreachable) { try book.list("log") }
        #expect(throws: BookError.unreachable) { try book.read("a.json") }
        // nothing was created anywhere
        #expect(!FileManager.default.fileExists(atPath: book.root.path))
    }

    @Test func dotFilePlaceholdersStayHidden() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data().write(to: book.root.appending(path: "..foo.icloud"))
        try Data().write(to: book.root.appending(path: ".a.json.icloud"))
        #expect(try book.list("") == ["a.json"])
    }

    @Test func rootItselfCannotBeWrittenOrDeleted() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try book.writeAtomic("keep.json", Data("k".utf8))
        for bad in ["", ".", "./", "//", "./."] {
            #expect(throws: BookError.outsideRoot(bad)) { try book.delete(bad) }
            #expect(throws: BookError.outsideRoot(bad)) { try book.writeAtomic(bad, Data("x".utf8)) }
        }
        #expect(try book.read("keep.json") == Data("k".utf8))
        #expect(try book.list("") == ["keep.json"])
    }

    @Test func symlinkOutOfBookIsRefused() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = tmp.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appending(path: "s.json"))
        try FileManager.default.createSymbolicLink(at: book.root.appending(path: "log"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: book.root.appending(path: "file.json"), withDestinationURL: outside.appending(path: "s.json"))
        for rel in ["log/s.json", "log/new.json", "log", "file.json"] {
            #expect(throws: BookError.outsideRoot(rel)) { try book.read(rel) }
            #expect(throws: BookError.outsideRoot(rel)) { try book.writeAtomic(rel, Data("x".utf8)) }
            #expect(throws: BookError.outsideRoot(rel)) { try book.delete(rel) }
        }
        #expect(throws: BookError.outsideRoot("log")) { try book.list("log") }
        #expect(!book.exists("log/s.json"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["s.json"])
        #expect(try Data(contentsOf: outside.appending(path: "s.json")) == Data("secret".utf8))
        // allFiles never follows links
        #expect(try book.allFiles(under: "") == [])
    }

    @Test func symlinkLoopDoesNotRecurseAndInternalLinksWork() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try book.writeAtomic("a/f.json", Data("1".utf8))
        try FileManager.default.createSymbolicLink(at: book.root.appending(path: "a/loop"), withDestinationURL: book.root.appending(path: "a"))
        #expect(try book.allFiles(under: "") == ["a/f.json"])
        // a link that stays inside the book is allowed for reads
        #expect(try book.read("a/loop/f.json") == Data("1".utf8))
    }

    @Test func symlinkedRootIsResolved() throws {
        let (book, tmp) = try makeTempBook()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let link = tmp.appending(path: "link_book")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: book.root)
        let viaLink = Book(root: link)
        try viaLink.writeAtomic("x.json", Data("x".utf8))
        #expect(try book.read("x.json") == Data("x".utf8))
    }
}
