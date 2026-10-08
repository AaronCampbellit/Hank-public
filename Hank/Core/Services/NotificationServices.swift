import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

enum HankNotificationCategory: String, CaseIterable, Sendable {
    case storage
    case notes
    case dashboardEntities = "dashboard_entities"
}

struct HankLocalNotification: Sendable {
    let category: HankNotificationCategory
    let title: String
    let body: String
    let url: URL
    let threadID: String
}

final class HankNotificationService: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = HankNotificationService()
    static let isEnabled = false

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastRegistrationError: String?
    @Published private(set) var pendingDeepLinkURL: URL?

    private weak var services: AppServices?
    private let center = UNUserNotificationCenter.current()
    private let deviceIDKey = "Hank.APNSDeviceID"
    private var deviceToken: String?
    private var pendingContext: HankRemoteConnectionContext?

    @MainActor
    func configure(services: AppServices) {
        guard Self.isEnabled else {
            return
        }
        self.services = services
        center.delegate = self
        center.setNotificationCategories(Set(HankNotificationCategory.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        }))
        Task {
            await refreshAuthorizationStatus()
        }
    }

    @MainActor
    func requestAuthorizationAndRegister(context: HankRemoteConnectionContext, services: AppServices) async {
        guard Self.isEnabled else {
            lastRegistrationError = nil
            return
        }
        pendingContext = context
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            guard granted else {
                lastRegistrationError = "Notifications are disabled for Hank."
                return
            }
            #if canImport(UIKit)
            UIApplication.shared.registerForRemoteNotifications()
            #endif
            await registerAPNSDeviceIfPossible(context: context, services: services)
        } catch {
            lastRegistrationError = error.localizedDescription
        }
    }

    @MainActor
    func registerAPNSDeviceIfPossible(context: HankRemoteConnectionContext, services: AppServices) async {
        guard Self.isEnabled else {
            return
        }
        pendingContext = context
        guard let deviceToken else {
            return
        }
        do {
            try await services.hankRemoteService.registerAPNSDevice(
                deviceID: deviceID,
                token: deviceToken,
                environment: Self.apnsEnvironment,
                bundleID: Bundle.main.bundleIdentifier ?? "com.dropfile.Hank",
                enabledCategories: HankNotificationCategory.allCases.map(\.rawValue),
                context: context
            )
            lastRegistrationError = nil
        } catch {
            lastRegistrationError = error.localizedDescription
        }
    }

    @MainActor
    func unregisterAPNSDevice(context: HankRemoteConnectionContext, services: AppServices) async {
        guard Self.isEnabled else {
            return
        }
        do {
            try await services.hankRemoteService.unregisterAPNSDevice(deviceID: deviceID, context: context)
        } catch {
            lastRegistrationError = error.localizedDescription
        }
    }

    @MainActor
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        guard Self.isEnabled else {
            return
        }
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        guard let services, let pendingContext else {
            return
        }
        Task {
            await registerAPNSDeviceIfPossible(context: pendingContext, services: services)
        }
    }

    @MainActor
    func didFailToRegisterForRemoteNotifications(_ error: Error) {
        guard Self.isEnabled else {
            return
        }
        lastRegistrationError = error.localizedDescription
    }

    @MainActor
    func presentLocalNotification(_ notification: HankLocalNotification) async {
        guard Self.isEnabled else {
            return
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.threadID
        content.categoryIdentifier = notification.category.rawValue
        content.userInfo = [
            "hank_url": notification.url.absoluteString,
            "hank_category": notification.category.rawValue
        ]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    @MainActor
    func queueDeepLink(_ url: URL) {
        guard Self.isEnabled else {
            return
        }
        pendingDeepLinkURL = url
    }

    @MainActor
    func consumePendingDeepLinkURL() {
        pendingDeepLinkURL = nil
    }

    @MainActor
    private func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @MainActor
    private var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: deviceIDKey)
        return generated
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

extension HankNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard
            let rawURL = response.notification.request.content.userInfo["hank_url"] as? String,
            let url = URL(string: rawURL)
        else {
            return
        }
        Task { @MainActor in
            self.queueDeepLink(url)
        }
    }
}

#if canImport(UIKit)
final class HankAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            HankNotificationService.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            HankNotificationService.shared.didFailToRegisterForRemoteNotifications(error)
        }
    }
}
#endif
