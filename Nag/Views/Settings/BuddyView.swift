import NagKit
import SwiftUI

/// Share chosen nags and locks with one buddy, and see what others shared with you. Low pressure on
/// purpose: a buddy sees "did it" or "still due" and can send one nudge, never counts or rankings.
struct BuddyView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false
    @State private var leaving: BuddyFriend?

    var body: some View {
        Form {
            if let buddy = model.buddy {
                sharingSection(buddy)
                if model.state.buddy.sharingEnabled {
                    pickSection(title: "Nags", items: model.state.tasks.map { ($0.id, $0.title, "bell") })
                    if !model.state.profiles.isEmpty {
                        pickSection(title: "Locks", items: model.state.profiles.map { ($0.id, $0.name, $0.symbol) })
                    }
                }
                followingSection(buddy)
                if let message = buddy.errorMessage {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
            } else {
                Section {
                    Text("Buddies aren't available right now.")
                }
            }
        }
        .navigationTitle("Accountability buddy")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.buddy?.refreshFriends() }
        .refreshable { await model.buddy?.refresh() }
        .confirmationDialog("Stop sharing?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) {
                Task { await model.buddy?.stopSharing() }
            }
        } message: {
            Text("Your buddy will no longer see anything, and the invitation stops working.")
        }
        .confirmationDialog(
            "Stop following \(leaving?.name ?? "")?",
            isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop following", role: .destructive) {
                if let friend = leaving { Task { await model.buddy?.leave(friend) } }
            }
        }
    }

    @ViewBuilder
    private func sharingSection(_ buddy: BuddyController) -> some View {
        Section {
            Toggle("Share with a buddy", isOn: Binding(
                get: { model.state.buddy.sharingEnabled },
                set: { on in
                    if on {
                        Task { await buddy.enableSharing() }
                    } else {
                        confirmStop = true
                    }
                }
            ))
            .disabled(buddy.isWorking)
            if model.state.buddy.sharingEnabled {
                Button {
                    Task { await buddy.presentInvite() }
                } label: {
                    Label("Invite or manage your buddy", systemImage: "person.badge.plus")
                }
                .disabled(buddy.isWorking)
            }
        } footer: {
            Text("Pick one person to see whether the nags and locks you choose are done or still due. They can send you a nudge. Nothing else is shared: no notes, keys, apps or history. Turn it off any time.")
        }
    }

    private func pickSection(title: String, items: [(UUID, String, String)]) -> some View {
        Section {
            if items.isEmpty {
                Text("Nothing here yet.").foregroundStyle(.secondary)
            }
            ForEach(items, id: \.0) { id, name, symbol in
                Toggle(isOn: Binding(
                    get: { model.state.buddy.isShared(id) },
                    set: { model.buddy?.setShared(id, $0) }
                )) {
                    Label(name, systemImage: symbol)
                }
            }
        } header: {
            Text("Share these \(title.lowercased())")
        }
    }

    @ViewBuilder
    private func followingSection(_ buddy: BuddyController) -> some View {
        if buddy.friends.isEmpty {
            Section {
                Text("When someone invites you to be their buddy, what they share shows up here.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shared with you")
            }
        }
        ForEach(buddy.friends) { friend in
            Section {
                if friend.items.isEmpty {
                    Text("\(friend.name) hasn't shared anything yet.").foregroundStyle(.secondary)
                }
                ForEach(friend.items) { item in
                    BuddyItemRow(item: item, friend: friend, now: .now)
                }
                Button("Stop following", role: .destructive) { leaving = friend }
            } header: {
                Text(friend.name)
            } footer: {
                Text("A nudge is a quiet notification. You can send one per item until it's done, or again after a few hours.")
            }
        }
    }
}

private struct BuddyItemRow: View {
    @Environment(AppModel.self) private var model
    let item: BuddyItem
    let friend: BuddyFriend
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(item.displayStatus(at: now) == .done ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.statusLabel(at: now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.displayStatus(at: now) == .due, let buddy = model.buddy {
                let canNudge = buddy.canNudge(item, now: now)
                Button(canNudge ? "Nudge" : "Nudged") {
                    Task { await buddy.nudge(item, of: friend) }
                }
                .buttonStyle(.bordered)
                .disabled(!canNudge || buddy.isWorking)
                .accessibilityHint(canNudge ? "Sends \(friend.name) a gentle notification" : "You can nudge again later")
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch (item.kind, item.displayStatus(at: now)) {
        case (_, .done): item.kind == .lock ? "lock.open" : "checkmark.circle.fill"
        case (.lock, _): "lock.fill"
        case (_, .started): "figure.walk"
        case (_, .upcoming): "clock"
        default: "bell"
        }
    }
}
