import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var library: Library
    @State private var renamingID: Playlist.ID?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: $library.selection) {
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    row(for: playlist)
                        .tag(playlist.id)
                        .contextMenu {
                            Button("Rename") { beginRename(playlist) }
                            Button("Add Videos…") { library.presentOpenPanel(into: playlist.id) }
                            Divider()
                            Button("Delete Playlist", role: .destructive) { library.deletePlaylist(playlist.id) }
                                .disabled(library.playlists.count < 2)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            !library.add(urls, to: playlist.id).isEmpty
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    let id = library.newPlaylist()
                    if let p = library.playlists.first(where: { $0.id == id }) { beginRename(p) }
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        if renamingID == playlist.id {
            TextField("Playlist name", text: $draftName)
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renamingID = nil }
                .onChange(of: renameFocused) { focused in if !focused { commitRename() } }
        } else {
            Label(playlist.name, systemImage: "list.bullet.rectangle")
                .badge(playlist.items.count)
        }
    }

    private func beginRename(_ playlist: Playlist) {
        draftName = playlist.name
        renamingID = playlist.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        if let id = renamingID { library.rename(id, to: draftName) }
        renamingID = nil
    }
}
