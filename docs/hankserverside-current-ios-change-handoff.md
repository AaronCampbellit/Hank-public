# HankServerside Current iOS Change Handoff

Date: 2026-06-12

This file tracks Hank iOS follow-up work implied by recent HankServerside changes. It is intentionally scoped to the iOS app. Server-only dashboard, deployment, and agent implementation details are included only when they change app-visible contracts.

## Current Baseline

- Hank iOS should talk to Hank Remote Cloud over normal HTTPS and `/ws/app`; it should not speak SMB, Home Assistant, or other LAN protocols directly for remote use.
- The active server model is a single deployment Home under `/v1/home` plus signed-in user state under `/v1/me`.
- Local credentials and local network reachability stay inside the Hank Remote Agent.
- File and media operations must preserve `source_id` / `destination_source_id` so multi-SMB-share deployments route correctly.
- App WebSocket auth should use `POST /v1/ws/app-ticket` and then open the returned `websocket_path`; do not restore old `session_token` query auth.

## Already Mostly Aligned In The Current iOS Checkout

- Singleton `/v1/home` and `/v1/me` route families are present in `HankRemoteService`.
- `/v1/ws/app-ticket` is present for app WebSocket startup.
- Profile sync routes are present:
  - `GET /v1/me/profile`
  - `PUT /v1/me/profile`
  - `GET /v1/me/profile-secret-vault`
  - `PUT /v1/me/profile-secret-vault`
  - `GET /v1/me/profile-backup`
  - `PUT /v1/me/profile-backup`
- APNs registration and notification settings routes are present.
- Storage health/config/event/admin routes are present.
- Assistant session, run, confirmation, client-tool-result, and calendar-index routes are present.
- Shared Home notes and profile notes are split across `/v1/home/notes` and `/v1/me/notes`.
- `files.move` already waits on job-backed nonterminal statuses and treats `completed`, `failed`, `cancelled`, `canceled`, `rollback_required`, and `rolled_back` as terminal.

## P0 Contract Checks Before More Feature Work

- Sweep the app for stale `/v1/homes`, `/v1/agents`, and `/ws/app?session_token=` assumptions.
- Confirm every Remote file browser path carries a normalized `source_id` and cross-share moves carry `destination_source_id`.
- Confirm profile bootstrap still hydrates SMB settings from `/v1/me/profile` into the local `SavedSMBConnection` model, including `domain` and remote source identity fields.
- Confirm Remote file browsing does not prompt for raw SMB credentials when the server has a valid SMB service profile.
- Confirm the app handles `403`/permission responses by hiding or disabling admin-only actions rather than retrying lower-level protocol paths.

## P1 Server Surfaces Missing Or Needing iOS Decisions

### Quick Links

Server surface:

- `GET /v1/home/quick-links`
- `POST /v1/home/quick-links`
- `POST /v1/home/quick-links/checks`
- `PUT /v1/home/quick-links/order`
- `PUT /v1/home/quick-links/{linkID}`
- `DELETE /v1/home/quick-links/{linkID}`

iOS impact:

- Decide whether Home quick links appear in the Dashboard tab, Settings, or both.
- Preserve the server ordering instead of sorting locally.
- Non-admin users should be read-only unless server permissions say otherwise.

Verification:

- Load quick links after sign-in.
- Reorder links and relaunch the app.
- Confirm a non-admin cannot create, edit, delete, or reorder links.

### Installable Apps: Hermes And Gramaton

Server surface:

- `GET /v1/home/apps`
- `GET /v1/home/apps/{appID}`
- `PUT /v1/home/apps/{appID}/config`
- `POST /v1/home/apps/{appID}/invoke`
- Import/activation is dashboard-oriented:
  - `POST /v1/home/apps/import/preview`
  - `POST /v1/home/apps/import/activate`

iOS impact:

- Optional workflow slash commands should come from installed app metadata, not from hardcoded `/Hermes` or `/gramaton` assumptions.
- Configuration for optional installed apps belongs to Settings > Apps on the server side. iOS can expose read-only status or a lightweight configure link, but should not duplicate package import flows unless explicitly designed.
- Keep core Hank features built in. Treat Hermes and Gramaton as optional installed workflows.

Verification:

- With only Hermes installed, the app should not show Gramaton as available.
- With both installed, assistant slash command UI should include both from server metadata.
- Disabling or uninstalling an app should remove its command entry without an app update.

### External Notes API Tokens

Server surface:

- `GET /v1/home/notes-api-tokens`
- `POST /v1/home/notes-api-tokens`
- `DELETE /v1/home/notes-api-tokens/{tokenID}`

iOS impact:

- Decide whether iOS should manage external notes API tokens. This is likely an admin Settings feature, not part of normal note editing.
- Tokens are notes-only and should not be presented as general Remote API tokens.
- Newly created token plaintext is a one-time secret; do not store or log it unless the user explicitly saves it in a secure place.

Verification:

- Admin can list token metadata and revoke tokens.
- Non-admin cannot create or revoke tokens.
- A created token works only for `/v1/me/notes...` and `/v1/home/notes...`.

### File Preview Streaming

Server surface:

- `GET /v1/home/files/preview?path=...&source_id=...`
- Supports browser-oriented authenticated inline/ranged streaming.
- Returns media-friendly headers such as `Accept-Ranges`, `Content-Range`, and inline `Content-Disposition`.

iOS impact:

- If the File Server tab adds inline preview for large videos/audio/PDFs/images, prefer this preview endpoint over downloading the whole file into memory.
- Preserve `source_id`.
- For native AV playback, check whether bearer or cookie auth is available through the chosen player stack. Browser media elements drove the server design, but native iOS may still need custom resource loading if auth headers are required.

Verification:

- Preview a large video without loading the whole file into memory.
- Seek within the video and confirm ranged requests work.
- Preview a file from a non-default SMB source.

### File Job Controls

Server surface:

- `GET /v1/home/file-jobs`
- `GET /v1/home/file-jobs/{jobID}`
- `POST /v1/home/file-jobs/{jobID}/cancel`
- `POST /v1/home/file-jobs/{jobID}/retry`
- `POST /v1/home/file-jobs/{jobID}/rollback`

iOS impact:

- The app currently polls individual move jobs after `files.move`. Add a File Jobs surface or contextual actions if the iOS File Server UI exposes long-running moves.
- Surface `rollback_required` clearly and offer rollback when the server allows it.
- Do not refresh the file browser as if a move succeeded until the job is terminal and successful.

Verification:

- Start a cross-source directory move and background the app.
- Relaunch, load job status, and show progress/failure.
- Exercise cancel, retry, and rollback against server-supported states.

### Assistant Media Jobs And Media Settings

Server surface:

- `GET /v1/home/assistant/media-jobs/{jobID}`
- `POST /v1/home/assistant/media-jobs/{jobID}/cancel`
- `GET /v1/home/assistant/media-settings`
- `PUT /v1/home/assistant/media-settings`
- Media workflow events continue through assistant messages and realtime events.

iOS impact:

- Assistant media cards should keep using both `poster_url` and `image_url`.
- Media download progress should stay compact, visible, and link back to the destination inside the File Server tab when complete.
- Media settings must allow explicit SMB source selection when exposed in-app; do not default silently to the first share.

Verification:

- `/gramaton <title>` search, selection, download planning, progress, and completion link all work.
- Alternate SMB share destinations list subfolders.
- Cancelling a media job updates the card and does not leave stale progress.

### Recovery Export/Import

Server surface:

- `GET /v1/home/recovery/export`
- `POST /v1/home/recovery/import/preview`
- `POST /v1/home/recovery/import/apply`

iOS impact:

- This is probably dashboard-first. If iOS exposes it, treat it as an admin-only recovery tool.
- Export bundles intentionally redact tokens, passwords, API keys, encryption keys, and agent setup tokens.
- Import flow must prompt for missing secrets instead of expecting the bundle to contain them.

Verification:

- Non-admin cannot access recovery.
- Exported bundle contains no plaintext secrets.
- Import preview clearly lists missing required secrets before apply.

## P2 Product Decisions

- Whether iOS should expose full server administration surfaces for storage, recovery, installable app import, and notes API tokens, or keep those as dashboard-only power-session workflows.
- Whether iOS should implement a Settings > Apps pane for installed app status/config, or only consume app metadata for assistant commands.
- Whether quick links are a Dashboard tab feature, a Settings feature, or both.
- Whether inline file preview should be native iOS playback or a server-hosted web view for parity with the dashboard preview route.

## Regression Test Checklist

- Sign in to Hank Remote and load `GET /v1/home` without any home picker.
- Open realtime connection through `POST /v1/ws/app-ticket` and the returned `websocket_path`.
- Load Home Assistant dashboard tiles from `dashboard_tiles` in `/v1/me/profile`.
- Load shared Home notes from `/v1/home/notes` and profile notes from `/v1/me/notes`.
- Load SMB service profile status from `/v1/home/service-profiles`.
- Browse files from the default source and at least one alternate `source_id`.
- Move a file within one source and across two sources.
- Start a media download, watch progress, cancel one job, and open the completed destination.
- Confirm a member account cannot access admin-only storage, service-profile edit, recovery, installable-app config, or token-management actions.

