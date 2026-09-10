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

enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

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
        CriterionGuidance.self,
        Candidate.self,
        Interview.self,
        InterviewPhase.self,
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

/// SchemaV3 adds optional resume-analysis fields to `Candidate`
/// (`resumeSummary`, `characterSheetJSON`, `resumeAnalyzedAt`). Purely
/// additive — auto-migration handles it.
enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV2.models }
}

/// SchemaV4 adds `RoleRubricLink` (the join model for many-to-many
/// Rubric↔Role with per-link strictness metadata) plus the
/// corresponding `roleLinks` / `roleRubricLinks` relationships on
/// `Rubric` and `InterviewRole`. The legacy `Rubric.role` single
/// pointer stays for backward compat. Purely additive.
enum SchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV3.models + [RoleRubricLink.self]
    }
}

/// SchemaV5 adds `RubricSection.candidateInstructions` (optional markdown
/// brief). Briefly used as a per-section field; superseded by the
/// rubric-level field in V6. Field stays on the model for backward
/// compat reads.
enum SchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV4.models }
}

/// SchemaV6 promotes the candidate brief from the section level to the
/// rubric level — briefs describe the whole phase, not individual
/// rubric sections. Adds `Rubric.candidateInstructions`. The legacy
/// `RubricSection.candidateInstructions` field stays on the model
/// unused for backward compat. Purely additive.
enum SchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV5.models }
}

/// SchemaV7 adds:
/// - `InterviewImpression.aiValue` — AI's independent trait read so it
///   doesn't clobber the interviewer's manual rating.
/// - `InterviewNote.phase` — phase the note was captured under, plus
///   the inverse `InterviewPhase.notes` collection. Lets the live notes
///   panel group by phase.
/// Purely additive — auto-migration handles it.
enum SchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV6.models }
}

/// SchemaV8 adds `InterviewPhase.iconName` (optional SF Symbol). Purely
/// additive.
enum SchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV7.models }
}

/// SchemaV11 adds external-info fields to `Candidate`: `linkedInURL`,
/// `githubUsername`, `personalSiteURL`, `githubSummary`,
/// `githubFetchedAt`. All optional strings/dates — purely additive,
/// lightweight migration.
enum SchemaV11: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(11, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV10.models }
}

/// SchemaV10 adds `InterviewPhase.assignedInterviewers` — an optional
/// many-to-many link to `Contact` so each phase can carry its own panel
/// (e.g., Alice owns System Design, Bob runs Coding). Empty array on a
/// phase means "no per-phase narrowing — everyone on the interview-level
/// panel runs this phase." Purely additive — lightweight migration.
enum SchemaV10: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(10, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV9.models }
}

/// SchemaV9 introduces interview templates as a first-class concept:
/// `InterviewTemplate`, `InterviewTemplatePhase`, `TemplateRoleLink`.
/// Plus additive fields on existing models:
/// - `Interview.template` (optional relation) and
///   `Interview.templateNameAtSchedule` (denormalized snapshot string,
///   so historical interviews keep their template label even after the
///   template is renamed or deleted).
/// - `InterviewPhase.targetMinutes` and `InterviewTemplatePhase.targetMinutes`
///   for soft per-phase time-boxing.
/// - `InterviewTemplatePhase.briefOverride` schema field reserved for a
///   future per-template brief override; UI in v1 always defers to the
///   rubric-level brief.
/// All changes are additive — lightweight migration handles V8 → V9.
enum SchemaV9: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV8.models + [
            InterviewTemplate.self,
            InterviewTemplatePhase.self,
            TemplateRoleLink.self
        ]
    }
}

/// SchemaV12 adds `Interview.lastScoredAt` — timestamp of the most recent
/// AI scoring pass (end-of-interview final analysis or a manual "Score All
/// Sections" run), surfaced in the scorecard header. Optional date —
/// purely additive, lightweight migration.
enum SchemaV12: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(12, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV11.models }
}

/// SchemaV13 adds `InterviewRole.templateRoleLinks` — the inverse of
/// `TemplateRoleLink.role`, mirroring `roleRubricLinks`. Lets a role
/// enumerate its linked templates without a full-table scan. Purely
/// additive, lightweight migration.
enum SchemaV13: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(13, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV12.models }
}

/// SchemaV14 adds `Interview.scheduledAt` — the planned slot picked at
/// interview-creation time. Optional, lightweight migration; pre-existing
/// interviews keep `nil` and the list falls back to `createdAt`.
enum SchemaV14: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(14, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV13.models }
}

/// SchemaV15 adds `Interview.interruptedAt` — set by app-launch orphan
/// recovery when a `.recording` row was reverted to `.scheduled`, so the
/// Interviews list can badge it instead of looking identical to a never-
/// started row. Optional, lightweight migration.
enum SchemaV15: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(15, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV14.models }
}

/// SchemaV16 adds `ActionItem.dismissedAt` — distinguishes "won't do" from
/// "done" and from "still pending". Lightweight migration; pre-existing
/// items keep `nil` and stay pending.
enum SchemaV16: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(16, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV15.models }
}

/// SchemaV17 adds `ScreenShareFrame` — kept screenshots of a shared-screen
/// window during a recording, with a cascade relationship from `Meeting`
/// (`Meeting.screenFrames`). Image bytes live on the file system; the row
/// carries metadata, OCR text, and the AI observation. New model + optional
/// relationship — lightweight migration.
enum SchemaV17: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(17, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV16.models + [ScreenShareFrame.self]
    }
}

/// SchemaV18 adds two independent models in one bump (they ship in the same
/// release):
/// - `ShareSessionSummary` — per-share-session synthesized narrative, with a
///   cascade relationship from `Meeting` (`Meeting.sessionSummaries`).
/// - `AIUsageEvent` — the AI usage ledger; deliberately relationship-free
///   (plain `meetingID: UUID?`) so it survives meeting deletion.
/// New models + one optional relationship — lightweight migration.
enum SchemaV18: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(18, 0, 0) }
    static var models: [any PersistentModel.Type] {
        SchemaV17.models + [ShareSessionSummary.self, AIUsageEvent.self]
    }
}

/// SchemaV19 adds `Meeting.sourceAppBundleID` / `sourceAppName` — which app
/// the call was held in, so Discord and Teams meetings can be told apart
/// after the fact. Two optional attributes, no new entity — lightweight
/// migration; pre-existing meetings keep `nil`.
enum SchemaV19: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(19, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV18.models }
}

/// SchemaV20 adds `Meeting.absentAttendeeIDs` — invitees marked as not
/// having attended. One defaulted array attribute, no new entity —
/// lightweight migration; pre-existing meetings get an empty list.
enum SchemaV20: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(20, 0, 0) }
    static var models: [any PersistentModel.Type] { SchemaV19.models }
}

enum GreyEminenceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self, SchemaV6.self, SchemaV7.self, SchemaV8.self, SchemaV9.self, SchemaV10.self, SchemaV11.self, SchemaV12.self, SchemaV13.self, SchemaV14.self, SchemaV15.self, SchemaV16.self, SchemaV17.self, SchemaV18.self, SchemaV19.self, SchemaV20.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
            .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
            .lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self),
            .lightweight(fromVersion: SchemaV4.self, toVersion: SchemaV5.self),
            .lightweight(fromVersion: SchemaV5.self, toVersion: SchemaV6.self),
            .lightweight(fromVersion: SchemaV6.self, toVersion: SchemaV7.self),
            .lightweight(fromVersion: SchemaV7.self, toVersion: SchemaV8.self),
            .lightweight(fromVersion: SchemaV8.self, toVersion: SchemaV9.self),
            .lightweight(fromVersion: SchemaV9.self, toVersion: SchemaV10.self),
            .lightweight(fromVersion: SchemaV10.self, toVersion: SchemaV11.self),
            .lightweight(fromVersion: SchemaV11.self, toVersion: SchemaV12.self),
            .lightweight(fromVersion: SchemaV12.self, toVersion: SchemaV13.self),
            .lightweight(fromVersion: SchemaV13.self, toVersion: SchemaV14.self),
            .lightweight(fromVersion: SchemaV14.self, toVersion: SchemaV15.self),
            .lightweight(fromVersion: SchemaV15.self, toVersion: SchemaV16.self),
            .lightweight(fromVersion: SchemaV16.self, toVersion: SchemaV17.self),
            .lightweight(fromVersion: SchemaV17.self, toVersion: SchemaV18.self),
            .lightweight(fromVersion: SchemaV18.self, toVersion: SchemaV19.self),
            .lightweight(fromVersion: SchemaV19.self, toVersion: SchemaV20.self)
        ]
    }
}
