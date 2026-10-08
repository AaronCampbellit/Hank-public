# Hank iOS Native Options Audit

Date: 2026-06-07

## Scope

This audit was based on a simulator run and a code pass through the main SwiftUI surfaces. I built and launched the `Hank` scheme with XcodeBuildMCP, then walked Dashboard, Calendar, Notes list/detail, File Server SMB/local files, More, Settings, and Hank Assistant.

Runtime proof:

- Build/run succeeded for bundle `com.dropfile.Hank`.
- Simulator used by the launcher: iPhone 17, iOS 26.x.
- Build log: `/Users/aaroncampbell/Library/Developer/XcodeBuildMCP/workspaces/Hank-502725e305bd/logs/build_run_sim_2026-06-07T22-09-55-770Z_pid97413_d9bbf9ec.log`

Project context:

- The app target is already at `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, so iOS 26 SwiftUI options are in scope.
- The app already uses several native controls well: `NavigationStack`, `List`, `ContentUnavailableView`, `DatePicker`, `Picker`, `PhotosPicker`, `ShareLink` in Settings, `confirmationDialog`, and native alerts.
- The biggest cleanup opportunity is not "remove all custom UI." It is moving custom shells, settings containers, file/import/share wrappers, search bars, and tab overflow behavior back onto system-provided SwiftUI or UIKit system surfaces where the app does not need domain-specific behavior.

## Priority Findings

### P1: Replace the custom root tab bar and More overflow with native TabView customization

Current state:

- `RootTabView` manually switches on `selectedTab` and owns all root stores in `Hank/Features/Dashboard/DashboardView.swift`.
- The bottom bar is a custom `safeAreaInset` with `RootTabBar`, fixed primary tabs, a custom "More" popover, custom height measurement, and keyboard visibility handling.
- Settings has a custom "Tabs" section with up/down buttons because the tab shell itself is custom.

Code references:

- `Hank/Features/Dashboard/DashboardView.swift`: `RootTabView` around lines 87-170.
- `Hank/Features/Dashboard/DashboardView.swift`: `RootTabBar` around lines 712-899.
- `Hank/Features/Settings/SettingsView.swift`: tab ordering UI around lines 243-277.

Native iOS option:

- Use SwiftUI `TabView` with `Tab` entries and `customizationID`.
- For the current iOS 26 target, evaluate `.tabViewStyle(.sidebarAdaptable)` plus `.tabViewCustomization(_:)` to persist user tab order/visibility instead of maintaining custom tab order storage and up/down controls.
- If iPhone compact behavior still requires a Hank-specific first-four policy, keep the policy in the model but render it through native `TabView` first, then only add custom overflow if the native behavior cannot meet the requirement.

Why it matters:

- Native tabs bring correct accessibility, Dynamic Type behavior, keyboard/safe-area behavior, selected-state semantics, and standard overflow/adaptable behavior.
- This would remove a lot of fragile shell code: custom overlay dismissal, custom height preferences, keyboard notification handling, custom More bubbles, and settings-only tab reordering controls.

Apple references:

- [TabView](https://developer.apple.com/documentation/SwiftUI/TabView?changes=latest_minor&language=ob_2)
- [tabViewCustomization(_:)](https://developer.apple.com/documentation/swiftui/view/tabviewcustomization%28_%3A%29)

### P1: Convert Settings from custom cards/collapsible sections to native Form/Section navigation

Current state:

- Settings is a `ScrollView` plus vertical stack of custom `settingsCard` blocks.
- Collapsible sections are custom buttons with chevrons and `AnyView` type erasure.
- Long form-like content, including Hank Remote, Home Assistant, SMB, notes, calendars, and assistant settings, is rendered in cards instead of native `Form` sections.

Code references:

- `Hank/Features/Settings/SettingsView.swift`: custom settings layout around lines 60-108.
- `Hank/Features/Settings/SettingsView.swift`: `collapsibleSection` around lines 175-204.
- `Hank/Features/Settings/SettingsView.swift`: `settingsCard` around lines 1711-1724.
- `Hank/Features/Settings/SettingsView.swift`: SMB/Home Assistant forms around lines 1455-1574.

Native iOS option:

- Use `Form` with `Section`, `DisclosureGroup`, `NavigationLink`, `LabeledContent`, `Picker`, `Toggle`, and native destructive rows.
- Move heavy subsections into drill-in settings screens where needed, rather than expanding everything inline.
- Keep `confirmationDialog` and the delete authorization sheet for high-risk actions; those are appropriate native patterns.

Why it matters:

- Settings will get native spacing, keyboard avoidance, row grouping, VoiceOver grouping, Dynamic Type scaling, and platform-standard form behavior.
- It will also reduce the need for `AnyView` in large settings trees and make validation/status rows easier to scan.

### P1: Move file import/share/preview wrappers to SwiftUI native modifiers where possible

Current state:

- File Browser and Assistant both wrap `UIDocumentPickerViewController`.
- File Browser, Assistant, and Notes wrap `QLPreviewController`.
- File Browser and Notes wrap `UIActivityViewController`.
- File Browser has a custom selection action bar for Copy, Move, Share, Delete, and Cancel.

Code references:

- `Hank/Features/FileBrowser/FileBrowserView.swift`: sheet wiring around lines 274-325.
- `Hank/Features/FileBrowser/FileBrowserView.swift`: `LocalFileImportPicker` around lines 1115-1151.
- `Hank/Features/FileBrowser/FileBrowserView.swift`: `SelectionActionBar` around lines 1153-1210.
- `Hank/Features/FileBrowser/FileBrowserView.swift`: `ActivityView` and camera wrappers around lines 1489-1535.
- `Hank/Features/HankAssistant/HankAssistantView.swift`: document/camera/preview sheets around lines 152-188 and wrappers around lines 633-710.
- `Hank/Features/Notes/NotesView.swift`: share/Quick Look wrappers around lines 1001-1061 and 2371-2395.

Native iOS option:

- Replace document picker wrappers with SwiftUI `.fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)`.
- Replace simple Quick Look wrapper use with `.quickLookPreview(_:)`.
- Replace basic share sheet wrappers with `ShareLink` and `Transferable` models when the shared item can be represented as a URL/data item.
- Use native edit/selection patterns for file lists where practical: `EditButton`, list selection, `swipeActions`, `contextMenu`, and a bottom toolbar action group instead of a custom glass card.

Why it matters:

- The app gets system dismissal, security-scoped URL semantics, current Quick Look behavior, share presentation adaptation, and less UIKit delegate code.
- Custom wrappers are still acceptable for camera capture and cases where the app needs UIKit-specific behavior. The recommendation is to replace the simple wrappers first.

Apple references:

- [fileImporter(isPresented:allowedContentTypes:onCompletion:)](https://developer.apple.com/documentation/swiftui/view/fileimporter%28ispresented%3Aallowedcontenttypes%3Aoncompletion%3A%29)
- [quickLookPreview(_:)](https://developer.apple.com/documentation/swiftui/view/quicklookpreview%28_%3A%29)
- [ShareLink](https://developer.apple.com/documentation/swiftui/sharelink?changes=latest_major)

### P1: Fix File Server's local-files header mismatch

Runtime finding:

- In the File Server tab, selecting "iPhone Files" still leaves the top title/subtitle as "SMB Connections" and "Choose a connection".
- The body correctly says "Local Files", but the top-level heading contradicts it.

Code reference:

- `Hank/Features/FileBrowser/FileBrowserView.swift`: `selectedPane` switches the body around lines 44-83, but the surrounding navigation/header state remains shared.

Recommended fix:

- Use pane-specific navigation title/subtitle/chrome.
- If this screen moves closer to native `TabView` or `NavigationSplitView`, make SMB and iPhone Files separate routes or child tabs so each has its own native title.

### P2: Replace custom search bars with `.searchable`

Current state:

- Notes injects a custom `NotesListSearchBar` through `safeAreaInset`.
- File Browser uses a custom search text field in its content/header area.

Code references:

- `Hank/Features/Notes/NotesView.swift`: notes search inset around lines 155-171.
- `Hank/Features/FileBrowser/FileBrowserView.swift`: search field is rendered as part of the browser panes and appeared in runtime snapshots as "Search folders and files".

Native iOS option:

- Use `.searchable(text:placement:prompt:)` on the relevant `NavigationStack`, `List`, or split-view column.
- Add search suggestions/scopes where it helps, such as note tags or file source.

Why it matters:

- Native search gets the correct nav-bar placement, cancel behavior, keyboard focus, accessibility, and platform adaptation.

Apple reference:

- [Adding a search interface to your app](https://developer.apple.com/documentation/SwiftUI/Adding-a-search-interface-to-your-app)

### P2: Keep the rich text editor bridge, but move formatting into native keyboard/toolbars

Current state:

- Notes uses a UIKit `UITextView` bridge for attributed text, which is reasonable because plain SwiftUI `TextEditor` is not a full rich-text editor.
- The formatting bar is a custom horizontal scroll view with custom `FormatButton` controls.

Code references:

- `Hank/Features/Notes/NotesView.swift`: formatting bar around lines 439-470.
- `Hank/Features/Notes/NotesView.swift`: `FormatButton` around lines 969-997.
- `Hank/Features/Notes/NotesView.swift`: `RichTextEditor` around lines 1063-1078.

Native iOS option:

- Keep `UITextView` for attributed editing if it is still the least risky option.
- Move formatting commands into `.toolbar` with keyboard placement where possible.
- Add `accessibilityLabel` to each symbol-only formatting button.
- Consider UIMenu/edit-menu actions for link, checklist, heading, and tag commands so they feel like iOS editing commands instead of app-specific icon chips.

Why it matters:

- The editor keeps its rich text capability while reducing custom chrome and improving keyboard ergonomics.

### P2: Calendar can use more system UI, but the custom month grid may be justified

Current state:

- Calendar event create/edit already uses `Form`, `DatePicker`, `Toggle`, and a navigation-link style calendar picker.
- The visible month calendar is fully custom, with manual month navigation, day cells, selected/today rings, and event dots.

Code references:

- `Hank/Features/Calendar/CalendarView.swift`: month section around lines 182-190.
- `Hank/Features/Calendar/CalendarView.swift`: custom header/day cells around lines 770-829.
- `Hank/Features/Calendar/CalendarView.swift`: native event editor around lines 576-655.

Native iOS option:

- If event dots are not essential, evaluate a graphical `DatePicker` for single-day selection.
- If calendar selection is the main task, use `EKCalendarChooser` through EventKitUI instead of custom calendar-source rows.
- For event create/edit, consider EventKitUI event editors where the goal is to match Calendar.app behavior exactly.

Why it matters:

- The custom month grid is a maintenance cost and has already been a crash-sensitive area in this app. It is justified only if the event-dot visual and Hank-specific layout are core.

Apple references:

- [Accessing Calendar using EventKit and EventKitUI](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui)
- [EKCalendarChooser](https://developer.apple.com/documentation/eventkitui/ekcalendarchooser?changes=la_9___8__5__1&language=objc)

### P2: Dashboard custom tiles should stay custom, but editing can use more native actions

Current state:

- Dashboard cards are domain-specific Home Assistant controls. Custom cards are appropriate here.
- Current dirty working-tree changes already move tile rename/delete toward native alert-style flows.
- The tile UI still uses custom edit affordances, custom delete overlay buttons, and custom row/card styling.

Code references:

- `Hank/Features/Dashboard/DashboardView.swift`: dashboard toolbar/sheets/alerts around lines 1030-1135.
- `Hank/Features/Dashboard/DashboardView.swift`: `DashboardTileCard` around lines 1388-1507.

Native iOS option:

- Keep the tile card layout.
- Prefer `contextMenu`, `swipeActions` where list-like, native alerts, and toolbar edit mode for title/delete/resize commands.
- Use native `Slider` and `Toggle` controls inside tiles where the entity supports them. The brightness slider is already a good native control.

Why it matters:

- The dashboard is one place where custom presentation is useful. The improvement is to make editing commands native without flattening the actual dashboard experience.

### P2: Assistant attachment handling is partly native already; finish the migration

Current state:

- The assistant composer uses `PhotosPicker`, which is the right native option.
- Document import, camera capture, and attachment preview still use UIKit wrappers.
- The chat cards are custom, which is probably appropriate because media results, confirmations, and progress cards are Hank-specific.

Code references:

- `Hank/Features/HankAssistant/HankAssistantView.swift`: composer controls around lines 373-420.
- `Hank/Features/HankAssistant/HankAssistantView.swift`: wrapper types around lines 633-710.

Native iOS option:

- Keep `PhotosPicker`.
- Replace document import with `.fileImporter`.
- Replace simple previews with `.quickLookPreview`.
- Keep camera capture wrapper unless a product decision says photo-library-only attachments are enough.

Apple reference:

- [PhotosPicker](https://developer.apple.com/documentation/PhotosUI/PhotosPicker)

### P3: Reduce custom "glass card everywhere" styling where native surfaces carry meaning

Current state:

- `hankCard`, `hankGlassCapsule`, and `hankNavigationChrome` are used broadly.
- This creates a strong Hank visual identity, but it also makes settings, file rows, note toolbars, tab bars, and dashboard controls feel visually similar even when their interaction models differ.

Code reference:

- `Hank/App/HankApp.swift`: `HankTheme`, `hankCard`, `hankGlassCapsule`, and navigation chrome around lines 865-1020.

Recommended fix:

- Keep the theme for dashboard cards, assistant cards, and branded empty states.
- Use more native `Form`, `List`, toolbar, tab, and sheet backgrounds in Settings, file lists, and utility surfaces.
- Audit contrast and Dynamic Type on every custom dark/glass component.

### P3: Accessibility pass for symbol-only custom buttons

Current state:

- Some controls have explicit labels, especially assistant attachment buttons.
- Other custom symbol-only buttons rely on inferred labels or have app-specific labels like "Go Up"/"Go Down" for tab ordering.

Recommended fix:

- Add explicit labels/hints for custom icon buttons in the root tab overflow, calendar month navigation, notes formatting bar, file selection bar, and dashboard edit/delete affordances.
- Use native controls where possible so VoiceOver roles, traits, and rotor behavior come for free.

## Recommended Implementation Order

1. Root shell: prototype `TabView` with all six tabs, native tab customization, and current store ownership preserved.
2. File Browser: fix the local-files header mismatch, then replace `LocalFileImportPicker`, simple Quick Look sheets, and simple share sheets.
3. Settings: move Profile/Tabs/Calendar/SMB into native `Form` sections or drill-in screens. Keep delete-profile authorization as a guarded sheet.
4. Notes: replace the custom list search bar with `.searchable`; move formatting controls to a native keyboard toolbar and add accessibility labels.
5. Calendar: decide whether event dots justify the custom month grid. If not, trial graphical `DatePicker`; if yes, keep the custom grid but improve accessibility labels and reduce styling risk.
6. Assistant: keep custom message/media cards, but use SwiftUI-native file import and Quick Look preview modifiers.

## Custom UI That Should Probably Stay

- Dashboard tiles and Home Assistant control cards, because they map to Hank-specific device/entity behavior.
- Assistant media result, confirmation, and progress cards, because they represent server-side Hank actions and not generic iOS content.
- Rich text editing's `UITextView` bridge, unless SwiftUI gains a first-party rich text editor that covers the same checklist/link/tag behavior.
- Camera capture wrappers, unless the app no longer needs direct camera capture.
