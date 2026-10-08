# Hank Tab Assistant Checklist

This document turns the Hank Assistant backend design in [phase-6-hank-assistant.md](/Users/aaroncampbell/Documents/HankServerside/docs/phase-6-hank-assistant.md) into concrete Hank app work.

Use [SERVER_SYNC.md](/Users/aaroncampbell/Documents/Hank/SERVER_SYNC.md) as the shared contract ledger. Use this file to implement the Hank side.

## Summary

Hank will gain a real `Hank` chat tab backed by the local Ollama-powered assistant runtime in `hankserverside`.

The app owns:
- chat UI
- session list and message history UI
- streaming response rendering
- local calendar indexing and EventKit tool execution
- deep-link navigation into Notes and Files from assistant results

The server owns:
- chat orchestration
- message persistence
- retrieval and ranking
- note and SMB tool execution
- audit history

## Key Constraint

Calendar access is still device-local in Hank.

That means:
- the app must index device calendars into the assistant backend
- the app must execute EventKit write actions locally
- the server must not pretend it can create or edit calendar events on its own

## Workstream 1: Root Tab Integration

### Add The Real Hank Tab

- Replace the current `ChatPlaceholderView()` in `RootTabView` with a real `HankAssistantView`.
- Keep the feature as a native tab in the existing shell.
- Preserve current tab order behavior and overflow behavior.

### State Ownership

Add a dedicated store for the feature, for example:
- `HankAssistantStore`

It should own:
- sessions
- selected session
- draft text
- streaming response state
- pending confirmation state
- pending client tool requests
- deep-link targets returned by the server

## Workstream 2: Hank Remote Client

Extend `HankRemoteService` with assistant routes.

Suggested client methods:
- `assistantSessions(context:)`
- `createAssistantSession(title:, context:)`
- `assistantMessages(sessionID:, context:)`
- `sendAssistantMessage(sessionID:, content:, clientCapabilities:, deviceContext:, context:)`
- `assistantRun(runID:, context:)`
- `confirmAssistantRun(runID:, action:, context:)`
- `submitAssistantClientToolResults(runID:, results:, context:)`
- `uploadAssistantCalendarIndex(entries:, deviceContext:, context:)`
- `openAIAuthorizationURL(context:)`

The assistant send path should support streaming so the tab can show:
- typing deltas
- tool-in-progress state
- confirmation requests
- client tool requests

The Assistant settings path should call `GET /v1/oauth/openai/start`, read `authorization_url`, and open it in Hank's in-app browser so the server can complete the `/v1/oauth/openai/callback` token exchange.

## Workstream 3: Chat UI

### Session Shell

Add:
- session list
- conversation view
- composer
- empty state

The conversation view should render:
- user messages
- assistant messages
- transient system rows such as "Searching notes" or "Checking calendar"
- confirmation cards
- structured result cards

### Structured Result Cards

Render rich cards instead of plain text when the server returns structured targets.

Initial card types:
- note result
- calendar result
- SMB folder or file result

Each card should include:
- title
- short summary
- button to open the target in the relevant tab

## Workstream 4: Deep-Link Navigation

The assistant should not only answer with text. It should move the user to the right entity when tapped.

Add app-side navigation hooks for:
- open note by note ID
- open calendar date or event
- open file browser at SMB path

Recommended target handling:
- the assistant store receives a structured target payload
- `RootTabView` or a shared navigation coordinator switches tabs and hands the target to:
  - `NotesStore`
  - `CalendarStore`
  - `FileBrowserStore`

This should reuse the current root-tab shell rather than building a second navigation system inside the chat tab.

## Workstream 5: Calendar Indexing

The server needs searchable calendar context, but EventKit remains local.

### App Responsibilities

- read calendar events from `CalendarStore` or an EventKit-backed helper
- normalize them into lightweight assistant index entries
- upload them to `hankserverside`

Suggested upload points:
- after calendar permission is granted
- after calendar refresh
- when the app becomes active
- after a successful local calendar mutation from the assistant flow

### Data To Send

Per event:
- external event ID
- calendar ID
- calendar title
- title
- location
- notes
- start and end timestamps
- all-day flag

Do not send:
- unnecessary raw attendee metadata in v1
- recurring rule expansions beyond what the server needs to search

## Workstream 6: Client Tool Bridge

The assistant runtime may pause a run and ask the app to execute a local tool.

Initial client tools:
- `calendar.search`
- `calendar.create_event`
- `calendar.update_event`

### Tool Execution Flow

1. User sends a chat message.
2. Server emits `client_tool.required`.
3. App executes the requested EventKit tool locally.
4. App posts the structured result back to the server.
5. Server finalizes the assistant response.

### App Requirements

- validate tool payloads before execution
- show confirmation UI before local calendar writes when the server marks the action as requiring confirmation
- return deterministic result payloads, not free-form text blobs

Suggested result payload fields:
- `tool_name`
- `status`
- `result`
- `error`

## Workstream 7: Confirmation UX

The assistant needs an explicit confirmation path for ambiguous or sensitive changes.

Examples:
- multiple possible shopping lists matched
- calendar event title or date is incomplete
- the assistant wants to create a new note because no target note matched confidently

The app should render a confirmation card with:
- assistant explanation
- action summary
- confirm button
- cancel button

The confirm button should call the run-confirm route, not rerun the whole message.

## Workstream 8: Notes and Files Integration

### Notes

When a note result is tapped:
- switch to `Notes`
- select the note
- reveal the changed content when practical

Potential store work:
- add a public "open note by ID" seam if it does not already exist
- support post-mutation refresh when the assistant appended content remotely

### Files

When a file result is tapped:
- switch to `File Server`
- navigate to the returned SMB path
- highlight the matched folder or file if the payload contains an exact item

Potential store work:
- add a direct path-open seam to `FileBrowserStore`
- reuse existing search index support for local browsing after navigation

## Workstream 9: Session Persistence

Persist enough local state for a good app experience:
- last selected assistant session ID per profile
- draft composer text
- transient stream state only in memory

Do not make the app the source of truth for chat history. The server is the durable owner.

## Workstream 10: Error Handling

Handle these cases explicitly:
- assistant backend unavailable
- Ollama unavailable on the server
- no calendar permission
- client tool request received while the app is backgrounded
- stale run ID
- note or file target no longer exists

User-facing failures should stay plain:
- "Hank couldn't reach the local model."
- "Calendar access is not enabled on this device."
- "That folder is no longer available."

## Validation

### Read-Only

- Ask Hank to find an existing note by title.
- Ask Hank to find a known SMB folder.
- Ask Hank what is on the calendar for a specific date.

### Mutations

- Ask Hank to append to a uniquely matched shopping note.
- Ask Hank to create a calendar event.
- Confirm the EventKit write occurs locally and the server stores the completed run.

### Navigation

- Tap a note result card and confirm the app opens the Notes tab at the correct note.
- Tap a file result card and confirm the app opens the File Server tab at the correct path.
- Tap a calendar result card and confirm the app opens the Calendar tab at the relevant date or event.

## Recommended File Areas

Likely app touch points:
- `Hank/Features/Dashboard/DashboardView.swift`
- `Hank/Core/Services/Services.swift`
- `Hank/Features/Calendar/CalendarStore.swift`
- `Hank/Features/Notes/NotesStore.swift`
- `Hank/Features/FileBrowser/FileBrowserStore.swift`
- new `Hank/Features/HankAssistant/` files for UI and store logic

## Recommendation Summary

- keep the Hank tab native to the current root tab shell
- make the server the source of truth for sessions, runs, and retrieval
- let the app handle EventKit indexing and execution through a client-tool bridge
- return structured result targets so the assistant can open the right note, event, or SMB path in-app
