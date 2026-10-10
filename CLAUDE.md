# CLAUDE.md — Dastavez mobile (Flutter)

Operating guide for coding agents. **Orientation, not documentation.**

## What this is
The Flutter client for **Dastavez** — a GST purchase/sales and inventory app for small Indian shops. This is the shop owner's daily tool and the **only** client that captures bill photos or records voice.

It is a thin client: all business logic lives in the backend (`../backend`). This app captures, polls, reviews and submits.

## Where the knowledge lives
One Obsidian vault documents all four repos:

```
../Dastavez-memory/GSTApp/
```

Plain Markdown — readable without Obsidian. Start at `00 - START HERE.md`.

Most relevant here:
- `06 - Mobile/Flutter App.md` — structure, dependencies, the permissions trap
- `06 - Mobile/User Flows/Mobile Screen Map.md` — every screen, grouped by workflow
- `01 - Product/Core Workflows.md` — what the user is actually doing
- `04 - Backend/API Reference.md` — what you are calling

Keep it honest (needs the backend repo checked out beside this one; set `GSTAPP_VAULT` if the vault is elsewhere):
```bash
python3 ../backend/ops/check_docs.py      # verifies code_paths + links
```

## Find before you write
`codeintel` (`../codeintel/`, its own git repo) indexes every file, symbol and import in backend, mobile and admin panel. Before adding a function, look for one that already exists:

```bash
cd ../codeintel                       # standard library only (run with python3 3.9.6)
python3 -m codeintel scan             # incremental, ~0.2s
python3 -m codeintel find <name>      # where is it defined, in any repo
python3 -m codeintel file <path>      # a file's symbols, and what it really imports
python3 -m codeintel registry mobile --write   # regenerate MODULE_REGISTRY.md
```

It finds the repos only as siblings named `backend/`, `mobile/` and `admin_panel/`. This repo is checked out as `bahi_app/`, so `../mobile` is a symlink to it. Without that link a scan finds no mobile code and says so only as a missing row in `stats`. Only repos present beside it are indexed.

**`MODULE_REGISTRY.md`** at this repo's root lists every module and what is in it — the quickest way to find where new code belongs. It is generated (`codeintel registry --write`) and quotes the code verbatim, so a blank there means the code says nothing about itself. Regenerate it after adding or moving modules.

The index itself is local only — never deployed, never committed. What it can and cannot tell you: the vault's `14 - Tooling/Codebase Intelligence.md`.

## Layout
```
lib/features/<domain>/{data,models,presentation,widgets}
lib/core/utils/        poll.dart, recording_error.dart, pending_photo_store.dart, bill_image_cache.dart
lib/core/api/          api_client.dart (+ each feature's data/<f>_api.dart as a `part`)
```
Reuse before writing a new one:
- calling the server: `_get` / `_postJson` / `_patchJson` / `_delete` / `_multipart` in `api_client.dart`, never `http.*` directly — they add the auth header, a timeout (`ApiClient.readTimeout` and friends), the error check, and sign the device out on a refused token
- recording audio: `voice/widgets/recording.dart` (format, permission, `MicButton`, `formatElapsed`)
- waiting on a job: `core/utils/poll.dart` (one job) or the capture screen's `_statusLoop` (a batch)
- a save the server refused for a GSTIN: `VendorHint.fromSaveRefusal`, then `showGstinConfirmDialog` / `showSavedTick` (`invoice/presentation/gstin_confirm.dart`)
- what a save sends as `extraction_meta`: `ExtractionMeta.reviewed()`
- a capture bill failing: `BatchItem.markFailed` (it also clears the retry state)
- the capture grid's rules (filters, bulk move/discard, search): pure functions in `capture/models/`, tested without a screen; the Select-mode UI around them is `capture/presentation/capture_selection.dart`, a `part` of the capture screen
**No state-management package** — plain `StatefulWidget`/`setState` throughout. Do not introduce one casually.

## The things that bite
- **iOS permissions live in `ios/Runner/Info.plist`, and a missing key does not error — iOS terminates the app** (SIGABRT) the moment the API is touched. No prompt, no message. `NSCameraUsageDescription` was missing once and the camera "just closed the app". `Info.plist` is compiled into the bundle, so a hot reload will not pick up a change — rebuild.
- **These permission strings are user-visible** in the iOS dialog. They said "Bahi" until the rename caught them.
- **Waiting on jobs used to be the backend's heaviest read path.** The server now holds each request until something changes (~25s), so the client asks again at once rather than on a timer: `core/utils/poll.dart` for one job (voice), and the capture screen's `_statusLoop` for a whole batch of bills in one request. A dropped request means "ask again", never "the job failed", and **the phone sets no deadline of its own** — the server fails a job nobody is working on, and every client limit so far failed jobs the server went on to finish. A wait with no deadline passes `stillWanted: () => mounted` so it ends with its screen. Do not add a third way; a held request uses `ApiClient.heldTimeout` (40s).
- **The review screen must round-trip what the server sent.** It once cleared `discount_amount` before re-submitting, so the server saw no discount and invented six validation errors on a clean bill. If you clear a derived field, make sure something survives to recompute it from. A field the form does not show is still carried (`seller_phone` was once dropped that way), and after a revalidate the form holds the server's answer, derived tax rates included. `test/invoice/save_round_trip_test.dart` checks both save paths.
- **The client never self-asserts a confirmation.** A destructive voice result always round-trips a server-issued token; `confirmed: true` from the client is not trusted, and the backend re-validates anyway.
- **A 401 signs the device out.** `_send` clears a refused token and the app returns to login (`ApiClient.onSessionEnded`, set in `app/app.dart`). A call that is not about the session must go through `_send`, and one that already ends it (`logout`) must not.
- **The tests cover the capture grid and the models well, the rest thinly** (`test/`, 269 tests on 2026-10-10). Screens are driven against a fake server with `http.runWithClient` + `MockClient` — see `test/capture/capture_screen_retry_test.dart`. Voice, sales, inventory and account screens have no tests; camera, mic and permissions can only be checked on a real device.

## Commands
```bash
flutter pub get
flutter analyze lib        # keep this clean
flutter test
flutter run
```

## Working with other agents (Linear)
Cross-component work (anything needing a backend, web, or admin change, or a new or changed API contract) is coordinated in the ticket's Linear issue (`DAS-NN`). Agents for the other components read and write the same thread.
- **Before starting**, read the issue and **all** its comments.
- **Propose first.** Post a comment with: the endpoints and payloads you need (or what you change), dependencies on other components, edge cases (offline, retries, a 401, old app builds still in the field), and how you will test it.
- **Engage, don't just post.** Read and answer the Backend, Frontend, Admin and Product Manager comments that affect mobile. Name trade-offs, challenge assumptions — including your own — and revise the proposal until all sides agree on something compatible.
- **Do not build anything that depends on another component** until the API contract (paths, fields, status codes, error shapes) and who does what are agreed in the thread. Work that stays inside mobile can go ahead.
- **Record in the issue as you go:** decisions and why, progress, test results (the command you ran and what it printed), and blockers.
- **Disagreements that stay unresolved go to the Product Manager** in the issue, with each option and its cost. Do not settle them by building one side.
- **Never claim communication or agreement you have not verified.** "Backend agreed" means a comment in the issue says so, and you read it. If this session has no Linear access (no Linear MCP tool or CLI configured), say so and hand the comments to the user to post. Do not write as if they were posted.

The issue thread is the working record. Behaviour that ships still goes into the vault (below).

## Role and session start
You are the senior Flutter engineer on Dastavez mobile. The other agents are Backend, Frontend (web), Admin and a Product Manager (PM); Linear is how you talk to them.

At the start of a session, before any code:
1. Check that the `linear-server` MCP tools exist. If not, say so and hand the comments to the user to post.
2. Read the vault notes `06 - Mobile/Flutter App.md` and, for any API, `04 - Backend/API Reference.md`.
3. Tell the user whether Linear is available and that you are ready, then wait for a DAS-NN issue or a task.

Working agreement:
- **Linear is the record.** Contracts, decisions and test results go in the issue thread. Direct messages to other sessions (`ListAgents` / `SendMessage`) are a nudge only; anything decided over one is written into the issue, labelled as coming from a direct message. A DM does not count as agreement until it is confirmed in the thread.
- **Stay inside `bahi_app/`.** Reading `../bahi_backend` is fine; editing it is not (`.claude/settings.json` denies it). If mobile needs a backend change, propose it in the issue and let the Backend agent build it.

## Documentation rules
- Do not invent facts. Record uncertainty in the vault's `11 - Issues/Open Questions.md`.
- Update the vault when documented **behaviour** changes, not for trivial detail.
- One fact, one canonical note — link rather than copy.

## Before finishing a change
1. `flutter analyze` is clean and `flutter test` passes.
2. Test on a **real device** if you touched camera, mic or permissions — the simulator hides these failures.
3. Update `06 - Mobile/Flutter App.md` only if documented behaviour changed.
4. Never commit or push unless asked.
