import SkylightBrowser
import SkylightCore
import SwiftUI

/// What a new Space keeps from the current one. It opens on the last choice with the name
/// selected, so Return is all it takes, and it lists only what this Space has to keep.
struct SpaceSetupSheet: View {
    let request: SpaceSetupRequest
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var setup = SpaceSetup()
    @FocusState private var nameFocused: Bool

    private var isNew: Bool { request.space == nil }
    private var sharesEverything: Bool { isNew && setup.sharesEverything }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Space" : "New Profile for This Space").font(.title3.weight(.semibold))
            if isNew {
                TextField("Name", text: $name, prompt: Text(request.name))
                    .focused($nameFocused)
                    .onSubmit(finish)
                section("Stay signed in to") {
                    Picker("Stay signed in to", selection: $setup.sharesEverything) {
                        choice("Everything", "Same accounts as \(request.sourceName)").tag(true)
                        choice(request.signedIn.isEmpty ? "Nothing" : "Only these", "Everything else starts signed out").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if !sharesEverything { sites.padding(.leading, 20) }
                }
            } else if !request.signedIn.isEmpty {
                section("Stay signed in to") { sites }
            }
            if !sharesEverything {
                section("Bring along") {
                    Toggle("Saved passwords", isOn: $setup.passwords)
                    ForEach(browser.extensions.enabled, id: \.id) { ext in
                        Toggle(browser.extensions.manifest(ext.id)?.name ?? ext.id, isOn: Binding(
                            get: { !setup.skippedExtensions.contains(ext.id) },
                            set: { keep in
                                if keep { setup.skippedExtensions.remove(ext.id) } else { setup.skippedExtensions.insert(ext.id) }
                            }))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Space" : "Split Space", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 340)
        .onAppear {
            name = request.name
            setup = browser.preferences.newSpaceSetup
            nameFocused = isNew
        }
    }

    private var sites: some View {
        ForEach(request.signedIn) { site in
            Toggle(site.name, isOn: Binding(
                get: { setup.sites.contains(site) },
                set: { keep in
                    if keep { setup.sites.insert(site) } else { setup.sites.remove(site) }
                }))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func choice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func finish() {
        animate(Motion.swap) { browser.finishSpaceSetup(name: name, setup: setup) }
    }
}
