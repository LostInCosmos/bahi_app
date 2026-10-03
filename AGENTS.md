# AGENTS.md — Dastavez mobile (Flutter)

Operating guide for coding agents. **Orientation, not documentation.**

## What this is
The Flutter client for **Dastavez** — a GST purchase/sales and inventory app for small Indian shops. This is the shop owner's daily tool and the **only** client that captures bill photos or records voice.

It is a thin client: all business logic lives in the backend (`../backend`). This app captures, polls, reviews and submits.

## Where the knowledge lives
One Obsidian vault documents all four repos:

```
~/Documents/Documents/Dastavez/GSTApp/
```

Plain Markdown — readable without Obsidian. Start at `00 - START HERE.md`.

Most relevant here:
- `06 - Mobile/Flutter App.md` — structure, dependencies, the permissions trap
- `06 - Mobile/User Flows/Mobile Screen Map.md` — every screen, grouped by workflow
- `01 - Product/Core Workflows.md` — what the user is actually doing
- `04 - Backend/API Reference.md` — what you are calling

Keep it honest:
```bash
python3 ../backend/ops/check_docs.py      # verifies code_paths + links
```

## Find before you write
`~/Desktop/GSTApp/codeintel/` indexes every file, symbol and import in backend, mobile and admin panel. Before adding a function, look for one that already exists:

```bash
cd ~/Desktop/GSTApp/codeintel
.venv/bin/python -m codeintel scan          # incremental, ~0.1s when little changed
.venv/bin/python -m codeintel find <name>   # where is it defined, in any repo
.venv/bin/python -m codeintel file <path>   # a file's symbols, and what it really imports
```

**`MODULE_REGISTRY.md`** at this repo's root lists every module and what is in it — the quickest way to find where new code belongs. It is generated (`codeintel registry --write`) and quotes the code verbatim, so a blank there means the code says nothing about itself. Regenerate it after adding or moving modules.

The index itself is local only — never deployed, never committed. What it can and cannot tell you: the vault's `14 - Tooling/Codebase Intelligence.md`.

## Layout
```
lib/features/<domain>/{data,models,presentation}
lib/core/utils/        poll.dart, recording_error.dart
lib/core/api/          api_client.dart
```
**No state-management package** — plain `StatefulWidget`/`setState` throughout. Do not introduce one casually.

## The things that bite
- **iOS permissions live in `ios/Runner/Info.plist`, and a missing key does not error — iOS terminates the app** (SIGABRT) the moment the API is touched. No prompt, no message. `NSCameraUsageDescription` was missing once and the camera "just closed the app". `Info.plist` is compiled into the bundle, so a hot reload will not pick up a change — rebuild.
- **These permission strings are user-visible** in the iOS dialog. They said "Bahi" until the rename caught them.
- **Polling drives the backend's heaviest read path.** `core/utils/poll.dart`, 2s interval, used by every submit-then-poll screen. Do not add a second polling implementation.
- **The review screen must round-trip what the server sent.** It once cleared `discount_amount` before re-submitting, so the server saw no discount and invented six validation errors on a clean bill. If you clear a derived field, make sure something survives to recompute it from.
- **The client never self-asserts a confirmation.** A destructive voice result always round-trips a server-issued token; `confirmed: true` from the client is not trusted, and the backend re-validates anyway.
- **Only one test exists** (`test/widget_test.dart`, a smoke test). There is effectively no safety net here — lean on `flutter analyze` and manual checks on a real device.

## Commands
```bash
flutter pub get
flutter analyze lib        # keep this clean
flutter test
flutter run
```

## Documentation rules
- Do not invent facts. Record uncertainty in the vault's `11 - Issues/Open Questions.md`.
- Update the vault when documented **behaviour** changes, not for trivial detail.
- One fact, one canonical note — link rather than copy.

## Before finishing a change
1. `flutter analyze lib` is clean.
2. Test on a **real device** if you touched camera, mic or permissions — the simulator hides these failures.
3. Update `06 - Mobile/Flutter App.md` only if documented behaviour changed.
4. Never commit or push unless asked.
