# SwiftAcervoUI — Components & Persistence Reference

`SwiftAcervoUI` is a thin SwiftUI layer on top of [`SwiftAcervo`](USAGE-library.md). It ships three drop-in components for managing on-device AI models plus a SwiftData-backed persistence scaffold (`StoredModelReference`) for hosting apps that want to keep an editable catalog without rolling their own store.

The components are deliberately decoupled from any specific persistence stack — they consume value-type row items (`AcervoModelRowItem`) and call back into closures the host provides. The persistence layer is a separate, opt-in convenience that an app can adopt without touching the components, or skip entirely.

---

## Installation

`SwiftAcervoUI` is a second product of the same package. Add it alongside `SwiftAcervo`:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftAcervo", package: "SwiftAcervo"),
        .product(name: "SwiftAcervoUI", package: "SwiftAcervo"),
    ]
)
```

`import SwiftAcervoUI` re-exports nothing from `SwiftAcervo` — import both modules where you need both.

---

## The components

### `AcervoModelRowItem`

A `Sendable` value type that carries the data one row needs. The host constructs one of these from whatever domain type it already has (a `StoredModelReference`, a `let` constant, a hard-coded catalog entry, etc.).

```swift
let item = AcervoModelRowItem(
    id: "black-forest-labs/FLUX.2-klein-4B",
    displayName: "FLUX.2 Klein 4B",
    subtitleLines: ["4.2 GB", "8 GB RAM minimum"],
    groupID: "flux",
    groupDisplayName: "FLUX engines"
)
```

- `id` — stable Acervo slug; passed back to every closure so the host can dispatch.
- `displayName` / `subtitleLines` — labels rendered by the row.
- `groupID` + `groupDisplayName` — opt-in grouping for `AcervoModelsSection`. When both are set, rows sharing a `groupID` render under one caption header.

### `AcervoModelsSection`

A reusable `Section` for a host app's Settings `Form`. Renders the supplied items, grouped if requested, with one `AcervoModelDownloadRow` per item.

```swift
Form {
    AcervoModelsSection(
        items: viewModel.rowItems,
        availability: { item in
            await acervo.availability(slug: item.id)
        },
        download: { item, progress in
            try await acervo.ensureAvailable(slug: item.id) { progress($0) }
        },
        deleteModel: { item in
            try await acervo.delete(slug: item.id)
        }
    )

    // ... your other settings sections
}
```

Three closures connect the rows to your download stack:

| Closure        | When called                                | Returns                                         |
| -------------- | ------------------------------------------ | ----------------------------------------------- |
| `availability` | Row appears / app returns to foreground    | `ModelAvailability` (`.available` / `.notAvailable` / `.checking`) |
| `download`     | User taps the download / try-again button  | `Void`; throws on failure; reports `Double` progress |
| `deleteModel`  | User taps the delete (trash) button        | `Void`; throws on failure                       |

`headerAccessibilityIdentifier` lets you keep your existing UI-test selectors stable (e.g. `"settings.modelsSection"`).

### `AcervoModelDownloadRow`

The single-row widget used inside `AcervoModelsSection`. Use it directly if you need bespoke layout outside a `Form`. Same closure contract as the section.

### `AcervoModelsList`

A **full-screen catalog manager** backed by a `@Query` against `StoredModelReference` (see [Persistence](#persistence-storedmodelreference) below). The list groups records by `groupID`, drives each row through `AcervoModelDownloadRow`, owns selection, and — when the underlying store is writable — exposes add/remove/edit affordances via a toolbar and per-row context menu.

Unlike `AcervoModelsSection` (a passive widget that takes value-type items), `AcervoModelsList` owns the SwiftData query and the mutating UI. It expects a `ModelContainer` configured with `StoredModelReference` to be in the environment.

```swift
NavigationStack {
    AcervoModelsList(
        availability: { item in
            await Acervo.availability(item.id)
        },
        download: { item, progress in
            try await Acervo.ensureAvailable(
                item.id,
                files: [],
                progress: { progress($0.overallProgress) }
            )
        },
        deleteModel: { item in
            try Acervo.deleteModel(item.id)
        }
    )
    .navigationTitle("Models")
}
```

Customization knobs:

| Parameter      | Default                                                  | Purpose                                                 |
| -------------- | -------------------------------------------------------- | ------------------------------------------------------- |
| `sortBy`       | `[\.groupDisplayName, \.createdAt]`                      | Sort descriptors handed to the underlying `@Query`.     |
| `editability`  | `.automatic`                                             | Gates the mutating UI. See below.                       |
| `availability` | —                                                        | Same contract as `AcervoModelsSection`.                 |
| `download`     | —                                                        | Same contract as `AcervoModelsSection`.                 |
| `deleteModel`  | —                                                        | Called for both the row's trash button *and* the list's bulk-remove actions. |

#### Editability

`AcervoModelsList.Editability` controls whether the toolbar, context menu, and edit sheets are exposed:

- **`.automatic`** *(default)* — read from the `ModelContext`'s container configurations. The list is editable iff *every* `ModelConfiguration` returned by `context.container.configurations` has `allowsSave == true`. This is the recommended setting: it tracks the store's writability automatically.
- **`.editable`** — always show mutating UI. Useful if you intentionally want the list to attempt writes even on a read-only store (SwiftData will throw on `save`, which lets you surface that as a host-level error).
- **`.readOnly`** — always hide mutating UI, even when the store accepts writes. Useful for "viewer" / "presenter" modes.

To make the underlying SwiftData store genuinely read-only (so save attempts actually fail at the data layer, not just in the UI), construct your `ModelContainer` with `ModelConfiguration(allowsSave: false)`:

```swift
let readOnlyConfig = ModelConfiguration(
    "AcervoReadOnly",
    schema: Schema([StoredModelReference.self]),
    isStoredInMemoryOnly: false,
    allowsSave: false
)

let container = try ModelContainer(
    for: StoredModelReference.self,
    migrationPlan: AcervoMigrationPlan.self,
    configurations: readOnlyConfig
)
```

`ModelConfiguration.allowsSave` is Apple's first-class read-only knob — `ModelContext` does not expose a per-context flag; writability is inherited from the store.

#### What it does *not* do

- It does not configure a `ModelContainer` for you — the host wires that up with `AcervoMigrationPlan` (see Persistence below).
- It does not seed fixtures or sample data — the host's responsibility, typically in a one-shot on the container.
- It does not render its own `NavigationStack` — embed it in whatever shell your app uses, and set `.navigationTitle` on the list (or the parent).

### `AcervoStoredModelEditSheet`

The add/edit form `AcervoModelsList` presents internally, also available standalone for hosts that want to drive their own add/edit flow (e.g. a different entry point than the toolbar). The sheet is *value-driven*: it never touches `ModelContext` and instead hands the caller a normalized `Draft` on save.

```swift
AcervoStoredModelEditSheet(mode: .add) { draft in
    let record = StoredModelReference(
        id: draft.id,
        displayName: draft.displayName,
        subtitleLines: draft.subtitleLines,
        groupID: draft.normalizedGroupID,
        groupDisplayName: draft.normalizedGroupDisplayName,
        origin: draft.normalizedOrigin
    )
    context.insert(record)
}
```

In `.edit(_:)` mode the identifier field is locked (the slug is the primary key and cannot be renamed in place — delete + re-insert to "rename").

### `AcervoModelDownloadInterstitial`

A first-launch / no-model-present prompt. Use this in place of your main UI when no model is downloaded yet — it walks the user through downloading a single nominated model. Internally drives the same controller as the row, so its state machine is identical.

```swift
if viewModel.allModelsMissing {
    AcervoModelDownloadInterstitial(
        item: viewModel.defaultModel,
        availability: { await acervo.availability(slug: $0.id) },
        download: { item, progress in
            try await acervo.ensureAvailable(slug: item.id) { progress($0) }
        },
        onSkip: { viewModel.dismissInterstitial() },
        onComplete: { viewModel.dismissInterstitial() }
    )
}
```

All copy is configurable via `LocalizedStringKey`s — defaults are English-only on purpose. Pass localized keys that resolve against your own `Localizable.xcstrings`.

---

## Persistence: `StoredModelReference`

`SwiftAcervoUI` ships an opt-in SwiftData `@Model` you can use to persist the host app's editable model catalog (the list of models the user has added). It is *only* a catalog reference — the binary on disk is still owned by `SwiftAcervo` and resolved through the shared App Group container.

```swift
import SwiftData
import SwiftAcervoUI

// ... inside a SwiftUI View
@Query(sort: \StoredModelReference.createdAt) private var refs: [StoredModelReference]
@Environment(\.modelContext) private var context
```

Fields:

| Property            | Type        | Notes                                                                 |
| ------------------- | ----------- | --------------------------------------------------------------------- |
| `id`                | `String`    | `@Attribute(.unique)` — the Acervo slug (e.g. `org/repo`).            |
| `displayName`       | `String`    | Primary label.                                                        |
| `subtitleLines`     | `[String]`  | Secondary metadata strings.                                           |
| `groupID`           | `String?`   | Optional group key for `AcervoModelsSection` grouping.                |
| `groupDisplayName`  | `String?`   | Caption header; required when `groupID` is set.                       |
| `origin`            | `String?`   | Free-form source URL / host (e.g. `"huggingface.co/org/repo"`).       |
| `createdAt`         | `Date`      | Defaults to `.now`. Drives the default chronological sort.            |

A `rowItem` accessor projects each record into the value type the components consume:

```swift
AcervoModelsSection(
    items: refs.map(\.rowItem),
    availability: { ... },
    download: { ... },
    deleteModel: { ... }
)
```

### Recommended `ModelContainer` setup

`StoredModelReference` is a typealias to the *current* schema version's concrete model type. The library also exports `AcervoMigrationPlan`, an Apple-blessed `SchemaMigrationPlan` that describes how the schema evolves between versions. Pass both to your container so future schema bumps migrate cleanly:

```swift
import SwiftUI
import SwiftData
import SwiftAcervoUI

@main
struct MyApp: App {

    let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: StoredModelReference.self,
                migrationPlan: AcervoMigrationPlan.self
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
```

That's it — every descendant `View` now has a `ModelContext` available via `@Environment(\.modelContext)`, and `@Query` returns live results that update as records are inserted, edited, or deleted.

### Inserting / deleting

```swift
struct AddModelButton: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        Button("Add FLUX.2") {
            let record = StoredModelReference(
                id: "black-forest-labs/FLUX.2-klein-4B",
                displayName: "FLUX.2 Klein 4B",
                subtitleLines: ["4.2 GB", "8 GB RAM minimum"],
                origin: "huggingface.co/black-forest-labs/FLUX.2-klein-4B"
            )
            context.insert(record)
            // Save happens automatically on the next runloop turn;
            // call `try? context.save()` if you need it immediate.
        }
    }
}
```

Deleting a record removes the catalog entry, but the on-disk model binary lives in the shared App Group container and must be cleared separately via `Acervo.delete(slug:)` if you also want to free that disk space.

---

## Versioning the schema with `VersionedSchema`

Once your app ships a build that persists `StoredModelReference`, you cannot edit the model's stored properties in place — every change has to roll forward as a new schema version with an explicit migration. SwiftAcervoUI's persistence layer is built around Apple's `VersionedSchema` / `SchemaMigrationPlan` protocols, so you get a sanctioned migration path out of the box.

### How the pieces fit

```
AcervoSchemaV1 (VersionedSchema)
  └── StoredModelReference  ← @Model owned by V1
AcervoSchemaV2 (VersionedSchema)             ← added when the shape changes
  └── StoredModelReference  ← @Model owned by V2

AcervoMigrationPlan (SchemaMigrationPlan)
  ├── schemas: [V1.self, V2.self]
  └── stages:  [MigrationStage(.lightweight | .custom, from V1, to V2)]

public typealias StoredModelReference = AcervoSchemaV2.StoredModelReference  ← bumped
```

The `StoredModelReference` typealias at module scope always resolves to the *latest* shipped version — that's why your app code can keep writing the bare name without caring which `V<N>` it points at this release.

### Adding `AcervoSchemaV2`

Worked example: you decide to split `origin` into a structured `OriginKind` enum + an opaque `originPath` string, and rename `subtitleLines` to `metadataLines`.

1. **Create the new versioned schema.** Add `Sources/SwiftAcervoUI/Persistence/AcervoSchemaV2.swift`:

   ```swift
   import Foundation
   import SwiftData

   public enum AcervoSchemaV2: VersionedSchema {

       public static var versionIdentifier: Schema.Version {
           Schema.Version(2, 0, 0)
       }

       public static var models: [any PersistentModel.Type] {
           [StoredModelReference.self]
       }

       public enum OriginKind: String, Codable, Sendable {
           case huggingFace, cdn, local, custom
       }

       @Model
       public final class StoredModelReference {
           @Attribute(.unique) public var id: String
           public var displayName: String
           public var metadataLines: [String]
           public var groupID: String?
           public var groupDisplayName: String?
           public var originKind: OriginKind?
           public var originPath: String?
           public var createdAt: Date

           public init(
               id: String,
               displayName: String,
               metadataLines: [String] = [],
               groupID: String? = nil,
               groupDisplayName: String? = nil,
               originKind: OriginKind? = nil,
               originPath: String? = nil,
               createdAt: Date = .now
           ) {
               self.id = id
               self.displayName = displayName
               self.metadataLines = metadataLines
               self.groupID = groupID
               self.groupDisplayName = groupDisplayName
               self.originKind = originKind
               self.originPath = originPath
               self.createdAt = createdAt
           }
       }
   }
   ```

2. **Append the V2 version and a migration stage** in `AcervoMigrationPlan.swift`:

   ```swift
   public enum AcervoMigrationPlan: SchemaMigrationPlan {

       public static var schemas: [any VersionedSchema.Type] {
           [AcervoSchemaV1.self, AcervoSchemaV2.self]
       }

       public static var stages: [MigrationStage] {
           [v1ToV2]
       }

       static let v1ToV2 = MigrationStage.custom(
           fromVersion: AcervoSchemaV1.self,
           toVersion: AcervoSchemaV2.self,
           willMigrate: nil,
           didMigrate: { context in
               // Backfill the parsed origin from V1's free-form string.
               let v2Records = try context.fetch(
                   FetchDescriptor<AcervoSchemaV2.StoredModelReference>()
               )
               for record in v2Records {
                   guard let path = record.originPath, !path.isEmpty else { continue }
                   if path.hasPrefix("huggingface.co/") {
                       record.originKind = .huggingFace
                   } else if path.hasPrefix("cdn.") {
                       record.originKind = .cdn
                   } else {
                       record.originKind = .custom
                   }
               }
               try context.save()
           }
       )
   }
   ```

   Use `.lightweight(fromVersion:toVersion:)` instead of `.custom(...)` when the change is purely additive (new optional property), a clean rename via `@Attribute(originalName:)`, or a removed property — SwiftData infers those without code.

3. **Bump the typealias** in `AcervoSchema.swift`:

   ```swift
   public typealias StoredModelReference = AcervoSchemaV2.StoredModelReference
   ```

4. **Ship.** Hosting apps that already pass `AcervoMigrationPlan.self` to `ModelContainer` get the migration automatically on next launch. SwiftData walks `stages` in order; existing stores at V1 advance to V2.

### Migration ground rules

- **Never edit a shipped `AcervoSchemaV<N>`.** Treat each version as immutable once released; new changes go into `V(N+1)`.
- **Test the migration path with real V1 data.** Create a small unit test that writes a V1 store, opens it with the V2 container, and asserts the post-migration shape. `MigrationStage`'s `didMigrate` closure runs against the destination context — that's the canonical place to backfill.
- **Lightweight covers additions, renames (via `originalName:`), and deletions.** Type changes, splits/merges, and any logic that depends on existing data require `.custom`.
- **Renames need `@Attribute(originalName: "oldName")`** on the V2 property so SwiftData maps the old column. Without it, the property is treated as new and the data is dropped.
- **The host app must keep passing the same `AcervoMigrationPlan`.** A `ModelContainer` constructed without a migration plan will throw on a store whose schema differs from the current models.

### When the host app already has its own SwiftData store

If you have an existing `ModelContainer` with its own migration plan, compose rather than replace:

```swift
let container = try ModelContainer(
    for: Schema([
        StoredModelReference.self,
        MyOtherEntity.self,
    ]),
    migrations: [AcervoMigrationPlan.self, MyOwnMigrationPlan.self],
    configurations: [.init(isStoredInMemoryOnly: false)]
)
```

Each plan is responsible only for the model types it owns. Apple's design assumes one migration plan per `ModelContainer`; merge both versions into a single plan in your app target if you need that shape.

---

## When *not* to adopt `StoredModelReference`

If your app already has a stable catalog (hard-coded entries, server-fetched JSON, or your own SwiftData store), keep using whatever you have and map directly to `AcervoModelRowItem` at the call site. The components do not care where the data came from. The persistence scaffold is purely a convenience for apps that want a SwiftData-backed editable list with first-class versioning out of the box.
