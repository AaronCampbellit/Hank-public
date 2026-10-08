# Hank / hankserverside Sync

This file is the contract ledger for Hank app changes that must stay aligned with `hankserverside`.

Use it for:
- API route changes
- request or response shape changes
- auth or permission changes
- WebSocket envelope changes
- rollout and compatibility notes

If a change is app-only, do not add it here.

## Status Labels

- `planned`
- `in_progress`
- `blocked`
- `ready_to_ship`
- `shipped`

## [Storage Health, Backups, And Restore]

- Status: in_progress
- Date Opened: 2026-04-30
- Owner: shared
- Related Ticket/PR: pg-integrity-backups-restore

### Summary

HankServerside now exposes database integrity and backup state to Hank. The server runs checksum monitoring, pgBackRest backups, restore testing, and admin-triggered primary restore through the private `db-ops` service.

### Contract Update

- New admin-only singleton routes:
  - `GET /v1/home/storage/status`
  - `GET /v1/home/storage/config`
  - `PUT /v1/home/storage/config`
  - `GET /v1/home/storage/events`
  - `POST /v1/home/storage/backup`
  - `POST /v1/home/storage/restore-test`
  - `POST /v1/home/storage/restore-primary`
- Storage websocket topic:
  - subscribe with `app.subscribe` topic `storage.health`
- Storage websocket events:
  - `storage.health.changed`
  - `storage.backup.failed`
  - `storage.checksum.corruption`
  - `storage.restore.started`
  - `storage.restore.completed`
  - `storage.restore.failed`

### Response Shape

`GET /v1/home/storage/status` returns:

- `config`: target, schedules, retention, and restore confirmation settings
- `checksum`: enabled state, last check timestamps, failure count, corruption flag, and last error
- `backup`: target, backup list, last successful backup, and failure count
- `restore`: last restore-test/primary-restore timestamps and pending intents
- `tasks`: current queued/running storage tasks, plus very recent completion/failure state
- `events`: recent storage log events
- `failures`: recent backup/checksum/restore failures

Each task has:

- `id`
- `operation`: `backup`, `restore_test`, or `primary_restore`
- `status`: `queued`, `running`, `success`, or `failed`
- `message`
- optional `step`
- optional `backup_type`
- optional `backup_label`
- optional `queued_at`, `started_at`, and `updated_at`

Each event has:

- `id`
- `time`
- `severity`: `info`, `warning`, `error`, or `critical`
- `operation`: `checksum`, `amcheck`, `backup`, `restore_test`, `primary_restore`, or `config`
- `status`: `pending`, `started`, `success`, or `failed`
- `message`
- optional `backup_label`
- optional redacted `details`

### Storage Security

- Postgres traffic stays on private Docker networks:
  - `postgres`, `cloud`, and `db-ops` share the internal database network.
  - `postgres-restore` and `db-ops` share a separate internal restore network.
  - only `cloud` publishes a host port.
- pgBackRest repositories are encrypted with `repo1-cipher-type=aes-256-cbc`; `HANK_REMOTE_DB_OPS_REPO_CIPHER_PASS` is mapped to `PGBACKREST_REPO1_CIPHER_PASS` so the passphrase is not passed on the command line.
- Backup repository ownership is intentionally narrow:
  - `postgres` writes WAL through encrypted pgBackRest archive-push
  - `db-ops` writes backups, restore state, and validation results
  - `postgres-restore` gets read-only backup-repo access
  - `cloud` and `agent` do not mount the backup repository
- Restore validation checks expected Hank tables and compares non-system login role attributes between the main and restore databases.
- Storage events and websocket payloads must not expose passwords, tokens, database URLs with passwords, cipher pass values, or raw command output.
- The public HTTPS/TLS boundary remains the reverse proxy or Cloudflare Tunnel. Postgres itself is not exposed outside the private Docker networks.

### Hank Changes

- Add a server-storage status surface if Hank exposes server administration in-app.
- Treat all storage routes as admin-only.
- Do not show storage pages, schedule controls, backup controls, or restore controls to non-admin members.
- Highlight `checksum.corruption_detected == true` and any `critical` storage event.
- Show backup target/schedule as editable only for admins.
- Show primary restore as a destructive admin action requiring the server-provided confirmation phrase.
- Subscribe to `storage.health` if Hank needs live notifications, but display only the redacted event summary fields.

### Rollout Order

- server first, then app

### Compatibility Notes

- Older Hank builds can ignore these routes and events.
- Hank should not call restore routes unless the signed-in user is an admin.

## [APNs Notifications]

- Status: in_progress
- Date Opened: 2026-05-09
- Owner: shared
- Related Ticket/PR: apns-notifications

### Summary

HankServerside now supports native iOS push delivery through APNs. Hank registers an APNs device token after Hank Remote sign-in, users can toggle categories, and the server sends only redacted notification summaries with a Hank deep link for detail.

### Contract Update

- Authenticated user routes:
  - `POST /v1/me/devices/apns`
  - `DELETE /v1/me/devices/{deviceID}/apns`
  - `GET /v1/me/notification-settings`
  - `PUT /v1/me/notification-settings`
- `POST /v1/me/devices/apns` body:
  - `device_id`
  - `token`
  - `environment`: `sandbox` or `production`
  - `bundle_id`
  - `enabled_categories`: `storage`, `notes`, and/or `dashboard_entities`
- `GET/PUT /v1/me/notification-settings` fields:
  - `storage`
  - `notes`
  - `dashboard_entities`
  - responses also include `user_id` and `updated_at`
- APNs sender config:
  - `HANK_REMOTE_APNS_TEAM_ID`
  - `HANK_REMOTE_APNS_KEY_ID`
  - `HANK_REMOTE_APNS_PRIVATE_KEY`
  - `HANK_REMOTE_APNS_TOPIC`
  - `HANK_REMOTE_APNS_ENVIRONMENT`: `sandbox` or `production`

### Recipient Rules

- Storage and PostgreSQL backup notifications go only to Home admins.
- Note edit notifications go to visible note recipients except the actor.
- Dashboard entity notifications go only to users whose profile settings contain that entity in `dashboard_tiles`.
- User category settings and device `enabled_categories` both filter delivery.
- Logout removes APNs device registrations tied to that app session.

### Payload Privacy

- Notification alert text must stay redacted.
- Do not include passwords, database URLs, command output, token values, backup encryption values, raw Home Assistant event bodies, or note content.
- Deep links:
  - `hank://notifications/storage`
  - `hank://notifications/notes/{noteID}`
  - `hank://notifications/dashboard/{entityID}`

### Hank Changes

- Add Push Notifications entitlement and APNs registration through `UserNotifications`.
- Register the device after Hank Remote sign-in or remembered-session bootstrap.
- Unregister the device on Hank Remote sign-out/clear and app logout when a Remote context exists.
- Add notification settings toggles for backups/storage, shared notes, and dashboard entities.
- Route notification deep links to the Storage, Notes, or Dashboard surfaces.
- While Hank is open, in-app local presentation may be used as a fallback for the same redacted event summaries.

### Rollout Order

- server first, then app
- APNs credentials can be absent in local/dev deployments; the server keeps routes active and uses a no-op sender until credentials are configured.

### Compatibility Notes

- Older Hank builds can ignore the notification settings and device routes.
- New Hank builds should handle `404` from older servers by hiding notification settings.
- Apple Developer provisioning still needs the Hank app Push Notifications capability and an APNs auth key outside the repo.

## [Single-Deployment Home Model]

- Status: in_progress
- Date Opened: 2026-04-19
- Owner: shared
- Related Ticket/PR: singleton-home refactor

### Summary

Hank Remote is now modeled as one deployment Home instead of multi-home tenancy. The first registered account auto-creates that Home and becomes an `admin`. Hank now needs to stop treating Remote as a home picker and instead treat it as one deployment-scoped Home with members, admins, permissions, notes, integrations, files, and one connected agent.

### Contract Update

- New singleton home routes:
  - `GET /v1/home`
  - `PUT /v1/home`
- Home membership and invitation routes:
  - `GET /v1/home/members`
  - `GET /v1/home/members/invitations`
  - `POST /v1/home/members/invitations`
  - `POST /v1/home/invitations/accept`
  - `DELETE /v1/home/members/invitations/{invitationID}`
  - `DELETE /v1/home/members/{userID}`
  - `PUT /v1/home/members/{userID}/role`
- Home permission routes:
  - `GET /v1/home/permissions`
  - `PUT /v1/home/permissions`
  - `GET /v1/home/members/{userID}/permissions`
  - `PUT /v1/home/members/{userID}/permissions`
- Agent and token routes:
  - `GET /v1/home/agent`
  - `GET /v1/home/agent/tokens`
  - `POST /v1/home/agent/tokens`
  - `DELETE /v1/home/agent/tokens/{tokenID}`
- Shared-resource routes:
  - `POST /v1/home/files/downloads`
  - `POST /v1/home/files/uploads`
  - `GET /v1/home/notes`
  - `GET /v1/home/notes/{noteID}`
  - `PUT /v1/home/notes/{noteID}`
  - `DELETE /v1/home/notes/{noteID}`
  - `GET /v1/home/sync`
  - `GET /v1/home/service-profiles`
  - `PUT /v1/home/service-profiles/{serviceType}`
- First-user bootstrap:
  - the first successful `POST /v1/auth/register` auto-creates the singleton Home
  - the default Home name is `Home`
- Roles:
  - `admin`
  - `member`
- The old multi-home routes are removed:
  - `/v1/homes`
  - `/v1/homes/{homeID}/...`
  - `/v1/agents`

### Hank Changes

- Remove Remote home list, home creation, and home selection flows.
- After auth, load the singleton Home from `GET /v1/home`.
- Replace `owner` wording and local role checks with `admin`.
- Move Remote settings, membership, permissions, sync health, integrations, files, and shared notes to a singleton Home model.
- Stop storing selected-home UI state for Remote.

### hankserverside Changes

- Singleton Home routing is implemented.
- First-user bootstrap is implemented.
- Multi-home startup is rejected server-side.
- `owner` memberships are migrated to `admin`.

### Rollout Order

- server first, then app

Details:
- This is a clean contract break. Hank should switch directly to the singleton routes instead of trying to support both shapes at once.

### Fallback Behavior

- What happens if Hank ships first?
  - Calls to singleton routes fail against older servers.
- What happens if `hankserverside` ships first?
  - Existing Hank builds that still call `/v1/homes` and related home-scoped routes break until Hank adopts the singleton contract.

### Compatibility Notes

- Minimum Hank version: current Hank singleton-home client
- Minimum `hankserverside` version: current singleton-home branch
- Is this backward compatible?
  - No. This is a deliberate clean break from the multi-home contract.
- When can old behavior be removed?
  - Old behavior is already removed from `hankserverside`.

### Validation

- Register the first account and confirm `GET /v1/home` succeeds without a separate create step.
- Confirm the app no longer expects a home picker or home creation flow.
- Confirm the app reads one Home, one agent surface, and one token list.

## [App WebSocket Relay Without home_id]

- Status: in_progress
- Date Opened: 2026-04-19
- Owner: shared
- Related Ticket/PR: singleton-home refactor

### Summary

App WebSocket commands now route implicitly against the singleton Home. Hank should stop sending `home_id` on `app.command` envelopes.

### Contract Update

- Hank app WebSocket endpoint remains:
  - `GET /ws/app`
- Preferred WebSocket auth is now:
  - `POST /v1/ws/app-ticket`
  - connect to the returned `websocket_path`, currently `/ws/app?app_ticket={ticket}`
- App tickets are one-use and short-lived. Current TTL is 90 seconds.
- Long-lived `session_token` query auth is no longer accepted on `/ws/app`; Hank must use app tickets.
- Requests must now include:
  - `request_id`
  - `command`
  - optional JSON payload
- Requests must no longer require:
  - `home_id`
- The cloud resolves the authenticated user to the singleton Home automatically.

### Hank Changes

- For new WebSocket connections, request an app ticket with the regular HTTP bearer session token, then connect with `app_ticket`.
- Do not persist app tickets. If the WebSocket connect fails or the ticket expires, request a fresh ticket.
- Remove `home_id` from outgoing `app.command` envelopes.
- Remove any home-selection dependency from the remote WebSocket client.
- Keep request correlation by `request_id`.

### hankserverside Changes

- The app WebSocket now accepts singleton-home commands without `home_id`.
- Route authorization still checks authenticated membership in the singleton Home.

### Rollout Order

- server first, then app

Details:
- Hank should not try to send both with and without `home_id`. The target contract is the singleton envelope.

### Fallback Behavior

- What happens if Hank ships first?
  - Older servers reject commands because they still require `home_id`.
- What happens if `hankserverside` ships first?
  - Older Hank builds still sending `home_id` continue to include the field, but the clean target is to remove the field from Hank.

### Compatibility Notes

- Minimum Hank version: current Hank singleton-home relay client
- Minimum `hankserverside` version: current singleton-home branch
- Is this backward compatible?
  - Treat it as no. Hank should align to the new envelope contract.
- When can old behavior be removed?
  - Hank should remove `home_id` handling in its Remote client during this migration.

### Validation

- Send `system.ping` through `/ws/app` without `home_id`.
- Verify `/v1/ws/app-ticket` returns `ticket`, `expires_at`, and `websocket_path`, and that Hank uses `websocket_path` for the connection.
- Send one Home Assistant command, one file command, and one notes command without `home_id`.

## [Home Members, Roles, And Permissions]

- Status: in_progress
- Date Opened: 2026-04-19
- Owner: shared
- Related Ticket/PR: singleton-home refactor

### Summary

The singleton Home now supports `admin/member` roles plus Home-wide feature defaults and per-member overrides for `homeassistant`, `files`, and `notes`.

### Contract Update

- Membership routes:
  - `GET /v1/home/members`
  - `GET /v1/home/members/invitations`
  - `POST /v1/home/members/invitations`
  - `POST /v1/home/invitations/accept`
  - `DELETE /v1/home/members/invitations/{invitationID}`
  - `DELETE /v1/home/members/{userID}`
  - `PUT /v1/home/members/{userID}/role`
- Permission routes:
  - `GET /v1/home/permissions`
  - `PUT /v1/home/permissions`
  - `GET /v1/home/members/{userID}/permissions`
  - `PUT /v1/home/members/{userID}/permissions`
- Permission model:
  - Home defaults: `homeassistant`, `files`, `notes`
  - Per-member overrides: nullable allow or deny for the same three features
  - `admin` bypasses feature toggles
- Admin-only management surfaces:
  - member removal
  - role changes
  - home permission edits
  - member permission edits
  - service-profile edits
  - agent token issuance and revocation
- Invitation creation now always creates `member` access. Promotion to `admin` is separate.
- Invitation listing and revocation are admin-only.

### Hank Changes

- Replace owner-only UI and logic with admin-only UI and logic.
- Add member role editing.
- Add Home permissions editor for `homeassistant`, `files`, and `notes`.
- Add per-member override editor for the same three features.
- Hide or disable admin-only actions for non-admin members.
- Make Remote settings explain that feature access can be denied by Home permissions even when the user is still a member.

### hankserverside Changes

- `admin/member` roles are implemented.
- Last-admin protection is implemented for removal and demotion.
- Home defaults and per-member overrides are implemented.

### Rollout Order

- server first, then app

Details:
- Hank should switch its role and permission UI together so the new admin/member vocabulary is consistent.

### Fallback Behavior

- What happens if Hank ships first?
  - Permission and role-management calls fail against older servers.
- What happens if `hankserverside` ships first?
  - Existing Hank builds still show owner-based or missing permission UI until the app is updated.

### Compatibility Notes

- Minimum Hank version: current Hank admin/member and permission UI
- Minimum `hankserverside` version: current singleton-home branch
- Is this backward compatible?
  - No. The permission and role model changed.
- When can old behavior be removed?
  - Remove owner naming and any selected-home assumptions from Hank during this migration.

### Validation

- Invite a second user and accept the invitation.
- Promote that user to `admin`, then demote back to `member`.
- Confirm the last admin cannot be removed or demoted.
- Confirm Home notes, Home Assistant, and file access are denied for a member when the corresponding Home permission is off.
- Confirm a per-member override can restore access while the Home default remains off.

## [Shared Home Notes, Sync Health, And Service Profiles]

- Status: in_progress
- Date Opened: 2026-04-19
- Owner: shared
- Related Ticket/PR: singleton-home refactor

### Summary

Shared Home notes, sync health, and integration settings are still the Remote collaboration model, but they now live under the singleton `/v1/home` contract and inherit the new permission system.

### Contract Update

- Shared Home notes:
  - `GET /v1/home/notes`
  - `GET /v1/home/notes/{noteID}`
  - `PUT /v1/home/notes/{noteID}`
  - `DELETE /v1/home/notes/{noteID}`
- Sync health:
  - `GET /v1/home/sync`
- Service profiles:
  - `GET /v1/home/service-profiles`
  - `PUT /v1/home/service-profiles/{serviceType}`
- Notes still support:
  - `page_type`
  - `board`
  - `expected_revision`
  - HTTP conflict responses
- Profile notes remain separate and unchanged:
  - `GET /v1/me/notes`
  - `POST /v1/me/notes`
  - `GET /v1/me/notes/{noteID}`
  - `PUT /v1/me/notes/{noteID}`
  - `DELETE /v1/me/notes/{noteID}`
- Profile sync and backup routes:
  - `GET /v1/me/profile`
  - `PUT /v1/me/profile`
  - `GET /v1/me/profile-secret-vault`
  - `PUT /v1/me/profile-secret-vault`
  - `GET /v1/me/profile-backup`
  - `PUT /v1/me/profile-backup`
- File transfer setup and transfer routes:
  - `POST /v1/home/files/downloads`
  - `POST /v1/home/files/uploads`
  - `GET /v1/file-transfers/{transferID}` with `Authorization: Bearer {transferToken}`
  - `PUT /v1/file-transfers/{transferID}` with `Authorization: Bearer {transferToken}`
- File transfer setup responses include `transfer_id`, `transfer_token`, `method`, `url`, `expires_at`, `next_offset`, `resumable`, and transfer status fields.
- File operation job routes:
  - `GET /v1/home/file-jobs`
  - `GET /v1/home/file-jobs/{jobID}`
  - `POST /v1/home/file-jobs/{jobID}/cancel`
  - `POST /v1/home/file-jobs/{jobID}/retry`
- `files.move` app commands can return `job_id` with a nonterminal `status` such as `running`; completion or failure is then reflected by the file operation job status.
- Service-profile writes accept:
  - `public_config`
  - `secrets`
  - `persist`
- Supported service profile types are:
  - `homeassistant`
  - `smb`

### Hank Changes

- Change all shared Remote note HTTP clients from `/v1/homes/{homeID}/...` to `/v1/home/...`.
- Keep profile notes under `/v1/me/notes`.
- Add user profile settings, encrypted secret vault, and backup clients under `/v1/me/...` if Hank syncs profile-owned state through Hank Remote.
- Change sync-status and service-profile clients to the singleton routes.
- Use file-transfer setup routes to get the short-lived transfer URL and token before performing the actual upload/download request.
- Treat `files.move` as job-backed when the server returns a nonterminal status, and wait for `GET /v1/home/file-jobs/{jobID}` to reach a terminal state before refreshing File Server UI.
- Gate shared notes, files, and Home Assistant actions on server-returned permission failures.
- Keep service-profile editing admin-only in the app.

### hankserverside Changes

- Singleton note, sync, and service-profile routes are implemented.
- Notes permission gating is enforced for non-admin members.
- Service-profile editing remains admin-only.

### Rollout Order

- server first, then app

Details:
- The route migration and role/permission migration should ship together in Hank so the Remote settings and Notes areas stay coherent.

### Fallback Behavior

- What happens if Hank ships first?
  - Shared-note, sync, and service-profile requests fail against older servers still on the multi-home routes.
- What happens if `hankserverside` ships first?
  - Existing Hank builds continue calling removed `/v1/homes/{homeID}/...` routes and break until updated.

### Compatibility Notes

- Minimum Hank version: current Hank singleton shared-note and settings client
- Minimum `hankserverside` version: current singleton-home branch
- Is this backward compatible?
  - No. The shared-resource route base changed.
- When can old behavior be removed?
  - Remove old shared-note and settings route code in Hank during this migration.

### Validation

- Load shared Home notes over `GET /v1/home/notes`.
- Save and delete shared Home notes over the singleton routes.
- Load sync health from `GET /v1/home/sync`.
- Load and update service profiles from the singleton routes.
- Confirm a non-admin member can view status but cannot edit service profiles.

## [Assistant, OpenAI Link, And Hank Context]

- Status: in_progress
- Date Opened: 2026-05-04
- Owner: shared
- Related Ticket/PR: assistant-app-contract

### Summary

HankServerside now exposes HankAI assistant sessions, per-user source settings, ChatGPT/Codex or legacy OpenAI account linking status, and app-assisted tool execution for calendar actions.

### Contract Update

- Assistant routes:
  - `GET /v1/home/assistant/status`
  - `GET /v1/home/assistant/settings`
  - `PUT /v1/home/assistant/settings`
  - `GET /v1/home/assistant/sessions`
  - `POST /v1/home/assistant/sessions`
  - `GET /v1/home/assistant/sessions/{sessionID}`
  - `DELETE /v1/home/assistant/sessions/{sessionID}`
  - `GET /v1/home/assistant/sessions/{sessionID}/messages`
  - `POST /v1/home/assistant/sessions/{sessionID}/messages`
  - `GET /v1/home/assistant/runs/{runID}`
  - `POST /v1/home/assistant/runs/{runID}/confirm`
  - `POST /v1/home/assistant/runs/{runID}/client-tool-results`
  - `PUT /v1/home/assistant/calendar-index`
- OpenAI/ChatGPT link routes:
  - `GET /v1/oauth/openai/status`
  - `GET /v1/oauth/openai/start`
  - `GET /v1/oauth/openai/callback`
- Link status can return `auth_mode: "authorization_url"` or `auth_mode: "device_code"`.
- For `authorization_url`, `start` returns an `authorization_url`.
- For `device_code`, `start` returns `auth_mode`, `verification_url`, `user_code`, `expires_at`, and `poll_after_seconds`.
- Assistant run states currently include:
  - `completed`
  - `waiting_client_tool`
  - `waiting_confirmation`
- `waiting_confirmation` run responses may include display-only `pending_action_summary` with:
  - `kind`
  - `title`
  - `summary`
  - `confirmation_message`
  - `is_destructive`
  - `details`: label/value rows for the mutation being reviewed
- `pending_action_summary` is not the execution source of truth. HankServerside keeps the private pending action payload server-side and only uses the summary for user review UI.
- The first app-side client tool is calendar creation through EventKit. Hank executes the local tool, then posts the result to `client-tool-results`.
- Assistant source settings are per Home user and include project docs, assistant conversations, profile notes, Home notes, files, calendar, and Home Assistant context sources.

### Hank Changes

- Add assistant session list/create/delete/message clients.
- Add assistant run polling and state handling.
- For `waiting_client_tool`, execute supported client tools locally and return a normalized result.
- For `waiting_confirmation`, render `pending_action_summary` mutation details when provided, then present approve/cancel UI before calling confirm.
- Add assistant status/settings clients so Hank can show link state and source toggles.
- Add OpenAI/ChatGPT linking UI that supports both browser authorization URLs and device-code flows.
- Upload calendar index data with `PUT /v1/home/assistant/calendar-index` when calendar context is enabled.

### Rollout Order

- server first, then app

### Validation

- Verify assistant sessions survive app relaunch.
- Verify a normal prompt completes and stores a message.
- Verify calendar creation enters `waiting_client_tool`, executes through EventKit, posts the result, and completes.
- Verify confirmation-required note/calendar mutations show structured action details and do not execute before approval.
- Verify both OpenAI auth modes render correctly: browser authorization URL and device-code copy/open flow.
