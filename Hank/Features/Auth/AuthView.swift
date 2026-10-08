import SwiftUI
import SwiftData

struct LoginView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var services: AppServices

    @State private var password = ""
    @State private var rememberSession = true
    @State private var firstLaunchMode: FirstLaunchMode = .chooser
    @State private var hankRemoteCloudURL = ""
    @State private var hankRemoteEmail = ""
    @State private var hankRemotePassword = ""
    @State private var isSubmittingHankRemote = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        HankTheme.background,
                        HankTheme.chrome,
                        HankTheme.background.opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(HankTheme.accent.opacity(0.22))
                    .frame(width: 260, height: 260)
                    .blur(radius: 28)
                    .offset(x: 140, y: -260)

                Circle()
                    .fill(HankTheme.success.opacity(0.14))
                    .frame(width: 220, height: 220)
                    .blur(radius: 30)
                    .offset(x: -150, y: 260)

                ScrollView {
                    VStack(spacing: 24) {
                        hero

                        if appState.profiles.isEmpty {
                            firstLaunchContent
                        } else {
                            existingProfileContent
                        }

                        if let errorMessage = appState.errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(HankTheme.error)
                                .multilineTextAlignment(.center)
                                .hankCard(fill: HankTheme.errorSurface, padding: 14)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                }
            }
            .navigationBarHidden(true)
            .task(id: appState.profileDataRevision) {
                syncAuthenticationFields()
            }
            .onChange(of: appState.selectedProfileID) { _, _ in
                syncAuthenticationFields()
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(HankTheme.elevatedSurface)
                Image(systemName: "server.rack")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(HankTheme.accent)
            }
            .frame(width: 84, height: 84)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(HankTheme.stroke, lineWidth: 1)
            )

            VStack(spacing: 8) {
                Text("Hank")
                    .font(.largeTitle.bold())
                Text("Profile-based home server dashboard and file manager")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 12)
    }

    private var selectedProfile: UserProfile? {
        appState.profiles.first(where: { $0.id == appState.selectedProfileID }) ?? appState.profiles.first
    }

    @ViewBuilder
    private var firstLaunchContent: some View {
        switch firstLaunchMode {
        case .chooser:
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Text("How do you want to use Hank?")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Text("Connect to Hank Remote to keep your home, notes, and profile data synced through your Hank server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Connect To Hank Remote") {
                    firstLaunchMode = .hankRemote
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            }
            .frame(maxWidth: .infinity)
            .hankCard(fill: HankTheme.surface)

        case .hankRemote:
            hankRemoteOnboardingCard
        }
    }

    @ViewBuilder
    private var existingProfileContent: some View {
        if appState.profiles.count > 1 {
            profilePicker
        }

        if let selectedProfile {
            profileAccessCard(for: selectedProfile)
        }
    }

    private var hankRemoteOnboardingCard: some View {
        hankRemoteAccessCard(
            title: "Connect To Hank Remote",
            message: "Sign in with your Hank Remote account first. Hank will create the device profile for you automatically.",
            allowsAccountCreation: true,
            showsBackButton: true
        )
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Accounts On This Device")
                    .font(.headline)
            }

            VStack(spacing: 10) {
                ForEach(appState.profiles) { profile in
                    Button {
                        appState.selectProfile(profile.id)
                        password = ""
                        hankRemotePassword = ""
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: appState.selectedProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(appState.selectedProfileID == profile.id ? HankTheme.accent : .secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.effectiveLoginIdentifier)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(profile.authMode == .hankRemote ? "Hank Remote" : "Legacy Device Profile")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if profile.rememberedSession {
                                Text("Remembered")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(HankTheme.success)
                            }

                            Button(role: .destructive) {
                                appState.removeProfile(profile.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .hankCard(
                            fill: appState.selectedProfileID == profile.id ? HankTheme.accent.opacity(0.16) : HankTheme.surface,
                            padding: 14
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .hankCard(fill: HankTheme.surface.opacity(0.86))
    }

    @ViewBuilder
    private func profileAccessCard(for profile: UserProfile) -> some View {
        switch profile.authMode {
        case .local:
            localLoginCard(for: profile)
        case .hankRemote:
            hankRemoteProfileLoginCard(for: profile)
        }
    }

    private func localLoginCard(for profile: UserProfile) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Legacy Device Profile")
                    .font(.headline)
                Text("This profile can still open local dashboard, Home Assistant, and SMB settings. HankAI and Notes need Hank Remote.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            Toggle("Remember this profile on this device", isOn: $rememberSession)
                .toggleStyle(.switch)

            Button("Sign In") {
                appState.login(profileID: profile.id, password: password, rememberSession: rememberSession)
                password = ""
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(password.isEmpty)
        }
        .hankCard(fill: HankTheme.surface)
    }

    private func hankRemoteProfileLoginCard(for profile: UserProfile) -> some View {
        hankRemoteAccessCard(
            title: "Sign In To Hank Remote",
            message: "Use your Hank Remote credentials for \(profile.effectiveLoginIdentifier). The local device profile stays in sync behind the scenes.",
            allowsAccountCreation: false,
            showsBackButton: false
        )
    }

    private func hankRemoteAccessCard(
        title: String,
        message: String,
        allowsAccountCreation: Bool,
        showsBackButton: Bool
    ) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField("Cloud URL", text: $hankRemoteCloudURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)

            TextField("Email", text: $hankRemoteEmail)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $hankRemotePassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Toggle("Remember this device on this iPhone", isOn: $rememberSession)
                .toggleStyle(.switch)

            Button {
                submitHankRemote(createAccount: false)
            } label: {
                HStack {
                    if isSubmittingHankRemote {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Sign In")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(isSubmittingHankRemote || hankRemoteCloudURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hankRemoteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hankRemotePassword.isEmpty)

            if allowsAccountCreation {
                Button {
                    submitHankRemote(createAccount: true)
                } label: {
                    HStack {
                        if isSubmittingHankRemote {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Create Account")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(isSubmittingHankRemote || hankRemoteCloudURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hankRemoteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hankRemotePassword.isEmpty)
            }

            if showsBackButton {
                Button("Back") {
                    firstLaunchMode = .chooser
                }
                .buttonStyle(.plain)
                .foregroundStyle(HankTheme.accent)
            }
        }
        .hankCard(fill: HankTheme.surface)
    }

    private func syncAuthenticationFields() {
        if let savedSettings = try? services.hankRemoteSettingsSnapshot(in: modelContext) {
            let normalizedCloudURL = HankRemoteService.normalizedCloudURL(from: savedSettings.cloudURL) ?? savedSettings.trimmedCloudURL
            if !normalizedCloudURL.isEmpty {
                hankRemoteCloudURL = normalizedCloudURL
            }
        }

        if let selectedProfile {
            switch selectedProfile.authMode {
            case .local:
                password = ""
            case .hankRemote:
                let desiredEmail = selectedProfile.remoteEmail ?? selectedProfile.effectiveLoginIdentifier
                if !desiredEmail.isEmpty {
                    hankRemoteEmail = desiredEmail
                }
                hankRemotePassword = ""
            }
        }
    }

    private func submitHankRemote(createAccount: Bool) {
        isSubmittingHankRemote = true

        let cloudURL = hankRemoteCloudURL
        let email = hankRemoteEmail
        let password = hankRemotePassword
        let shouldRemember = rememberSession

        Task {
            await appState.signInToHankRemote(
                cloudURL: cloudURL,
                email: email,
                password: password,
                rememberSession: shouldRemember,
                createAccount: createAccount
            )
            await MainActor.run {
                isSubmittingHankRemote = false
                hankRemotePassword = ""
            }
        }
    }
}

private enum FirstLaunchMode {
    case chooser
    case hankRemote
}
