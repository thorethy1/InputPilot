# 0.9 Presets Overhaul — Implementation Plan

Status: planned 2026-09-04, not started
Scope: 0.9.1 (InputPilot Shortcuts & Secure Secrets, Presets improvements) and 0.9.2
(Apple Shortcuts / App Intents) from `ROADMAP.md`, implemented as slices 5–6 of
`IMPLEMENTATION_0.9.md`.
Audience: an engineer or coding agent with **no prior context**. Every slice is
self-contained and ordered so each one compiles and passes tests on its own.

## What is being built

1. A shared action execution layer (one execution path reused by Presets UI and App Intents).
2. A Keychain-backed Secrets system with metadata in SwiftData and `SECRET <name>`
   references inside preset scripts.
3. A visual overhaul of the Presets tab in Apple Shortcuts style: colorful
   rounded tiles, native Liquid Glass surfaces, run-state feedback, editor sheet.
4. Apple Shortcuts integration through modern App Intents that reuse the same
   services (never a second transport implementation).

---

## 0. Current code reality (verified 2026-09-04)

| Thing | Location |
| --- | --- |
| `HIDPreset`, `HIDMacro`, `PresetScript`, `PresetsView`, `MacrosView`, `MacroController`, `HIDConnectionManager`, both transports | `ios/InputPilot/HIDControl.swift` (2806 lines, monolithic) |
| `PresetScript` enum | `HIDControl.swift:2351-2400` |
| `HIDPreset` @Model | `HIDControl.swift:2402-2406` |
| `PresetsView` + `run(_:)` | `HIDControl.swift:2757-2800` |
| `HIDConnectionManager.send/sendText/beginOrderedSession/endOrderedSession/releaseAll/releaseAllPreservingError` | `HIDControl.swift:2210-2290` |
| SwiftData schema | `ios/InputPilot/InputPilotApp.swift:177` → `Schema([StoredDevice.self, HIDPreset.self, HIDMacro.self])` |
| Liquid Glass fallback pattern to copy | `ios/InputPilot/KeyboardView.swift:214-261` (`if #available(iOS 26.0, *)` → `glassEffect`, else material background) |
| Design tokens | `InputPilotApp.swift:137-167` (`AppTheme.Spacing/Radius`, `AppColors`, 44 pt minimum target) |
| Preset script docs | `docs/PRESET_SCRIPTS.md` |
| Existing preset script tests | `ios/InputPilotTests/HIDRemoteTests.swift:266-293` (`PresetScriptTests`) |
| `StoredDevice` @Model | `ios/InputPilot/Persistence/DeviceStore.swift:5` |
| Keyboard layout strokes (text → keystrokes) | `ios/InputPilot/KeyboardLayout.swift` |

Important environment facts:

- The Xcode project uses **explicit file lists** (objectVersion 56, no
  filesystem-synchronized groups). Every new `.swift` file must be registered
  manually in `project.pbxproj` (procedure in section 1.1).
- Deployment target is **iOS 17**; Liquid Glass requires `#available(iOS 26.0, *)`
  gating with a fallback (copy the KeyboardView pattern).
- This repository may be edited on Linux, but **cannot be compiled here**.
  Verification happens on a Mac with Xcode (section 1.5).
- Logging today: `HIDConnectionManager.send` logs only `event.diagnosticName`
  (text appears as `keyboard_text length=N`, never content). Transports log
  `diagnosticName` too, not the raw line. Keep it that way for secrets.

## 1. Ground rules for every slice

### 1.1 Adding a new Swift file (mandatory procedure)

`ios/InputPilot.xcodeproj/project.pbxproj` uses manual IDs in the
`A100000000000000000000NN` (PBXBuildFile) and `A200000000000000000000NN`
(PBXFileReference) numbering space. In use as of now: build files up to
`...40`, file refs up to `...44`. Use fresh unique numbers (e.g. start at `51`)
and never reuse an existing ID. For each new file, add exactly four entries:

1. `/* Begin PBXBuildFile section */` — one line:
   `A100000000000000000000NN /* <Name>.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000000000000000000NN /* <Name>.swift */; };`
2. `/* Begin PBXFileReference section */` — one line:
   `A200000000000000000000NN /* <Name>.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = <Name>.swift; sourceTree = "<group>"; };`
   (for subdirectory files like `Views/Foo.swift` use `name = Foo.swift; path = Views/Foo.swift;`)
3. `PBXGroup` children of the matching folder group (InputPilot root group for
   root files, `Views`, `Models`, `Services` sub-groups otherwise; the group's
   `children` list contains the sibling files).
4. `PBXSourcesBuildPhase` of the correct target — app target for
   `ios/InputPilot/**`, test target for `ios/InputPilotTests/**`.

Verify with `grep -c "<Name>.swift" ios/InputPilot.xcodeproj/project.pbxproj`
→ must be exactly 4. Then confirm the project still opens and builds on a Mac.

### 1.2 Code style

- Normal, readable Swift as in `KeyboardView.swift` (the semicolon-packed style
  in old parts of `HIDControl.swift` is legacy; do not imitate it in new files).
- No comments unless genuinely non-obvious.
- Use `AppTheme.Spacing`, `AppTheme.Radius`, `AppColors`, `minimumInteractionSize`.
- SwiftUI-first: `ContentUnavailableView`, `Form`, `confirmationDialog`, context
  menus, swipe actions.

### 1.3 Security invariants (release-gate material)

- Secret plaintext lives **only** in the iOS Keychain and transiently in memory
  during execution. Never in SwiftData, never in `@Published` state that
  outlives execution, never in logs/diagnostics/error text/`CustomStringConvertible`,
  never in App Intent parameters or results.
- Broken/missing secret references must fail loudly with a human-readable
  reason ("Secret 'x' is missing") — never substitute an empty value.
- Reveal-secret UI uses a deliberate reveal toggle; apply `.privacySensitive()`
  and redaction reasons so screenshots/app-switcher do not show values.

### 1.4 Execution safety invariants

- All execution goes: `beginOrderedSession(lowLatency:) → steps → guaranteed
  releaseAll on every exit path (success, failure, cancel)` — exactly like
  `PresetsView.run` today (`HIDControl.swift:2774-2798`).
- One shared execution path. The Presets UI and App Intents must call the same
  executor; do not duplicate HID/transport logic.

### 1.5 Per-slice verification (on a Mac)

1. `xcodebuild -project ios/InputPilot.xcodeproj -scheme InputPilot -destination 'platform=iOS Simulator,name=iPhone 16' build` (succeeds)
2. `xcodebuild test -project ios/InputPilot.xcodeproj -scheme InputPilot -destination 'platform=iOS Simulator,name=iPhone 16'` (all tests pass, including new ones)
3. Manual smoke checklist of the slice (listed per slice).
4. Add one `CHANGELOG.md` entry under `Unreleased`.
5. Tick the matching boxes in `IMPLEMENTATION_0.9.md` sections 5/6 only when done.

### 1.6 SwiftData migration policy

Adding new entities (e.g. `StoredSecret`) or new properties **with default
values** (e.g. `var id: UUID = UUID()`) is a lightweight migration and needs no
migration plan. Never rename/remove existing properties of `HIDPreset`,
`HIDMacro`, `StoredDevice` in these slices. Never run a migration that would
temporarily store secret plaintext in SwiftData (not applicable — secrets were
never stored there).

---

## 2. Slice 1 — Shared action executor (foundation, no behavior change)

**Goal:** extract the preset execution loop out of the view into a reusable,
testable service. This is the seam both the new Presets UI (slice 4) and App
Intents (slice 5) will use.

### Files

- New `ios/InputPilot/Services/ActionExecutor.swift`
- New `ios/InputPilotTests/ActionExecutorTests.swift`
- Modified: `ios/InputPilot/HIDControl.swift` (PresetsView.run uses the executor)

### Content

```swift
@MainActor protocol HIDActionTransport: AnyObject {
    func send(_ event: HIDEvent) async -> Bool
    func sendText(_ text: String, layout: KeyboardLayout, delayMilliseconds: Int) async -> Bool
    func beginOrderedSession(lowLatency: Bool) -> Bool
    func endOrderedSession()
    func releaseAllPreservingError() async
}
// extension HIDConnectionManager: HIDActionTransport {}  — zero code, members exist

enum ActionExecutionError: LocalizedError { /* unsupportedCharacter(String), secretMissing(String), transportFailure(String), cancelled */ }

@MainActor final class ActionExecutor {
    func run(steps: [PresetScript.Step],
             layout: KeyboardLayout,
             typingDelayMs: Int,
             transport: HIDActionTransport,
             secretResolver: (String) async throws -> String) async -> Result<Void, ActionExecutionError>
}
```

Behavior (copy from `PresetsView.run`, `HIDControl.swift:2760-2799`):

- Validate all text steps through `layout.strokes(for:)` **before** sending
  anything (unchanged).
- `guard transport.beginOrderedSession(lowLatency: false)` else return failure.
- `defer { transport.endOrderedSession() }`.
- Per step: `.text` → `sendText`, `.key` → `send(.keyCombo(...))`, `.delay` →
  sleep, then `Task.checkCancellation()`. On `sent == false` →
  `releaseAllPreservingError()` and return failure. (Secret step comes in slice 2.)
- Catch `CancellationError` → releaseAll → return `.cancelled`.

Then rewrite `PresetsView.run` to call `ActionExecutor.run` and keep its
duplicate-execution guard (`execution != nil`). No visible behavior change.

### Tests (`ActionExecutorTests.swift`)

Use a `MockActionTransport` implementing `HIDActionTransport` (record calls,
scriptable success/failure). Cover:

- happy path text+key+delay ordering (recorded call order)
- layout validation failure sends nothing
- transport failure mid-run → `releaseAllPreservingError` called, failure returned
- cancellation → released
- failed `beginOrderedSession` → nothing sent

### Manual smoke

Presets tab still runs an existing text preset and a script preset on device;
error path still shows the banner error.

---

## 3. Slice 2 — Keychain Secrets + `SECRET <name>` script step

**Goal:** secrets infrastructure and secret references in preset scripts.

### Files

- New `ios/InputPilot/Services/SecretStore.swift`
- New `ios/InputPilot/Models/StoredSecret.swift`
- Modified: `HIDControl.swift` (`PresetScript.Step` + parser), `InputPilotApp.swift:177` (schema), `ActionExecutor.swift` (resolve secrets), `docs/PRESET_SCRIPTS.md`, tests.

### StoredSecret (SwiftData metadata only — no value!)

```swift
@Model final class StoredSecret {
    @Attribute(.unique) var id: UUID
    var name: String
    var note: String
    var createdAt: Date
    var updatedAt: Date
}
```

Register in the schema: `Schema([StoredDevice.self, HIDPreset.self, HIDMacro.self, StoredSecret.self])`.

### SecretStore (Keychain)

```swift
enum SecretStoreError: LocalizedError { /* notFound(String), duplicateName(String), keychain(OSStatus) */ }
struct SecretStore {
    static let service = "app.inputpilot.secrets"
    func save(name: String, value: String) throws        // kSecClassGenericPassword, account = UUID, also upsert StoredSecret metadata
    func value(forID id: UUID) throws -> String          // throws .notFound
    func delete(id: UUID) throws                         // delete keychain item + metadata
    func rename(id: UUID, to newName: String) throws     // metadata only
}
```

Rules: account is the UUID string, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
value stored as UTF-8 `kSecValueData`. No logging anywhere in this file. On
save, reject empty names; treat empty value as delete? No — reject empty value too.

### PresetScript extension

`Step` gains `case secret(String)`. Parser: a `SECRET <name>` line (bracketed
`[SECRET work-password]` also accepted) resolves by **name at parse time only
for validation of syntax** — execution resolves name → ID via metadata lookup,
then Keychain. Add `SECRET` to parse tests including error cases (empty name).

Execution in `ActionExecutor`: add a `secretResolver` used for `.secret(name)`
steps: look up `StoredSecret` metadata by name → `SecretStore.value(forID:)` →
send via `sendText` with the preset's typing delay (same path as `.text`, so
existing log-safety applies). Missing metadata or Keychain item →
`ActionExecutionError.secretMissing(name)` → releaseAll + failure surface.
**Never** put the resolved value into any error message.

Duplicate names: make `StoredSecret.name` the unique key instead of allowing
duplicates — simpler and matches `SECRET <name>` resolution. Use
`@Attribute(.unique) var name: String` plus non-unique `id: UUID`.

### Tests

- `SecretStoreTests`: save/read/update/delete round-trip against the real
  Keychain (works in simulator unit tests); duplicate name rejected; not-found error.
- `PresetScriptTests` additions: `SECRET work-password` parses to `.secret("work-password")`; `SECRET` with empty name throws.
- `ActionExecutorTests` additions: `.secret` step resolves through injected
  resolver and sends via `sendText`; missing secret → failure + releaseAll and
  **error text must not contain any resolved value**.

### Manual smoke

Create secret in a temporary debug path (full UI comes in slice 3), reference it
in a preset script, run against device, delete secret, run again → clear
failure naming the secret.

### Docs

Update `docs/PRESET_SCRIPTS.md` with `SECRET <name>` and its security notes.

---

## 4. Slice 3 — Secrets management UI

**Goal:** native secret management reachable from Settings and from the Preset editor.

### Files

- New `ios/InputPilot/Views/SecretsView.swift`
- Modified: Settings area (find it in `ContentView.swift` / `DeviceDetailView.swift`; Settings is a section-based SwiftUI Form) — add a "Secrets" navigation entry.

### Behavior

- List of secrets: name, updated date, `ContentUnavailableView` empty state
  ("No Secrets", "Add a password or token to reuse it in presets.").
- Add sheet: name, value (SecureField), optional note; Save disabled while
  name empty or duplicate.
- Row actions (swipe + context): Rename (name only), Replace Value… (sheet with
  new value + confirm), Reveal (temporary `@State` reveal with auto-hide after
  ~20 s and `.privacySensitive()` + `.redacted(reason: .privacy)` for snapshots),
  Delete (destructive confirmation).
- Delete flow: before deleting, scan all `HIDPreset.payload` for
  `SECRET <name>` occurrences (simple regex, case-insensitive); if referenced,
  show a confirmation listing the preset names ("Used by: Work Login, Unlock PC")
  and the consequence ("These presets will fail until the secret is replaced").
  Never show the old value.
- All value text fields clear their `@State` on sheet dismissal.

### Tests/manual

Manual: create/rename/replace/delete cycle; referenced-delete warning; value not
visible in app switcher (redaction); Light/Dark and Dynamic Type pass.

---

## 5. Slice 4 — Presets visual overhaul (Apple Shortcuts style)

**Goal:** replace the cramped `List`-based `PresetsView` with an Apple-Shortcuts-style
experience. Move presets UI out of `HIDControl.swift` into its own file.

### Files

- New `ios/InputPilot/Views/PresetsView.swift` (complete replacement)
- Modified: `HIDControl.swift` — delete old `PresetsView` (lines 2757-2800),
  keep `HIDPreset` model and `PresetScript` where they are (they move out only if
  App Intents needs it — see slice 5; avoid unnecessary pbxproj churn now).
- Add `var id: UUID = UUID()` to `HIDPreset` (default value → lightweight
  migration; stable identity for tile animation, drag/reorder, and App Intents).

### Design (Apple Shortcuts look)

Grid — `LazyVGrid` of flexible ~3 columns, scrollable:

- **Tile**: `RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)`,
  filled with a pastel gradient tint derived deterministically from the preset
  name (hash → hue; saturation/lightness fixed for pastel look), white SF Symbol
  (preset gains `icon: String = "keyboard"` default — lightweight migration),
  name (2-line limit), small type badge (text / key / script glyph).
- **Liquid Glass**: on iOS 26 apply `glassEffect(.regular.tint(tint), in: shape)`
  with the fallback otherwise (copy `keyCapSurface` pattern, KeyboardView.swift:214).
  Keep the pastel gradient as `opacity` fill under the glass so both look native.
- **Tap = Run.** Tile states: Ready → Running (`ProgressView` overlay) →
  Completed (checkmark overlay ~0.8 s + success haptic) → Failed (exclamation
  overlay + error haptic + the error text shown in the shared banner area).
  Guard: while any preset runs, tiles are disabled (`ActionExecutor` runs one
  at a time — single `@State execution`/`@Published` running preset ID).
- **Favorites** appear first, followed by the rest (single grid with sections or
  two sections, implementer's choice — keep it simple).
- **Context menu** per tile: Run, Edit…, Duplicate, Favorite/Unfavorite,
  Delete… (destructive confirmationDialog). Swipe actions are not available in
  grids — context menu is the primary management surface, matching Shortcuts.
- **Toolbar**: `+` (editor sheet), `ellipsis.circle` menu: Reorder (toggles an
  Edit Mode that switches the grid to a `List` with move handles and
  `.onMove`, updating `order`), and Sort (favorites first / name).
- **Editor sheet** (create + edit share one view):
  - Name, icon picker (curated SF Symbol list),
  - Type picker segmented: Text / Shortcut / Script (renamed labels:
    "Text", "Key Combo", "Script"),
  - payload `TextField(axis: .vertical)` monospaced for Script,
  - Secret picker: list of `StoredSecret`s → inserts `SECRET <name>` at the
    cursor/end; if none exist, inline "No secrets yet — create one" link to
    SecretsView,
  - Enter-after toggle, typing-speed picker, favorite toggle,
  - **live parse validation** for Script (`PresetScript.parse` on every edit,
    inline red caption with line number; Save disabled while invalid),
  - Delete (edit mode only, destructive confirm), Cancel/Save.
- **Empty state**: `ContentUnavailableView("No Presets", systemImage: ...)` with
  a "New Preset" action.
- Haptics: medium impact on run start, success/warning notification on outcome.
  Respect Reduce Motion (no scale-bounce then; static overlay only).

Accessibility: tiles ≥ 44 pt (grid spacing `AppTheme.Spacing.standard`), tile
label = preset name, value = type, hint = "Runs preset"; state announced via
`accessibilityValue` ("Running"/"Failed").

### Behavior kept from old view

- Duplicate-run guard, execution through `ActionExecutor` (slice 1), banner
  error display, `enterAfter`, `typingDelayMs`, favorites ordering,
  duplicate → "Name Copy" with next `order`, delete.

### Tests

- New `PresetsViewModelTests.swift` if a small `@Observable`/`ObservableObject`
  view model is introduced for run-state + validation (recommended); test
  duplicate guard transitions and parse-validation flag.
- Manual: create/edit/duplicate/delete/favorite/reorder/run each path; Light/Dark;
  smallest/largest iPhone; iOS 26 device (or 26 simulator) for glass, iOS 17/18
  simulator for fallback.

### Cleanup

Remove the old `PresetsView` entirely; `HIDControlView` (HIDControl.swift:2470)
switches `case .presets: PresetsView(manager: manager)` to the new file's type.
Name must stay `PresetsView` so only the file changes.

---

## 6. Slice 5 — Apple Shortcuts / App Intents

**Goal:** InputPilot actions in Apple's Shortcuts app and Siri, reusing the same
execution services. App Intents run **in-process**, so all of this is safe to
use the app's SwiftData container and `HIDConnectionManager`.

### Files

- New `ios/InputPilot/AppIntents/InputPilotIntents.swift` (entities + queries + intents)
- New `ios/InputPilot/AppIntents/InputPilotShortcuts.swift` (AppShortcutsProvider)
- New `ios/InputPilot/AppIntents/AppIntentSupport.swift` (container access + connection/execution helper)
- Modified: `InputPilotApp.swift` — expose the `ModelContainer` as a shared static
  (e.g. `AppModelContainer.shared`) used by both the App scene and intents.
- Tests: `ios/InputPilotTests/AppIntentSupportTests.swift`

### AppIntentSupport

```swift
enum AppIntentSupport {
    @MainActor static var container: ModelContainer // from shared creation
    @MainActor static func activeDevice() -> StoredDevice?       // reuse saved active-device logic (SavedDeviceIndex)
    @MainActor static func run(preset: HIDPreset, device: StoredDevice) async -> IntentResult
}
```

`run(preset:device:)` mirrors `HIDControlView` (HIDControl.swift:2445-2478):
create `HIDConnectionManager(device:)`, `await manager.connect()`, execute preset
through `ActionExecutor` (parse first; on error return failure result), always
`releaseAll` + `disconnect()` in `defer`. Return a structured result
(success / failure reason), not a thrown error for expected offline cases.

### Entities & Queries

- `InputPilotDevice`: `@AppEntity`, `DefaultEntityProvider`; `DeviceEntityQuery`
  enumerates `StoredDevice`s (`displayName` as display representation, deviceId
  as the stable ID string).
- `InputPilotPreset`: `@AppEntity`, `PresetEntityQuery` enumerates `HIDPreset`s
  by name, stable ID = the `UUID` added in slice 4.

### Intents (initial set from ROADMAP 0.9.2)

All `@MainActor` (in-process), `openAppWhenRun = false` except Connect Device may
keep false too (BLE/TCP connect can run in background; document what iOS
actually permits after testing — see roadmap "Background behavior").

1. `RunPresetIntent` — parameter: `InputPilotPreset`, optional device (default:
   active device). Executes via `AppIntentSupport.run`.
2. `ConnectDeviceIntent` — parameter: `InputPilotDevice`; connects and returns
   high-level status (`DevicePresenceStatus`-style summary, not raw transport state).
3. `CheckDeviceStatusIntent` — returns Connected/Connecting/Offline/Attention
   Required summary text for the device.
4. `SendKeyboardShortcutIntent` — parameter: key-combo string (validated with
   the same single-key parsing rules as `PresetScript`); sends via executor.
5. `SendTextIntent` — parameter: text; typing-delay parameter optional; sends
   via `sendText`. (No clipboard access from intents; that's fine.)
6. `RunMacroIntent` — optional, only if MacroController can run standalone
   without the view; otherwise defer and note it in IMPLEMENTATION_0.9.md.

**Never implement** a "Get Secret Value" intent, never return secret values,
never include secret values in result dialogs. RunPreset handles secrets
internally exactly like the UI does.

### AppShortcutsProvider

`struct InputPilotAppShortcuts: AppShortcutsProvider` with 2–3 phrases
("Run \(\.[applicationName]) preset", "Connect \(\.[applicationName])"),
`AppShortcutShortcutTileColor` matched to the accent, an SF Symbol per intent.
iOS 17+ supports AppShortcutsProvider with parameters via `@AppShortcutsBuilder`.

### Background behavior documentation

In `docs/IOS_CICD.md` or a new short `docs/APPLE_SHORTCUTS.md`: record on real
hardware what works with the app foregrounded / backgrounded / suspended:
BLE connect+run, Wi-Fi connect+run, and the timeout behavior when the device is
unreachable. Be honest — do not promise behavior iOS doesn't provide.

### Tests

`AppIntentSupportTests`: preset parsing + execution against
`MockActionTransport`; offline-device result text; secret-backed preset fails
with "missing secret" when the Keychain item is absent; no intent result string
ever contains a secret value.

### Manual gate (physical device, from IMPLEMENTATION_0.9.md)

Foreground run, background run where supported, BLE-only device, Wi-Fi device,
unavailable device (useful failure), invalid parameters, Siri phrase.

---

## 7. Slice 6 — Docs, changelog, gate bookkeeping

- One consolidated `CHANGELOG.md` entry under `Unreleased` per slice as it
  lands (do this in each slice, not at the end).
- Update `docs/PRESET_SCRIPTS.md` (slice 2) and add `docs/APPLE_SHORTCUTS.md` (slice 5).
- Tick the boxes in `IMPLEMENTATION_0.9.md` sections 5 (Presets, Secrets) and 6
  (App Intents) as they complete; leave hardware-verification boxes unticked
  until real-device evidence exists.
- Optional polish from ROADMAP presets list if time remains: presets run from
  Device Detail context menu; run-state on the keyboard quick-shortcut cards.

## 8. Slice order and why

1 (executor) → 2 (secrets engine) → 3 (secrets UI) → 4 (presets UI) →
5 (App Intents) → 6 (docs). Slices 3 and 4 can swap order if UI work should
land first, but 1 and 2 must precede both because the editor needs the secret
picker and the run states need the executor. Each slice compiles and tests green
independently; never leave a slice half-done before starting the next.

## 9. Non-goals / guardrails

- No new transport protocols, no firmware changes, no HIDMacro schema changes.
- No rewrite of `HIDControl.swift` beyond removing the old `PresetsView` and the
  tiny model additions. Presets/Shortcuts must not move macros or trackpad code.
- No plaintext secret anywhere persistent, ever (see 1.3).
- Do not run or promise beta-channel releases from this work without the human
  release workflow (`docs/RELEASE_CHANNELS.md`).
