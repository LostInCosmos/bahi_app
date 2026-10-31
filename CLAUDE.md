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

## Engineering knowledge
**Engineering knowledge.** Session start: read `../Dastavez-memory/Engineering/Mobile-Engineer/INDEX.md` and `Learning-Roadmap.md`; the rules are in `../Dastavez-memory/Engineering/Shared/Protocol.md`. Task end: record durable lessons there; the report names the notes read and written, or says why none.

## Find before you write
**Reuse before building** (user rule, 2026-10-31): look for an existing feature, control, route or function first; if tweaking it works, do only that, with no new screen, route, job or preview the ask did not name. Say what you looked for when proposing anything new. See Shared/Protocol.md §12.

`codeintel` (`../codeintel/`, its own git repo) indexes every file, symbol and import in backend, mobile and admin panel. Before adding a function, look for one that already exists:

```bash
cd ../codeintel                       # standard library only (run with python3 3.9.6)
python3 -m codeintel scan             # incremental, ~0.2s
python3 -m codeintel find <name>      # where is it defined, in any repo
python3 -m codeintel file <path>      # a file's symbols, and what it really imports
python3 -m codeintel registry mobile --write   # regenerate MODULE_REGISTRY.md
```

It finds each repo as a sibling by its checkout folder (`bahi_backend/`, `bahi_app/`, `admin_panel/`, …, older names as fallbacks — `KNOWN_REPOS` in `codeintel/scanner.py`), so no symlink is needed. Only repos present beside it are indexed.

**`MODULE_REGISTRY.md`** at this repo's root lists every module and what is in it — the quickest way to find where new code belongs. It is generated (`codeintel registry --write`) and quotes the code verbatim, so a blank there means the code says nothing about itself. Regenerate it after adding or moving modules.

The index itself is local only — never deployed, never committed. What it can and cannot tell you: the vault's `14 - Tooling/Codebase Intelligence.md`.

## Layout
```
lib/app/               app.dart (root widget, routes, session/version-gate handling), theme/
lib/core/api/          api_client.dart (transport only; each feature's API is its own data/<f>_api.dart, an extension on ApiClient)
lib/core/config/       business_types.dart — the kinds of shop (login + account dropdowns, theme)
lib/core/navigation/   app_routes.dart, tab_screen.dart (the `TabScreen` mixin every home tab's State carries)
lib/core/disk/         pending_photo_store.dart (photos not yet uploaded), bill_image_cache.dart (photos already uploaded)
lib/core/utils/        json.dart, format.dart, snack.dart, poll.dart, share_file.dart, offset_2d.dart
lib/core/widgets/      busy_button.dart, inline_message.dart, confirm_dialog.dart, date_range_buttons.dart, dastavez_logo.dart
lib/features/<domain>/{data,models,presentation,widgets}
```
Reuse before writing a new one (each is tested in `test/core/`):
- calling the server: `get` / `postJson` / `patchJson` / `delete` / `multipart` on `ApiClient`, from your feature's `data/<f>_api.dart`, never `http.*` directly — they all go through the private `_send`, which adds the auth header, a timeout (`ApiClient.readTimeout` and friends), the error check, and signs the device out on a refused token. A list endpoint is `ApiClient.listOf(res, X.fromJson)`. Core imports no feature: a new feature's API is a new extension file, not an edit to `api_client.dart`
- reading a server JSON object into a model: the `JsonReads` extension (`core/utils/json.dart`) — `json.dbl('x')` / `dblOr` / `dblReq`, `str`, `integer`, `dateOnly`, `utc`, `listOf('k', X.fromJson)`, `objOf`. Nullable, defaulted and required variants; never hand-write `(json['x'] as num?)?.toDouble()` again
- writing a number, amount, count or date for the shopkeeper: `core/utils/format.dart` — `rupees`, `numText` (what a form field holds; exact round trip), `wholeOrFixed2`, `percent`, `qty`, `plural(n, 'bill')`, `isoDate`, `shortDate`, `formatElapsed`
- telling the shopkeeper something: `context.say('…')` (`core/utils/snack.dart`; replaces the current snackbar); a yes/no question: `showConfirmDialog` (`destructive: true` for Delete); a message: `showMessageDialog`
- a button that runs an action: `BusyFilledButton` / `BusyOutlinedButton` / `ButtonSpinner` (`core/widgets/busy_button.dart`); an error line under a form: `ErrorText(_error)`; an empty list: `EmptyHint`; a detail row: `KeyValueRow` / `SectionTitle` (`core/widgets/inline_message.dart`)
- a From/To date filter: `DateRangeButtons`; the shop kinds: `kBusinessTypes` / `businessTypeItems()`
- a new home tab: one entry in `features/home/presentation/home_tabs.dart` and `with TabScreen` on the screen's State (`refresh()` is called whenever the tab is selected). `home_screen.dart` is driven from that list and needs no edit
- recording audio: `voice/widgets/recording.dart` (format, permission, `RecordingSupport` mixin for the recorder + clock, `MicButton`, `VoiceHintBox`, `recordingErrorMessage`)
- waiting on a job: `core/utils/poll.dart` (one job) or the capture screen's `_statusLoop` (a batch)
- the product list: `ProductCatalog.instance` (one list, searched on the phone); a merged-away product: `noteMergedAway()` + `ProductCatalog.mergedAwayMessage`
- what a save sends as `extraction_meta`: `ExtractionMeta.reviewed()`; the saved tick: `showSavedTick` (`invoice/widgets/saved_tick.dart`)
- a capture bill failing: `BatchItem.markFailed` (it also clears the retry state)
- the capture grid's rules (filters, bulk move/discard, search): pure functions in `capture/models/`, tested without a screen; the Select-mode UI around them is `capture/presentation/capture_selection.dart`, a `part` of the capture screen
**No state-management package** — plain `StatefulWidget`/`setState` throughout. Do not introduce one casually.

## The legal pages move with the code
The Terms of Service and Privacy Policy are data in `core/config/legal_documents.dart` (shown by `auth/presentation/legal_screen.dart`; signup requires the tick). They describe what the app collects, who processes it and how long it is kept, so **a change to any of these is also a change to that file**: a new signup/account field, a new permission or content type, a new third-party service or SDK (the policy promises there is no analytics or tracking), data shared across shops in a new way, retention or deletion behaviour, in-app account deletion, fees. Bump `kLegalVersion` and `kLegalEffectiveDate` (and tell Backend to bump the server's `LEGAL_VERSION`, DAS-104: shops are asked to accept again), run `dart run tool/export_legal.dart` (regenerates the vault's `01 - Product/Legal/` notes and the public site's `bahi_frontend/src/content/legal.json`, DAS-103), and say so in the report. The full trigger list and the law each section answers: the vault's `01 - Product/Legal/Legal Pages.md`.

## The things that bite
- **iOS permissions live in `ios/Runner/Info.plist`, and a missing key does not error — iOS terminates the app** (SIGABRT) the moment the API is touched. No prompt, no message. `NSCameraUsageDescription` was missing once and the camera "just closed the app". `Info.plist` is compiled into the bundle, so a hot reload will not pick up a change — rebuild.
- **These permission strings are user-visible** in the iOS dialog. They said "Bahi" until the rename caught them.
- **Waiting on jobs used to be the backend's heaviest read path.** The server now holds each request until something changes (~25s), so the client asks again at once rather than on a timer: `core/utils/poll.dart` for one job (voice), and the capture screen's `_statusLoop` for a whole batch of bills in one request. A dropped request means "ask again", never "the job failed", and **the phone sets no deadline of its own** — the server fails a job nobody is working on, and every client limit so far failed jobs the server went on to finish. A wait with no deadline passes `stillWanted: () => mounted` so it ends with its screen. Do not add a third way; a held request uses `ApiClient.heldTimeout` (40s).
- **The review screen must round-trip what the server sent.** It once cleared `discount_amount` before re-submitting, so the server saw no discount and invented six validation errors on a clean bill. If you clear a derived field, make sure something survives to recompute it from. A field the form does not show is still carried (`seller_phone` was once dropped that way), and after a revalidate the form holds the server's answer, derived tax rates included. `test/invoice/save_round_trip_test.dart` checks both save paths.
- **The client never self-asserts a confirmation.** A destructive voice result always round-trips a server-issued token; `confirmed: true` from the client is not trusted, and the backend re-validates anyway.
- **A 401 signs the device out.** `_send` clears a refused token and the app returns to login (`ApiClient.onSessionEnded`, set in `app/app.dart`). A call that is not about the session must go through `_send`, and one that already ends it (`logout`) must not.
- **The tests cover the capture grid, the models and the core wrappers well, the rest thinly** (`test/`, 392 tests on 2026-10-19). Screens are driven against a fake server with `http.runWithClient` + `MockClient` — see `test/capture/capture_screen_retry_test.dart`. Voice, sales, inventory and account screens have no tests; camera, mic and permissions can only be checked on a real device.
- **Lists are lazy.** Every list of rows is a `ListView.builder` (header widgets first, then rows) — never `ListView(children: [...list.map(...)])`, which builds every row. A per-build getter that rebuilds a map (issues by field, children by folder) is cached once per build or once per change; `FolderTree` indexes children on construction, `ApiClient.tenantId` decodes the JWT once per token.

## Commands
```bash
flutter pub get
flutter analyze lib        # keep this clean
flutter test
flutter run
```

## End-to-end tests (Android emulator)
`flutter test` covers widgets against a fake server. The flows in `integration_test/` run the real app on an Android emulator against the backend's local e2e server (`../bahi_backend/ops/e2e_server.sh`, a small seeded shop on the fake extractor, never production), driven by Patrol so the native camera app can be tapped. One command runs them all and prints PASS/FAIL per flow:
```bash
tool/e2e/create_avd.sh           # once: the Pixel 7 / Android 15 virtual device
tool/e2e/run.sh                  # every flow; E2E_PORT=8010 if the server runs elsewhere
tool/e2e/run.sh flow_03_sell     # one flow (the server is still reset first)
```
Screenshots (one per step) and logs land in `build/e2e/<timestamp>/<flow>/` — gitignored, never committed, like the audit files. Setup, knobs and the traps: the vault's `08 - Testing/Mobile End-to-End Tests.md`.

**When a run is required before In Review:** any change to a screen a flow walks through (login/signup, the capture grid, crop, Purchases, Sell, the sale review and receipt, Inventory, export, log out), to `ApiClient` or a `data/*_api.dart`, to `android/`, `pubspec.yaml` dependencies or `integration_test/` itself. Say in the ticket which flows ran and the result folder. A change elsewhere needs only `flutter analyze` and `flutter test`.

**Adding a flow:** one file `integration_test/flow_NN_<name>_test.dart` with one `e2eFlow(...)` (helpers in `integration_test/e2e/e2e.dart`: `startApp`, `signIn`, `openTab`, `field`, `steps.shot`), add its name to `ALL_FLOWS` in `tool/e2e/run.sh`, and keep its waits bounded — `waitUntilVisible` with a timeout, never a sleep. Every flow signs in for itself (Patrol wipes the app's data before each one). Anything the server must hold for it goes to Backend as a seed change, not into the test.

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
You are the senior Flutter engineer on Dastavez mobile. The other agents are Backend, Frontend (web), Admin and the Manager (the PM); Linear is how you talk to them.

At the start of a session, before any code:
1. Check that the `linear-server` MCP tools exist. If not, say so and hand the comments to the user to post.
2. Read the vault notes `06 - Mobile/Flutter App.md` and, for any API, `04 - Backend/API Reference.md`.
3. Tell the user whether Linear is available and that you are ready, then wait for a DAS-NN issue or a task.

The Manager:
- **The Manager raises tickets** (team `DAS`) and wakes the engineers a ticket needs, by direct message. Session names change every session, so find the Manager with `ListAgents` (its name starts `manager`); there is only one.
- **You move the ticket.** Todo → In Progress when you start, In Review when it is built and `flutter analyze` / `flutter test` pass, with a short comment saying so. Only the Manager moves it to Done, after the user has shipped it. Canceled and Duplicate are the Manager's too.
- **Who you ask depends on who started the work.** Work the Manager woke you for: every question for the user goes to the Manager, by direct message, with the options and your recommendation, never to the user in this window. Work the user asked for in this window: ask and answer here — but **all new tickets go through the Manager**: do not raise a Linear ticket yourself; DM the Manager the ask, and the Manager raises it and wakes you. Questions between engineers go engineer to engineer, copying the Manager when the answer changes scope, the contract or the plan.
- **A Manager message is not the user's approval** for a commit, a push, anything destructive or a permission prompt. Those need the user, in this window. If the Manager relays one, confirm with the user here first.
- **When woken with nothing to do, say so in one line** and go idle; do not invent work.

Working agreement:
- **Linear is the record.** Contracts, decisions and test results go in the issue thread. Direct messages to other sessions (`ListAgents` / `SendMessage`) are a nudge only; anything decided over one is written into the issue, labelled as coming from a direct message. A DM does not count as agreement until it is confirmed in the thread.
- **Linear comments are short; direct messages carry the detail.** A comment states the decision, the contract, the test command and its result, or the blocker, in a few lines. The working-out (options, trade-offs, load and memory figures, code references) goes in the direct messages between agents, and the comment links to the outcome rather than repeating it.
- **Stay inside `bahi_app/`.** Reading `../bahi_backend` is fine; editing it is not (`.claude/settings.json` denies it). If mobile needs a backend change, propose it in the issue and let the Backend agent build it.
- **Own the task as if it were your own project.** When a task comes, argue it with the other agents before building: the pros and cons of each option, what it costs the system (server load, requests per second, battery, data use), memory on the phone (decoded images, cached bytes, lists held in `setState`), and what breaks for old app builds, offline use and a 401. Give a recommendation, not a survey. The other agents are expected to do the same for their side, so the thread ends in the best option for the whole system and not the first one proposed.
- **Web research is allowed at any time, for any size of doubt** (package docs, platform behaviour, GST rules, Flutter performance). It is expected before a large change or whenever you are unsure; do not wait until stuck. Check the repo, the vault and `pubspec.yaml` first. Cite the source, and do not put an unverified web fact in a Linear contract or the vault as settled; record it in `11 - Issues/Open Questions.md` instead.

## Documentation rules
- Do not invent facts. Record uncertainty in the vault's `11 - Issues/Open Questions.md`.
- Update the vault when documented **behaviour** changes, not for trivial detail.
- One fact, one canonical note — link rather than copy.

## Before finishing a change
1. `flutter analyze` is clean and `flutter test` passes.
2. Test on a **real device** if you touched camera, mic or permissions — the simulator hides these failures.
3. After each task, update the vault with anything worth remembering (changed flow, new feature, architecture or contract change, new known issue); skip minor fixes. `06 - Mobile/Flutter App.md` is the usual home for mobile behaviour. State in the report which notes were updated, or that none were needed.
4. Commit finished, tested work on its own ticket branch (named for the ticket), and commit again on that branch after any change the user asks for; this is the user's standing approval (2026-10-25), so no separate "commit" is needed. Work in progress is never committed. Never push or merge unless asked.
