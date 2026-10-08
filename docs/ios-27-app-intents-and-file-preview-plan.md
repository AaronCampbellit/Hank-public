# iOS 27 App Intents And File Preview Plan

Date: 2026-06-12

This note explores three iOS 27-era opportunities for Hank iOS:

1. Core Hank App Intents.
2. Installed app slash commands as system actions.
3. Native file preview improvements using the server preview contract.

## TLDR

- Hank does not need to raise its deployment target to iOS 27 yet. Keep the app at iOS 26.0 and add iOS 27-only APIs behind availability checks.
- The best iOS 27 opportunity is App Intents. Hank should expose a small system action layer for "Ask Hank", "Open Hank", "Search notes", "Search files", and "Run installed workflow" instead of mirroring every tab.
- Installed workflows should stay package-driven. iOS should not hardcode `/Hermes`, `/gramaton`, or `/ydownload`; it should consume `/v1/home/apps` metadata and expose a generic "Run Hank workflow" intent with dynamic choices.
- File preview is the biggest practical UX fix. Hank currently downloads previewable files to memory or a temp file before Quick Look/PDFKit. For large video/audio/PDF/image previews, iOS should use a source-aware streaming route instead.
- The likely server-side addition for native preview is a short-lived signed preview URL or ticket. Browser cookie-auth preview works for the dashboard, but native `AVPlayer`, `QuickLook`, `PDFKit`, and image loaders need either URL-auth or custom resource loading.
- Build and test with Xcode 27 beta on the iOS 27 beta phone, but keep Xcode 26 compatibility until we intentionally adopt iOS 27-only symbols.

## Apple Documentation Checked

- [iOS & iPadOS 27 beta release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes): iOS/iPadOS 27 SDK ships with Xcode 27. App Intents beta notes call out known issues around non-SF Symbol entity images in Siri, `Set` parameter defaults, and `RelevantEntities` suggestions.
- [Xcode 27 beta release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes): Xcode 27 beta includes Swift 6.4 and SDKs for iOS 27/iPadOS 27/etc. It requires macOS Tahoe 26.4 or later and supports on-device debugging for iOS 17+.
- [App Intents updates](https://developer.apple.com/documentation/updates/appintents): June 2026 App Intents updates emphasize Apple Intelligence app schemas, `SyncableEntity`, ownership for sensitive/destructive actions, `LongRunningIntent`, `CancellableIntent`, `UndoableIntent`, `supportedModes`, `allowedExecutionTargets`, `EntityCollection`, and `IndexedEntityQuery`.
- [Adopting App Intents to support system experiences](https://developer.apple.com/documentation/AppIntents/adopting-app-intents-to-support-system-experiences): Apple’s iOS 27 sample shows organizing intents/entities in a shared package so the main app and widgets can reuse them, and making app actions/content discoverable in Shortcuts, Spotlight, Siri Suggestions, visual intelligence, and Action button flows.
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass): Apple recommends first building with the latest SDK and reviewing the app, relying on standard SwiftUI/UIKit components to pick up system glass behavior, and reducing custom backgrounds that interfere with system-provided materials.
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views): custom components can use `glassEffect` and related APIs where standard system material is not enough.
- [AVAssetResourceLoaderDelegate](https://developer.apple.com/documentation/AVFoundation/AVAssetResourceLoaderDelegate): native media playback can use custom resource loading when standard URL loading cannot express the auth/range behavior.

## Current Hank State

### App Intents

Current code scan found no `AppIntent`, `AppShortcut`, `AppEntity`, widget, or ActivityKit implementation in `Hank/`.

The app is already SwiftUI-heavy and has a six-tab app shell with Dashboard, Calendar, Notes, File Server, Hank Assistant, and Settings. The app’s shared state and navigation are app-local rather than represented as a system action layer.

Relevant current files:

- `Hank/App/HankApp.swift`
- `Hank/Features/HankAssistant/HankAssistantStore.swift`
- `Hank/Features/HankAssistant/HankAssistantView.swift`
- `Hank/Features/FileBrowser/FileBrowserStore.swift`
- `Hank/Features/FileBrowser/FileBrowserView.swift`
- `Hank/Core/Services/Services.swift`

### Installed App Slash Commands

Hank now has an iOS-side model for installed apps:

- `HankRemoteInstalledAppsResponse`
- `HankRemoteInstalledApp`
- `HankRemoteInstalledAppSlashCommand`
- `HankRemoteService.installedApps(context:)`

The assistant store now loads enabled installed app slash commands from `GET /v1/home/apps`, filters invalid commands, and appends built-in Hank commands. This is the right base for a system intent, because it keeps optional workflows server/package-driven instead of hardcoded.

Current limitation: the dynamic command list lives in the assistant store. App Intents can run outside the visible assistant UI path, so we need a small shared resolver/cache that is safe for intent execution.

### File Preview

Current File Browser preview behavior:

- `FileBrowserStore.open(_:)` calls `buildPreview(for:using:)`.
- Text previews download the whole file into memory.
- Images, PDFs, and Quick Look-compatible files download the whole file to a temp URL.
- `FilePreviewScreen` renders text, Quick Look, or PDFKit from local files.

That works for small files, but it conflicts with the recent server preview direction for large payloads. The handoff contract says native iOS preview should prefer:

`GET /v1/home/files/preview?path=...&source_id=...`

and preserve `source_id`.

## Opportunity 1: Core Hank App Intents

### What To Build

Start with a narrow system action layer:

1. `OpenHankIntent`
   - Uses an `AppEnum` for destination: Dashboard, Calendar, Notes, File Server, Hank, Settings.
   - Opens the app to the requested tab.
   - Good for Siri, Spotlight, Shortcuts, Action button, and widgets.

2. `AskHankIntent`
   - Parameter: prompt text.
   - First pass should open the app to Hank with the prompt prefilled, not submit in the background.
   - Background submission can come later after we design auth/session and confirmation behavior.

3. `SearchHankNotesIntent`
   - Parameter: query text.
   - Open app to Notes search results.
   - Later: add `HankNoteEntity` for selected note opening.

4. `SearchHankFilesIntent`
   - Parameters: query text, optional file source.
   - Open app to File Server search.
   - Entity support should include a narrow `HankFileSourceEntity`, not the whole SMB connection model.

5. `OpenHankFileServerIntent`
   - Optional source parameter.
   - Useful for widgets/Action button.

### Why This Fits iOS 27

iOS 27 App Intents documentation emphasizes system experiences beyond Shortcuts: Siri, Spotlight, widgets, Action button, visual intelligence, and Apple Intelligence. Hank’s current app model has clear verbs and destinations that map well to App Intents.

### Code Changes Needed

Add a small App Intents surface. Two implementation shapes are possible:

1. Main app target only for first pass.
   - Fastest.
   - Good if no widget/control ships yet.
   - Less reusable later.

2. New shared Swift package or folder plus optional App Intents extension.
   - Better long-term.
   - Matches Apple’s iOS 27 sample structure.
   - Lets future widgets/control surfaces reuse entities/intents.

Recommended first implementation:

- Add `HankIntents/` or `Hank/Core/Intents/` with thin intent definitions.
- Add `HankIntentRouter` or `PendingIntentHandoff` as the single bridge into the app scene.
- Add route handling in `HankApp.swift` or the root tab shell to consume one pending intent payload.
- Add an `AppEnum` for tabs.
- Keep inline/background actions conservative; anything that sends messages, writes notes, deletes/moves files, or invokes installed workflows should open Hank for review first.

### Security And Auth Rules

- Intents must never expose stored session tokens.
- If Hank Remote is signed out, intent result should ask the user to open Hank and sign in.
- Destructive or sensitive actions should open the app and use existing confirmation flows.
- For iOS 27 beta, use SF Symbols for intent/entity images because Apple notes non-SF Symbol custom entity images may not always appear in Siri.
- Avoid `Set` parameters in first-pass intents or explicitly provide defaults with `@Parameter`, because iOS 27 beta notes mention default-value issues for Set-typed parameters.

### Tests

- Unit test intent payload creation and route mapping without launching Siri/Shortcuts.
- UI smoke test that a pending `AskHankIntent` opens the Hank tab and pre-fills the composer.
- Device test from Shortcuts and Spotlight on the iOS 27 phone.

## Opportunity 2: Installed App Slash Commands As System Actions

### What To Build

Expose server-installed workflows as dynamic system choices without hardcoding app names.

First-pass intent:

`RunHankWorkflowIntent`

Parameters:

- `workflow`: `HankInstalledWorkflowEntity`
- `prompt`: String

Example user-facing flows:

- "Run Hank workflow"
- "Ask Hermes in Hank"
- "Search Gramaton in Hank"
- "Run installed workflow with Hank"

### Entity Shape

`HankInstalledWorkflowEntity` should be smaller than `HankRemoteInstalledApp`:

- stable ID: `appID:commandID`
- app ID
- command ID
- slash command, for display only
- app name
- description
- enabled status
- requires admin flag if available from `commands`

Do not expose package config, secrets, settings schema, or public config in the entity.

### Dynamic Resolution

App Intent entity queries should not depend on the live `HankAssistantStore`.

Needed changes:

- Extract app-command mapping from `HankAssistantStore` into a pure shared resolver, for example `HankInstalledWorkflowResolver`.
- Persist the latest enabled workflow list in an app-group-safe cache or normal app storage.
- On app launch and assistant refresh, update the cache from `GET /v1/home/apps`.
- In the entity query, return cached entities quickly.
- Optionally refresh from the network only when a valid Hank Remote context is available and the system allows background execution.

### Runtime Behavior

Recommended first pass:

- The intent opens Hank to the assistant tab and pre-fills `/command prompt`.
- Example: selecting Hermes plus prompt "summarize this" opens Hank with `/Hermes summarize this`.
- The user taps send in Hank.

Why not background invoke first:

- Installed workflows may require admin permissions.
- Some app commands are long-running.
- Some commands may need confirmations or settings repair.
- iOS 27 beta App Intents has new long-running/cancellable/foreground-background APIs, but Hank should prove the safe open-app path before background execution.

Second pass:

- Background `RunHankWorkflowIntent` for read-only or non-destructive workflows.
- Adopt `supportedModes` so the same intent can adapt when launched foreground vs background.
- For long workflows, consider `LongRunningIntent` and progress reporting, but only after server job status is exposed cleanly to iOS.

### Tests

- Decode `/v1/home/apps` fixtures into workflow entities.
- Confirm disabled apps and invalid slash commands do not appear.
- Confirm entity IDs remain stable across app refreshes.
- Confirm no hardcoded `/Hermes`, `/gramaton`, or `/ydownload` lists are used.

## Opportunity 4: File Preview Improvements

### Current Problem

File previews download full content before display. That is acceptable for small text/images/documents, but poor for:

- 2 GB videos
- large 4K images
- large PDFs
- audio/video seek
- alternate SMB sources where `source_id` must be preserved

### Server Contract To Use

The server handoff names:

`GET /v1/home/files/preview?path=...&source_id=...`

Server behavior from recent work:

- authenticated inline streaming
- range support
- `Accept-Ranges`
- `Content-Range`
- inline `Content-Disposition`
- preview MIME mapping
- source-aware `source_id`

### Native iOS Auth Issue

The browser preview route was designed around same-origin browser auth. Native iOS preview components do not all let us attach Hank Remote bearer headers:

- `AVPlayer` can play URLs, but authenticated/ranged behavior may need a custom `AVAssetResourceLoaderDelegate` or a signed URL.
- `QuickLook` generally wants local files or accessible URLs.
- `PDFKit` can open local files and URLs, but request-header control is limited.
- `AsyncImage` is convenient but not enough for authenticated custom requests.

Recommended server addition:

- Add a short-lived preview ticket endpoint for iOS:
  - `POST /v1/home/files/preview-ticket`
  - body: `path`, `source_id`, optional MIME/filename hint
  - returns: short-lived HTTPS URL that streams the preview and supports ranges without requiring app-side custom headers
  - expires quickly and is scoped to one file/source/user

Alternative if server URL tickets are not desired:

- Implement custom media loading for AV playback with `AVAssetResourceLoaderDelegate`.
- Keep downloading PDFs/images/QuickLook files as fallback until each renderer has safe auth.

### iOS Preview Architecture

Add a streaming preview mode:

```swift
enum FilePreviewContent {
    case text(String)
    case image(URL)
    case pdf(URL)
    case quickLookFile(URL)
    case streamed(StreamedFilePreview)
    case unsupported
}

struct StreamedFilePreview {
    let url: URL
    let fileName: String
    let sourceID: String?
    let mediaKind: FilePreviewMediaKind
    let expiresAt: Date
}
```

Preview rules:

- Text: keep current download path for small files, add size cap and a "too large for text preview" path.
- Image: use signed streaming URL for large images; local temp download remains fine for small images.
- Video/audio: use `AVPlayer` against signed streaming URL; verify seeking sends range requests.
- PDF: use signed streaming URL if reliable with PDFKit; otherwise small download fallback and large "Open in browser/dashboard" fallback.
- Office/archives/other Quick Look: keep current local-temp path unless server offers safe signed download URLs.

### Code Changes Needed

Client service:

- Add `HankRemoteService.filePreviewTicket(path:sourceID:context:)`.
- Add models for preview ticket response.
- Keep `source_id` normalization.

File Browser store:

- Include `sourceID` in preview cache keys.
- Decide preview strategy based on kind and size.
- Add streaming preview state.
- Avoid loading large text files fully into memory.

File Browser UI:

- Add `VideoPlayer`/`AVPlayer` surface for video.
- Add audio player surface.
- Keep current Quick Look/PDFKit local-file flow as fallback.
- Add expiration handling: if a preview ticket expires, refetch it.

Tests:

- Classifier tests for streamed video/audio/image/PDF thresholds.
- Service tests that preview ticket requests include `source_id`.
- Cache key tests include source identity.
- UI/manual test: seek in a large video from an alternate SMB source.

## Liquid Glass / iOS 27 Visual Follow-Up

This was not one of the three implementation areas, but it affects all of them.

Hank already uses custom glass/card styling (`hankGlassCapsule`, `hankCard`, custom backgrounds). Apple’s Liquid Glass guidance says standard SwiftUI/UIKit controls pick up system behavior automatically and custom backgrounds can interfere with system materials.

Recommended audit after building with Xcode 27:

- Assistant composer and slash-command chips.
- File preview sheets.
- Navigation split views.
- Tab/root shell backgrounds.
- Toolbars and sheets.

Do not rewrite the whole UI. First build with Xcode 27, test on the iOS 27 beta phone, then remove or reduce custom backgrounds only where they visibly fight system glass.

## Suggested Implementation Phases

### Phase 0: iOS 27 Device Baseline

- Install Xcode 27 beta side-by-side.
- Build Hank with the iOS 27 SDK.
- Run on the iOS 27 beta phone.
- Capture screenshots of Assistant, File Server, Settings, preview sheets, and slash-command chips.
- Do not change deployment target yet.

### Phase 1: Core App Intents

- Add route handoff infrastructure.
- Add `OpenHankIntent`, `AskHankIntent`, `SearchHankNotesIntent`, `SearchHankFilesIntent`.
- Add `AppShortcutsProvider`.
- Add tests for route payloads.
- Verify from Shortcuts, Spotlight, Siri, and Action button.

### Phase 2: Installed Workflow Intent

- Extract installed workflow resolver/cache.
- Add `HankInstalledWorkflowEntity`.
- Add `RunHankWorkflowIntent` as open-app handoff.
- Verify installed Hermes appears only when installed/enabled, and disabled Gramaton disappears without an app update.

### Phase 3: Streaming File Preview

- Add or request server preview-ticket endpoint.
- Add iOS preview-ticket service method.
- Add streaming preview state and AVPlayer surface.
- Preserve `source_id` in all preview requests and cache keys.
- Keep local Quick Look fallback.

### Phase 4: Background/Long-Running Enhancements

- Evaluate `LongRunningIntent`, `CancellableIntent`, and `supportedModes` for server workflows and media/file jobs.
- Add background execution only for safe read-only or explicit user-approved flows.

## Open Questions

- Should Hank ship App Intents in the main app target first, or add a shared package immediately?
- Should "Ask Hank" submit in the background, or always open app for review in v1?
- Should server add a native preview ticket URL, or should iOS own custom `AVAssetResourceLoaderDelegate` auth?
- Which file size threshold should switch from download-preview to stream-preview?
- Should installed workflows require admin-role visibility in iOS App Intents, or rely entirely on server-side rejection?

## Recommended Decision

Do this in order:

1. Build and run on iOS 27 with Xcode 27 beta to catch visual/toolchain issues.
2. Implement core App Intents with open-app handoff only.
3. Extract installed workflow metadata into an intent-safe cache and add `RunHankWorkflowIntent`.
4. Add server preview tickets, then implement streaming video/audio preview in iOS.

This gives Hank immediate system integration without weakening auth, and it fixes the largest real UX issue in the File Server: large previews.
