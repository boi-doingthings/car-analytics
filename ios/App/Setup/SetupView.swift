import SwiftUI
import UniformTypeIdentifiers

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}

struct CredentialsForm: View {
    @State private var username = Credentials.load()?.0 ?? ""
    @State private var password = ""
    @State private var message: String?
    var onSaved: () -> Void = {}

    var body: some View {
        Section("Bluelink login") {
            TextField("Username", text: $username)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("username")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("password")
            Button("Save login") {
                do {
                    try Credentials.save(username: username, password: password)
                    password = ""
                    message = "Saved"
                    onSaved()
                } catch {
                    message = "Could not save to the Keychain"
                }
            }
            .disabled(username.isEmpty || password.isEmpty)
            .accessibilityIdentifier("saveLogin")
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var folder: FolderAccess
    @Binding var hasCredentials: Bool

    var body: some View {
        NavigationStack {
            Form {
                if folder.book == nil {
                    Section("1. Logbook folder") {
                        Text("Choose the i20_book folder in iCloud Drive.")
                        Button("Pick folder") { folder.pick() }.accessibilityIdentifier("pickFolder")
                        if let e = folder.error { Text(e).foregroundStyle(.red).accessibilityIdentifier("folderError") }
                    }
                } else {
                    Section("1. Logbook folder") { Label("i20_book selected", systemImage: "checkmark.circle") }
                }
                if folder.book != nil {
                    CredentialsForm(onSaved: { hasCredentials = true })
                }
            }
            .navigationTitle("Set up")
        }
        .sheet(isPresented: $folder.showPicker) {
            FolderPicker { folder.picked($0) }
        }
    }
}
