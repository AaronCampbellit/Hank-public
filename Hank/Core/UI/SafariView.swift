import SafariServices
import SwiftUI
import UIKit

struct HankBrowserDestination: Identifiable, Equatable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

enum HankLinkOpenRoute: Equatable {
    case inAppBrowser(URL)
    case external(URL)
}

enum HankLinkRouting {
    static func route(for url: URL) -> HankLinkOpenRoute {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return .inAppBrowser(url)
        default:
            return .external(url)
        }
    }

    static func handle(
        _ url: URL,
        openInAppBrowser: (URL) -> Void,
        openExternally: (URL) -> Void
    ) {
        switch route(for: url) {
        case .inAppBrowser(let browserURL):
            openInAppBrowser(browserURL)
        case .external(let externalURL):
            openExternally(externalURL)
        }
    }
}

struct HankSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
