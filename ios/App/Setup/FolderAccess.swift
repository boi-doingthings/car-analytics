import Foundation
import I20Core

/// Access to the owner's `i20_book` folder through a security-scoped bookmark.
/// Nothing outside that folder is ever opened; a folder with any other name is refused and nothing is stored.
@MainActor
final class FolderAccess: ObservableObject {
    static let folderName = "i20_book"
    static let bookmarkKey = "i20_book_bookmark"
    static let wrongFolderMessage = "Pick the i20_book folder in iCloud Drive"

    @Published var book: Book?
    @Published var showPicker = false
    @Published var error: String?

    private let defaults: UserDefaults
    private var scopedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Presents the folder picker (the view hosts the sheet).
    func pick() {
        error = nil
        showPicker = true
    }

    static let restoreFailedMessage = "Couldn't open i20_book \u{2014} pick it again"
    static let refreshFailedMessage = "Couldn't refresh access to i20_book \u{2014} pick it again"

    @Published var warning: String?

    /// Resolves the stored bookmark; refreshes it when stale. Leaves `book` nil (and drops the dead
    /// bookmark, with a message) when unresolvable.
    func restore() {
        guard book == nil, let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.lastPathComponent == Self.folderName,
              url.startAccessingSecurityScopedResource() else {
            defaults.removeObject(forKey: Self.bookmarkKey)
            error = Self.restoreFailedMessage
            return
        }
        refreshIfStale(stale) { try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        activate(url)
    }

    /// Stores a fresh bookmark when the old one is stale; a failure sets `warning` (access still works until it lapses).
    func refreshIfStale(_ stale: Bool, make: () throws -> Data) {
        guard stale else { return }
        do {
            defaults.set(try make(), forKey: Self.bookmarkKey)
            warning = nil
        } catch {
            warning = Self.refreshFailedMessage
        }
    }

    /// Handles the picker result. Wrong name: message, nothing stored, current book unchanged.
    func picked(_ url: URL) {
        guard url.lastPathComponent == Self.folderName else {
            error = Self.wrongFolderMessage
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            error = "Could not open that folder"
            return
        }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            url.stopAccessingSecurityScopedResource()
            error = "Could not remember that folder"
            return
        }
        defaults.set(data, forKey: Self.bookmarkKey)
        error = nil
        warning = nil
        activate(url)
    }

    private func activate(_ url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url
        book = Book(root: url)
    }
}
