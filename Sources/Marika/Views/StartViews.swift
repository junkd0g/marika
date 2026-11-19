import MarikaCore
import SwiftUI

struct SessionStartView: View {
    @Environment(AppModel.self) private var model
    let session: SessionController
    let project: Project
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            if !compact {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text("What would you like to build?")
                .font(compact ? .custom("Georgia", size: 28, relativeTo: .title) : Theme.displayTitle).tracking(-1)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)

            if model.statuses[session.meta.agent]?.readiness != .ready {
                AgentStatusLine(agent: session.meta.agent)
            }
            if !session.meta.hasDraft {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { starters }.fixedSize()
                    Menu {
                        ForEach(SessionStarter.allCases) { starter in
                            Button { model.prepareStarter(starter, for: session.id) } label: {
                                Label(starter.title, systemImage: starter.symbol)
                            }
                        }
                    } label: {
                        Label("Choose a starting point", systemImage: "sparkle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 660)
        .padding(.horizontal, 24).padding(.top, compact ? 12 : 20)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var starters: some View {
        ForEach(SessionStarter.allCases) { starter in
            Button { model.prepareStarter(starter, for: session.id) } label: {
                Label(starter.title, systemImage: starter.symbol)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surface.opacity(0.45), in: Capsule())
                    .overlay { Capsule().strokeBorder(Theme.hairline.opacity(0.6)) }
            }.buttonStyle(.plain).help("Add this prompt to your draft")
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
