import Foundation
import SwiftData

/// Versioned schema declarations for the app's SwiftData store.
///
/// Why this exists: without a `VersionedSchema`, every model change risks
/// breaking existing user stores with no migration path. With this in place,
/// evolving the schema becomes a structured process:
///
/// 1. Add a new `SchemaV2` enum below that points at the updated model types.
/// 2. Add a `MigrationStage` to `GreyEminenceMigrationPlan.stages` — either
///    `.lightweight` (for additive, non-breaking changes) or `.custom` (for
///    property renames, type changes, entity splits, etc.).
/// 3. Bump `GreyEminenceMigrationPlan.currentSchema` to the new version.
///
/// The first version simply wraps the existing models. Switching an existing
/// non-versioned store to `SchemaV1` is a lightweight migration — the model
/// shapes haven't changed, so SwiftData loads the store transparently.
///
/// Safety net: even if a schema change goes wrong, `StoreBackupService` keeps
/// daily copies of the store in `AppSupport/GreyEminence/backups/` for 7 days.
enum SchemaV1: VersionedSchema {
    // Computed properties rather than `static let` because `Schema.Version`
    // isn't `Sendable` on Xcode 16's toolchain — storing it as a stored static
    // fails Swift 6 strict concurrency checking. Computing it per-access
    // sidesteps the shared-mutable-state check cleanly.
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
        Meeting.self,
        TranscriptSegment.self,
        ActionItem.self,
        MeetingInsight.self,
        Contact.self,
        // Interview feature
        Department.self,
        Team.self,
        RoleLevel.self,
        InterviewRole.self,
        Rubric.self,
        RubricSection.self,
        RubricCriterion.self,
        RubricBonusSignal.self,
        Candidate.self,
        Interview.self,
        InterviewSectionScore.self,
        InterviewImpression.self,
        InterviewImpressionTrait.self,
        InterviewBookmark.self,
        InterviewNote.self,
        ScoreEvidence.self,
        CriterionEvaluation.self,
        CriterionEvidence.self,
        ]
    }
}

/// Migration plan for the SwiftData store. Each new `SchemaV*` version is
/// appended to `schemas` along with a corresponding `MigrationStage` in
/// `stages`. Lightweight migration (adding optional fields, etc.) works
/// automatically and doesn't need an explicit stage.
enum GreyEminenceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // No migrations yet — SchemaV1 is the first versioned snapshot.
        // When you add SchemaV2, add a stage like:
        //   .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
        // or for property renames / custom transforms:
        //   .custom(
        //     fromVersion: SchemaV1.self,
        //     toVersion: SchemaV2.self,
        //     willMigrate: { context in ... },
        //     didMigrate: { context in ... }
        //   )
        []
    }
}
