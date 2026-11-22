# Sidebar Model Picker and Plain Model Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The main window's sidebar box holds a model picker and a Mini View switch side by side. Every model has a plain name on one speed ladder.

**Architecture:**
- **Plain names** live in each engine's catalog, so every screen that shows `ModelDescriptor.displayName` gets them. The old names move to a new `technicalName`.
- **A pure `ModelPicker`** decides what both pickers list: the speed ladder, then Apple, then an off-ladder model in use. It also sets each row's mark (✓ or ↓) and its line.
- **One menu view, `ModelPickerItems`**, draws those rows in both the sidebar's picker and the menu bar's Model submenu.

**Tech Stack:** Swift 6 toolchain in Swift 5 mode, SwiftUI and AppKit, XCTest, Swift Package Manager (XcodeGen only for the app build check).

**Spec:** `docs/superpowers/specs/2026-11-22-sidebar-model-picker-design.md`

## Global Constraints

- **Branch and commits.**
  - Work on `mini-view-organisation`, and commit at the end of each task. Never push.
  - Commit messages are one line under 72 characters, ending with the session's attribution line.
- **Running Swift.**
  - Prefix commands: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift …`.
  - Send long output to a file and read its tail.
- **Exact names.**

  | Model | Name |
  |---|---|
  | whisper.cpp tiny.en | "Fastest" |
  | whisper.cpp base.en | "Fast" |
  | whisper.cpp small.en | "Slow" |
  | WhisperKit large-v3-turbo | "Slowest" |
  | WhisperKit tiny.en | "WhisperKit tiny" |
  | WhisperKit base.en | "WhisperKit base" |
  | WhisperKit small.en | "WhisperKit small" |
  | Apple Speech | "Apple Speech" (unchanged) |
  | Apple Dictation | "Apple Dictation" (unchanged) |

- **Exact lines.**
  - The usual lines:
    - "more mistakes" (Fastest)
    - "the default" (Fast)
    - "fewer mistakes" (Slow)
    - "fewest mistakes" (Slowest)
    - "built into macOS" (both Apple models)
  - The state lines:
    - "in use"
    - "downloading 40%" (the whole percent)
    - "preparing"
    - an unavailable model's reason
  - No download sizes appear in either picker.
- **Other exact copy.**
  - "Mini View" (the switch's label).
  - "Model" (the closed picker before any model is listed or chosen).
  - "Status: Preparing the Fast model...".
  - "The Fast model is ready.", "The Fast model needs its files before it can listen." and "Download the Fast model".
- **Look.** Prism (`DESIGN.md`): no colour in the picker or the switch; DESIGN.md's tokens through `Theme`; radius 0; no shadows.
- **What doesn't change.**
  - How models download, load and transcribe.
  - Saved transcripts, which keep model keys.
  - The engines' own error messages and log lines, which keep the technical names (spec call 9).
- **The running app.** Danny's dev copy runs from `.build/xcode`. Don't launch the app, and build only into `.build/xcode-check`.

## Review Focus

- **A model in use that's off the ladder** (WhisperKit base, chosen before this change). It must still appear in both pickers, reading "in use", and the closed box shows its name. *(Task 2 test)*
- **A model mid-download.** It can't be chosen again, and its line shows the percentage. *(Task 2 test)*
- **Launch, before the models are listed.** The closed box reads "Model", and the open list reads "Loading models…" as the menu does today. *(Task 2 test)*
- **An Apple model whose macOS files aren't installed.** It shows ↓, and one click installs it. *(Task 2 test)*
- **Sentences with a plain name.** "Preparing Fast..." or "Download Fast" would read as orders. They say "the Fast model". *(Task 1 tests)*

---

### Task 1: Plain names, kept apart from the technical ones

**Files:**
- Modify: `Sources/VoiceDictationLib/Core/ModelID.swift` (`ModelDescriptor`)
- Modify: `Sources/VoiceDictationLib/Engine/GGMLModel.swift`, `Engine/GGMLDownload.swift`, `Engine/WhisperCppEngine.swift`, `Engine/WhisperKitEngine.swift`
- Modify: `Sources/VoiceDictationUI/AppModel.swift:351,367`
- Modify: `Sources/VoiceDictationUI/Onboarding/OnboardingModel.swift:165-169`
- Modify: `Sources/VoiceDictationUI/Window/ModelsView.swift:94`
- Test: `Tests/VoiceDictationTests/WhisperCppEngineTests.swift`, `WhisperKitEngineTests.swift`, `CoreTypesTests.swift`; `Tests/VoiceDictationUITests/OnboardingModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // ModelDescriptor
  public let technicalName: String?   // init parameter `technicalName: String? = nil`, after `detail`
  public var inSentence: String       // "the \(displayName) model"
  // GGMLModel: `displayName` renamed `technicalName`; new `public let plainName: String`
  // WhisperKitEngine.Model: `displayName` renamed `technicalName`; new `let plainName: String`
  ```
- **Descriptors.** Both engines build `ModelDescriptor(id:, displayName: plainName, detail:, technicalName: technicalName, state:)`.
- **Errors and logs.** Every engine error and log line now uses `technicalName`, so their text is unchanged.

- [ ] **Step 1: Write the failing tests**

```swift
// WhisperCppEngineTests
func testModelsHavePlainNames() async {          // with this file's engine setup
    let models = await engine.models()
    XCTAssertEqual(models.map(\.displayName), ["Fastest", "Fast", "Slow"])
    XCTAssertEqual(models.map(\.technicalName), ["whisper.cpp tiny.en", "whisper.cpp base.en", "whisper.cpp small.en"])
}
// testCatalogMatchesHuggingFace: `$0.displayName` becomes `$0.technicalName` (same strings), plus
//   XCTAssertEqual(GGMLModel.all.map(\.plainName), ["Fastest", "Fast", "Slow"])

// WhisperKitEngineTests
func testModelsHavePlainNames() async {
    let models = await WhisperKitEngine(root: root).models()
    XCTAssertEqual(models.map(\.displayName), ["WhisperKit tiny", "WhisperKit base", "WhisperKit small", "Slowest"])
    XCTAssertEqual(models.map(\.technicalName),
                   ["WhisperKit tiny.en", "WhisperKit base.en", "WhisperKit small.en", "WhisperKit large-v3-turbo"])
}

// CoreTypesTests
func testADescriptorNamesItselfInASentence() {
    let fast = ModelDescriptor(id: .whisperCppBase, displayName: "Fast", detail: "", state: .ready)
    XCTAssertEqual(fast.inSentence, "the Fast model")
    XCTAssertNil(fast.technicalName)
}
```

In `OnboardingModelTests`:
- The `.whisperCppBase` fixtures (lines 190 and 198) get `displayName: "Fast"`.
- Their expectations become `"Download the Fast model"` and `"The Fast model is ready."`.
- Add an assertion on the not-downloaded detail: `"The Fast model needs its files before it can listen."`.

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "WhisperCppEngineTests|WhisperKitEngineTests|CoreTypesTests|OnboardingModelTests" > /tmp/t1.txt 2>&1; tail -30 /tmp/t1.txt`
Expected: build errors for `technicalName`, `plainName` and `inSentence`.

- [ ] **Step 3: Implement**

- The catalogs, descriptors and error strings as in Interfaces.
- `OnboardingModel.speechModelStep()` uses the three sentences: "The \(name) model is ready.", "The \(name) model needs its files before it can listen." and "Download the \(name) model".
- `AppModel` passes `model.inSentence` to `pipeline.selectModel(_:named:)` (line 351) and `pipeline.whilePreparing(_:)` (line 367).
- `ModelsView.row`: under the name, when `technicalName` isn't nil, show it in `Theme.Font.mono(11)` in `textMuted`, above the detail.

- [ ] **Step 4: Run them and see them pass; then the whole suite**

Run: the Step 2 command, then `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test > /tmp/t1-full.txt 2>&1; grep -E "Executed [0-9]+ tests" /tmp/t1-full.txt | tail -4`
Expected:
- Everything passes.
- Any other test that pinned an old name is updated to the new copy, with nothing else changed.
- The `CoreData … Store failed to load` lines are noise that was there before.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: plain model names on one speed ladder"
```

---

### Task 2: What the pickers list, shared by the menu bar

**Files:**
- Create: `Sources/VoiceDictationUI/ModelPicker.swift`
- Modify: `Sources/VoiceDictationUI/MenuBar/MenuBarContent.swift`:
  - `modelMenu` and `modelItems` use `ModelPickerItems`.
  - Delete `ModelSection`, `modelSections(_:)` and `menuEntry(for:)`.
  - Keep `modelMenuTitle`.
- Test: create `Tests/VoiceDictationUITests/ModelPickerTests.swift`. In `MenuBarContentTests.swift`, delete the `menuEntry` and `modelSections` tests, and keep `modelMenuTitle`'s.

**Interfaces:**
- Consumes: Task 1's plain `displayName`s; `ModelID.whisperCppBase`, `.appleSpeech`, `.appleDictation`.
- Produces:
  ```swift
  enum ModelPicker {
      enum Mark: Equatable {
          case downloaded, notDownloaded
          var systemImage: String        // "checkmark", "arrow.down.circle"
      }
      struct Entry: Identifiable {
          let descriptor: ModelDescriptor
          let name: String                // descriptor.displayName
          let line: String
          let mark: Mark?
          let isEnabled: Bool
          let isInUse: Bool
          var id: ModelID { descriptor.id }
      }
      /// whisperCpp tiny.en, whisperCpp base.en, whisperCpp small.en, whisperKit large-v3-turbo.
      static let ladder: [ModelID]
      /// .appleSpeech, .appleDictation.
      static let apple: [ModelID]
      /// The ladder's listed models in ladder order, then Apple's in that order, then the model in
      /// use if it is in neither; empty groups dropped.
      static func sections(_ models: [ModelDescriptor], selected: ModelID?) -> [[Entry]]
      /// The closed box: the name of the model in use; "Model" when none is chosen or it isn't listed yet.
      static func title(_ models: [ModelDescriptor], selected: ModelID?) -> String
  }
  /// One Section per group; each entry a Button that calls `choose`, labelled with the mark's
  /// image (none when nil), the name and the line; disabled when !isEnabled.
  struct ModelPickerItems: View {
      let sections: [[ModelPicker.Entry]]
      let choose: (ModelDescriptor) -> Void
  }
  ```

The rules for marks, lines and choosing (the spec's "Marks and states"):

| State | Mark | Line | Can choose |
|---|---|---|---|
| `.ready` | `.downloaded` | "in use" if in use, else its usual line | yes |
| `.preparing` | `.downloaded` | "preparing" | yes |
| `.notDownloaded` | `.notDownloaded` | its usual line | yes (downloads, then switches) |
| `.downloading(p)` | `.notDownloaded` | "downloading \(Int(p*100))%" | no |
| `.unavailable(reason)` | nil | reason | no |

An off-ladder model is listed only when it is in use, so its usual line is "in use".

- [ ] **Step 1: Write the failing tests**

Fixture: `func d(_ id: ModelID, _ name: String, _ state: ModelDescriptor.State = .ready) -> ModelDescriptor`. `all` lists all nine in `AppModel.engines()` order: whisper.cpp tiny, base, small; Apple Speech, Apple Dictation; WhisperKit tiny, base, small, large-v3-turbo.

```swift
func testTheLadderComesFirstThenApple() {
    let s = ModelPicker.sections(all, selected: .whisperCppBase)
    XCTAssertEqual(s.map { $0.map(\.name) },
                   [["Fastest", "Fast", "Slow", "Slowest"], ["Apple Speech", "Apple Dictation"]])
    XCTAssertEqual(s.map { $0.map(\.line) },
                   [["more mistakes", "in use", "fewer mistakes", "fewest mistakes"],
                    ["built into macOS", "built into macOS"]])
}
func testMarksAndLinesFollowEachState() {
    // tiny .ready, small .notDownloaded, large .downloading(0.4), appleDictation .unavailable("Not supported on this Mac")
    // expect: tiny .downloaded "more mistakes" enabled; small .notDownloaded "fewer mistakes" enabled;
    //         large .notDownloaded "downloading 40%" disabled; appleDictation nil "Not supported on this Mac" disabled
}
func testAPreparingModelInUseSaysPreparing() {
    // selected large-v3-turbo, .preparing → mark .downloaded, line "preparing", enabled
}
func testAnAppleModelNotYetInstalledOffersItsDownload() {
    // appleSpeech .notDownloaded → mark .notDownloaded, line "built into macOS", enabled
}
func testAModelOffTheLadderInUseIsListedLast() {
    let s = ModelPicker.sections(all, selected: ModelID(engine: .whisperKit, name: "base.en"))
    XCTAssertEqual(s.last?.map(\.name), ["WhisperKit base"])
    XCTAssertEqual(s.last?.first?.line, "in use")
    XCTAssertEqual(s.count, 3)
}
func testOffLadderModelsAreHiddenWhenNotInUse() {
    let names = ModelPicker.sections(all, selected: .whisperCppBase).flatMap { $0.map(\.name) }
    XCTAssertFalse(names.contains { $0.hasPrefix("WhisperKit") })
}
func testTheClosedBoxNamesTheModelInUse() {
    XCTAssertEqual(ModelPicker.title(all, selected: .whisperCppBase), "Fast")
    XCTAssertEqual(ModelPicker.title([], selected: .whisperCppBase), "Model")
    XCTAssertEqual(ModelPicker.title(all, selected: nil), "Model")
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ModelPickerTests|MenuBarContentTests" > /tmp/t2.txt 2>&1; tail -30 /tmp/t2.txt`
Expected: build errors for `ModelPicker`.

- [ ] **Step 3: Implement `ModelPicker` and `ModelPickerItems`; wire the menu bar**

- **The two-line label.** Label each button `Label { Text(name); Text(line) } icon: { … }`.
  - If macOS's menu draws only one line from that, fall back to `Text("\(name) — \(line)")` (spec call 7).
  - Say in your report which one shows.
- **The menu bar.** `MenuBarContent.modelMenu` keeps its title and "Loading models…". Its body becomes:
  ```swift
  ModelPickerItems(sections: ModelPicker.sections(model.models, selected: model.selectedModel)) { d in
      Task { await model.choose(d) }
  }
  ```
  Keep each item's `.help(descriptor.detail)`.

- [ ] **Step 4: Run them and see them pass; then the whole suite**

Run: the Step 2 command, then the full suite as in Task 1 Step 4.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: model picker marks downloads and the model in use"
```

---

### Task 3: The sidebar's box, side by side

**Files:**
- Modify: `Sources/VoiceDictationUI/Window/Sidebar.swift`:
  - `footer` becomes one row.
  - New init parameters; drop `hotkey`, `doubleTap` and `hotkeyReminder(for:doubleTap:)`.
- Modify: `Sources/VoiceDictationUI/Window/SettingsView.swift`: `private struct PrismSwitch` becomes internal (`struct PrismSwitch`), so the sidebar uses the same switch.
- Modify: `Sources/VoiceDictationUI/Window/MainWindow.swift:28-29` (what it passes).
- Modify: `DESIGN.md`: a Components line for the sidebar's box.
- Modify: `CLAUDE.md`: the Known Constraints line becomes "Mini View" in the menu and the sidebar.
- Test: in `Tests/VoiceDictationUITests/LibraryModelTests.swift`, delete `testTheSidebarFooterNamesTheHotkeyAndTheDoubleTap`. The reminder is gone.

**Interfaces:**
- Consumes:
  - `ModelPicker.title`, `ModelPicker.sections` and `ModelPickerItems` (Task 2)
  - `AppModel.miniViewEnabled { get set }`, `AppModel.choose(_:)`, `AppModel.models` and `AppModel.selectedModel`
- Produces: `Sidebar(library: LibraryModel, models: [ModelDescriptor], selectedModel: ModelID?, miniViewEnabled: Binding<Bool>, choose: @escaping (ModelDescriptor) -> Void)`

- [ ] **Step 1: Delete the reminder's test, then build to see it fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -5` after changing `Sidebar`'s init.
Expected: errors at `MainWindow`'s call. Nothing else should use `hotkeyReminder`.

- [ ] **Step 2: Implement the row**

```
HStack(spacing: Theme.Space.sm):
  Menu { ModelPickerItems(...) or Text("Loading models…") when models is empty } label: {
      Text(ModelPicker.title(models, selected:)) Theme.Font.ui(12, medium: true), text, lineLimit 1, truncationMode .tail
      Image(systemName: "chevron.up.chevron.down") Theme.Font.ui(9, medium: true), textMuted
  }  .menuStyle(.button) .buttonStyle(.plain) .menuIndicator(.hidden)
     .accessibilityLabel("Model") .accessibilityValue(title)
  Spacer(minLength: Theme.Space.sm)
  Text("Mini View") Theme.Font.ui(12), textMuted, fixedSize
  PrismSwitch(title: "Mini View", isOn: miniViewEnabled)
```

- Keep the box's padding (`Theme.Space.sm`) and its hairline on top.
- The name gives way first (`layoutPriority`), so the switch and its label never squeeze. A long name ends in "…" (spec call 6).
- `MainWindow` passes:
  ```swift
  miniViewEnabled: Binding(get: { model.miniViewEnabled }, set: { model.miniViewEnabled = $0 }),
  choose: { d in Task { await model.choose(d) } }
  ```

- [ ] **Step 3: DESIGN.md and CLAUDE.md**

**DESIGN.md**, under Components, beside the Projects & apps panel line:

> **Sidebar box:** one row under a hairline. On the left, the model picker: the name in Work Sans 500 12, the text colour, and a muted chevron; it opens the system menu, with ✓ for downloaded, ↓ for not downloaded, and a muted line under each name. On the right, "Mini View" in Work Sans 12, muted, and Prism's switch.

**CLAUDE.md:** change `("Mini View" in the menu, off by default)` to `("Mini View" in the menu bar menu and the sidebar, off by default)`.

- [ ] **Step 4: The whole suite, the lint and the app build**

Run, in order:
1. The full suite as in Task 1 Step 4.
2. `npx --yes @google/design.md lint DESIGN.md`
3. The app build, into `.build/xcode-check` (Danny's dev copy runs from `.build/xcode`):
   ```bash
   cp Package.resolved .build/Package.resolved.committed && xcodegen && \
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme VoiceDictation -configuration Debug \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-check build 2>&1 | tail -3; \
   cp .build/Package.resolved.committed Package.resolved
   ```

Expected:
- All tests pass.
- Lint: 0 errors (the 6 warnings were there before).
- `** BUILD SUCCEEDED **`.
- `git status` shows no change to `Package.resolved`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests DESIGN.md CLAUDE.md docs/superpowers/specs/2026-11-22-sidebar-model-picker-design.md docs/superpowers/plans/2026-11-22-sidebar-model-picker.md
git commit -m "feat: model picker and Mini View switch in the sidebar"
```

---

## For Danny, once it's built (hands-on)

- The sidebar's box shows the model's name with a chevron on the left, and "Mini View" with its switch on the right, on one line.
- The switch turns the tab on and off. The menu bar's Mini View tick follows it, and the other way round.
- Open the picker:
  - Fastest, Fast, Slow and Slowest come first, then Apple's two.
  - Each has ✓ or ↓, and a line under it (or after it, if macOS menus allow only one line).
  - Fast reads "in use".
- Click a ↓ model. It downloads, its line counts up, and dictation switches to it when the download finishes.
- The menu bar's Model submenu shows the same list.
- The Models page shows each plain name, with the technical name under it.
- Apple's names in the closed box: do they fit, or end in "…"?
