import SwiftUI
import AppKit

private let surgeViolet = Color(red: 0.64, green: 0.36, blue: 1)
private let surgeInk = Color(red: 0.055, green: 0.04, blue: 0.10)

struct PurpleSurgeDock: View {
    @ObservedObject var game: PurpleSurgeStore
    let returnToTask: (SurgeTaskStatus?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var tabFocused: Bool
    @StoredState private var onlineFailure: String?
    @StoredState private var reload = 0
    @StoredState private var onlineLoading = true
    @StoredState private var puzzleHeight: CGFloat = 620
    var body: some View {
        HStack(spacing: 0) {
            if game.open {
                GeometryReader { geometry in
                    panel(compact: geometry.size.height < 760)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }.frame(width: game.introduction ? 328 : 360)
                    .transition(.opacity.combined(with: reduceMotion ? .identity : .move(edge: .trailing)))
            } else {
                VStack {
                    Button { game.show() } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "bolt.fill").font(.system(size: 15, weight: .bold))
                            Text("PURPLE\nSURGE").font(.system(size: 8, weight: .heavy, design: .rounded)).multilineTextAlignment(.center).tracking(0.5)
                            if !game.notices.isEmpty { Circle().fill(.orange).frame(width: 6, height: 6) }
                        }.foregroundStyle(surgeViolet).padding(.vertical, 15).frame(width: 40)
                        .background(surgeViolet.opacity(0.09), in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
                    }.buttonStyle(.plain).focused($tabFocused).help("Play Purple Surge · offline puzzles and online matches")
                        .accessibilityLabel("Open Purple Surge")
                        .overlay(alignment: .leading) {
                            if game.peeking {
                                mascot("waving", size: 82).offset(x: -76)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                                    .transition(.opacity)
                            }
                        }
                    Spacer()
                }.padding(.top, 22).frame(width: 40)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: game.open)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: game.peeking)
    }
    private func panel(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "bolt.fill").font(.system(size: 19, weight: .black)).foregroundStyle(surgeViolet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PURPLE SURGE").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(1.2)
                    if !compact { Text("A little play. Right here.").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                Button { game.hide(); tabFocused = true } label: {
                    Image(systemName: "sidebar.right").font(.system(size: 16)).frame(width: 28, height: 30)
                }.buttonStyle(.plain).help("Hide Purple Surge").accessibilityLabel("Hide Purple Surge")
            }.padding(compact ? 12 : 18)
            taskStrip(compact: compact)
            if game.introduction {
                introduction(compact: compact)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(SurgeDestination.allCases) { destination in
                        Button {
                            onlineFailure = nil
                            onlineLoading = true
                            if game.destination == destination { reload += 1 }
                            else { game.destination = destination }
                        } label: {
                            Text(destination.title).font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(game.destination == destination ? surgeViolet.opacity(0.4) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(game.destination == destination ? .isSelected : [])
                    }
                }.padding(.horizontal, compact ? 12 : 18).padding(.vertical, 8)
            }
            if game.destination != .offline && !game.introduction {
                onlineContent
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                        if let puzzle = game.puzzle, let position = game.position { puzzleContent(puzzle, position, compact: compact) }
                        if let error = game.error {
                            Text(error).font(.callout).foregroundStyle(.orange)
                            if game.position == nil { Button("Keep backup & start fresh") { game.recover() } }
                            else { Button("Retry saving") { game.retrySave() } }
                        }
                    }.padding(compact ? 12 : 18)
                }
            }
            Divider().overlay(.white.opacity(0.08))
            Toggle("Show occasional invitations", isOn: Binding(get: { game.archive.invitations }, set: { game.setInvitations($0) }))
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(.secondary).padding(compact ? 10 : 14)
                .accessibilityLabel("Show occasional Purple Surge invitations")
        }
        .background(surgeInk)
        .overlay(alignment: .leading) { Rectangle().fill(surgeViolet.opacity(0.23)).frame(width: 1) }
        .environment(\.colorScheme, .dark).tint(surgeViolet)
    }
    private func taskStrip(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(game.notice?.needsInput == true ? .orange : game.runningCount > 0 ? .green : surgeViolet).frame(width: 6, height: 6)
                Text(taskText).font(.system(size: 11, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
                if game.notices.count > 1 { Text("+\(game.notices.count - 1)").font(.caption).foregroundStyle(.secondary) }
                if compact && (game.notice != nil || game.runningCount > 0) { returnButton }

            }
            if !compact && (game.notice != nil || game.runningCount > 0) { returnButton }
        }.padding(.horizontal, compact ? 12 : 18).padding(.vertical, compact ? 8 : 11)
            .frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045))
            .accessibilityElement(children: .contain)
    }
    private var returnButton: some View {
        Button("Return to task") {
            let notice = game.notice; game.acknowledgeNotice(); game.hide(); returnToTask(notice)
        }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(surgeViolet).fixedSize()
    }
    private var taskText: String {
        if let notice = game.notice {
            if notice.needsInput { return "Your task needs your input." }
            if notice.failed { return "Your task stopped. Check its status." }
            return "Your task is complete."
        }
        return game.runningCount > 0 ? "\(game.runningCount == 1 ? "Your task is" : "\(game.runningCount) tasks are") still working." : "Your workspace is right beside you."
    }
    private func introduction(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                mascot("waving", size: compact ? 46 : 68)
                Text("Purple Surge is built into Navigator. Play here while you wait, or tuck it away whenever you like.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Play") { game.play() }.buttonStyle(.borderedProminent)
                Button("Hide") { game.hide(); tabFocused = true }.buttonStyle(.bordered)
                Spacer()
            }
        }.padding(compact ? 12 : 18).background(surgeViolet.opacity(0.08))
    }
    private var onlineContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Timed games keep running when hidden.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Reload game")
            }.padding(.horizontal, 18).padding(.bottom, 10)
            if let failure = onlineFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure).font(.callout)
                    HStack { Button("Retry") { reload += 1 }; Button("Offline puzzle") { game.destination = .offline } }
                }.padding(14).frame(maxWidth: .infinity).background(surgeViolet.opacity(0.12))
            }
            PurpleSurgeOnline(failure: $onlineFailure, loading: $onlineLoading, reload: reload, destination: game.destination)
                .id(game.destination)
                .overlay {
                    if onlineLoading && onlineFailure == nil {
                        VStack(spacing: 12) { ProgressView(); Text("Loading Purple Surge…").font(.callout).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(surgeInk)
                    }
                }
        }
    }
    private func puzzleContent(_ puzzle: SurgePuzzle, _ position: SurgePosition, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            PurpleSurgeBoard(game: game, reduced: reduceMotion, contentHeight: $puzzleHeight)
                .frame(height: puzzleHeight)
            HStack {
                Label(game.error == nil ? "Saved on this Mac" : "Save needs attention", systemImage: game.error == nil ? "checkmark.shield" : "exclamationmark.circle").foregroundStyle(.secondary)
                Spacer()
                Text("\(game.archive.completed.count) / \(game.puzzleCount) solved").foregroundStyle(surgeViolet)
            }.font(.system(size: 10))
        }
    }
    private func tokenLegend(_ label: String, name: String) -> some View {
        HStack(spacing: 4) {
            if let image = NSImage(contentsOf: SurgeResources.directory.appendingPathComponent("img/token-" + name + ".webp")) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16).accessibilityHidden(true)
            }
            Text(label)
        }
    }
    private func mascot(_ name: String, size: CGFloat) -> some View {
        Group {
            if let image = NSImage(contentsOf: SurgeResources.directory.appendingPathComponent(name + ".webp")) {
                Image(nsImage: image).resizable().scaledToFit()
            }
        }.frame(width: size, height: size).accessibilityLabel("Sergio")
    }
}
