import MarikaCore
import SwiftUI

struct SessionStartView: View {
    @Environment(AppModel.self) private var model
    let session: SessionController
    let project: Project

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.ink)
                            .padding(.bottom, 6).accessibilityHidden(true)
                        Text("What would you like to build?")
                            .font(.system(size: geometry.size.width < 420 ? 22 : 28, weight: .medium))
                            .tracking(-0.6).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(project.name, systemImage: "folder")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(project.path)
                    }

                    if model.statuses[session.meta.agent]?.readiness != .ready {
                        AgentStatusLine(agent: session.meta.agent)
                    }

                    if !session.meta.hasDraft {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                            ForEach(SessionStarter.allCases) { starter in
                                Button { model.prepareStarter(starter, for: session.id) } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Image(systemName: starter.symbol).font(.system(size: 14)).foregroundStyle(.secondary)
                                        Text(starter.title).font(.system(size: 12)).lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                    .padding(14)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline.opacity(0.6)) }
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain).help("Add this prompt to your draft")
                            }
                        }
                    }
                }
                .frame(maxWidth: 530)
                .padding(geometry.size.width < 420 ? 24 : 40)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .defaultScrollAnchor(.center, for: .alignment)
        }
    }
}

enum SessionStarter: String, CaseIterable, Identifiable {
    case explore, review, test

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: "Understand this project"
        case .review: "Review recent changes"
        case .test: "Find a bug worth fixing"
        }
    }

    var symbol: String {
        switch self {
        case .explore: "map"
        case .review: "text.magnifyingglass"
        case .test: "ladybug"
        }
    }

    var prompt: String {
        switch self {
        case .explore:
            "Give me a concise tour of this project: how it is structured, how to run it, and where the main behavior lives. Read the files first; don't change anything yet."
        case .review:
            "Review the recent changes in this project for concrete bugs and regressions. Explain any findings with file references. Don't change files yet."
        case .test:
            "Inspect this project and find a concrete bug worth fixing. Explain how to reproduce it and suggest a focused fix and a useful test. Don't change files yet."
        }
    }
}

struct AppIconMark: View {
    var size: CGFloat = 80

    var body: some View {
        Group {
            if let icon = Theme.appIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "terminal.fill").resizable().scaledToFit().padding(16)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            AppIconMark(size: 96)
            VStack(spacing: 9) {
                Text("Welcome to Marika")
                    .font(.system(size: 26, weight: .semibold))
                Text("Open a project and work with your coding agent.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Button {
                model.chooseProject()
            } label: {
                Label("Open a Project", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Text("Choose a folder or drop one into this window  ·  ⌘O")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(AgentKind.allCases) { agent in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.displayName)
                            .font(.system(size: 12, weight: .semibold))
                        AgentStatusLine(agent: agent)
                    }
                    if agent != AgentKind.allCases.last { Divider() }
                }
            }
            .padding(16)
            .frame(maxWidth: 350, alignment: .leading)
            .background(Theme.chrome.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline) }
            .padding(.top, 10)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
