import Foundation
import I20Core

/// Simulator-only harness for manual checks (DEBUG builds): `I20_DEBUG_BOOK=<path to a COPY of a book>`
/// (pass as `SIMCTL_CHILD_I20_DEBUG_BOOK`) opens that folder without the picker and replaces Bluelink with
/// an offline stub account that has no vehicles, so "Sync now" walks login → collect → analyse without any
/// network call. Release builds never read the environment.
enum DebugHarness {
    #if DEBUG
    static var active: Bool { ProcessInfo.processInfo.environment["I20_DEBUG_BOOK"] != nil }

    struct Setup {
        let book: Book
        let login: SyncCoordinator.Login
    }

    static func fromEnvironment() -> Setup? {
        guard let path = ProcessInfo.processInfo.environment["I20_DEBUG_BOOK"] else { return nil }
        return Setup(book: Book(root: URL(fileURLWithPath: path))) { _, _ in
            try await Task.sleep(for: .seconds(2))  // long enough to see the step label
            return StubAPI()
        }
    }

    private struct StubAPI: BluelinkAPI {
        func vehicles() async throws -> (raw: Data, list: [Vehicle]) {
            try await Task.sleep(for: .seconds(2))
            return (Data(), [])
        }
        func get(_ path: String) async throws -> Data { Data() }
        func post(_ path: String, json: [String: Any]) async throws -> Data { Data() }
    }
    #else
    static let active = false
    #endif
}
