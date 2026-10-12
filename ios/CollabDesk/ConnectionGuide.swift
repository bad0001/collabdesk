import SwiftUI

/// Public onboarding material only. These values are never credentials and
/// choosing the suggested address does not connect or change a workspace.
enum ConnectionGuide {
    static let suggestedAddress = "https://api.example.com"

    static func addressSuggestion(existing: String) -> String {
        existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestedAddress : existing
    }
}

enum PublicAIGuide: String, CaseIterable, Identifiable {
    case leader, worker, platform
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leader: return "Leader 使用手册"
        case .worker: return "Worker 专用版模板"
        case .platform: return "全平台功能说明"
        }
    }
    var url: URL {
        URL(string: "\(ConnectionGuide.suggestedAddress)/guide/\(rawValue).md")!
    }
}

struct AIGuideLinks: View {
    var guides: [PublicAIGuide] = PublicAIGuide.allCases
    var body: some View {
        ForEach(guides) { document in
            HStack(spacing: 12) {
                Link(destination: document.url) {
                    Label(document.title, systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("aiGuide-\(document.rawValue)")
                ShareLink(item: document.url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(minWidth: 32, minHeight: 32)
                }.accessibilityLabel("分享\(document.title)")
                    .accessibilityIdentifier("shareAIGuide-\(document.rawValue)")
            }.font(.subheadline)
        }
    }
}
