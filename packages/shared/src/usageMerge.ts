/**
 * Merges per-environment usage summaries into the single view the page renders.
 *
 * Pure, so the de-duplication and derivation rules can be tested without a
 * connected environment.
 *
 * @module usageMerge
 */
import {
  USAGE_MERGE_COMPATIBLE_SINCE,
  type EnvironmentId,
  type UsageBucket,
  type UsageProviderKind,
  type UsageSource,
  type UsageSourceFingerprint,
  type UsageSummary,
  type UsageTokenTotals,
} from "@t3tools/contracts";

import { modelFamily, type ModelFamily } from "./usageModelFamily.ts";

export interface EnvironmentUsage {
  readonly environmentId: EnvironmentId;
  readonly label: string;
  readonly summary: UsageSummary;
}

/**
 * What the per-row list, the period chart and the period table are keyed by:
 * the harness that ran the work, or the vendor family of the model. Totals,
 * mixes and cost quality are grand totals and do not depend on it.
 */
export type UsageGroupBy = "harness" | "family";

/** A provider when grouped by harness, a model family when grouped by family. */
export type UsageGroupKey = UsageProviderKind | ModelFamily;

export interface GroupTotals {
  readonly key: UsageGroupKey;
  readonly costUsd: number;
  readonly totalTokens: number;
  /** Distinct assistant responses. */
  readonly records: number;
  /**
   * Distinct sessions, only when grouped by harness. A session can use models
   * from several families, so per-family counts would double count.
   */
  readonly sessions?: number;
  /** The part of `costUsd` priced from model rates rather than reported. */
  readonly estimatedCostUsd: number;
  readonly costShare: number;
  readonly tokenShare: number;
}

/** One group's share of a day or hour. */
export interface PeriodGroupTotals {
  readonly costUsd: number;
  readonly totalTokens: number;
  /** The part of `costUsd` priced from model rates rather than reported. */
  readonly estimatedCostUsd: number;
}

export interface ModelTotals {
  readonly model: string;
  /** The harness that ran it; grouped by family, the one with the most cost. */
  readonly provider: UsageProviderKind;
  /**
   * Every harness that ran it, largest cost first. Grouped by harness, a model
   * row belongs to one harness, so this is just `[provider]`.
   */
  readonly providers: readonly UsageProviderKind[];
  readonly family: ModelFamily;
  readonly costUsd: number;
  /** The part of `costUsd` priced from model rates rather than reported. */
  readonly estimatedCostUsd: number;
  readonly totalTokens: number;
  readonly tokens: UsageTokenTotals;
  readonly records: number;
  /**
   * Records whose tokens are counted here but which contributed nothing to
   * `costUsd`. When it equals `records` the cost is unknown, not zero.
   */
  readonly unpricedRecords: number;
  /**
   * Tokens with no known rates, which a custom price would cover. A cell that
   * mixes these with reported costs counts its tokens by record share.
   */
  readonly unpricedTokens: number;
  readonly costShare: number;
  readonly tokenShare: number;
}

/**
 * A model whose every record lacked rates has an unknown cost, not a zero one.
 * Clients must not present its `costUsd` as a real dollar figure.
 */
/** The smallest share of a cost priced from model rates that marks it as an estimate. */
export const ESTIMATE_MARK_MIN_SHARE = 0.01;

/**
 * The share of `costUsd` priced from model rates, when it is large enough to
 * mark: a sliver of rate-priced usage beside mostly reported cost does not
 * make the total an estimate. `null` means show no mark.
 */
export function estimatedCostShare(costUsd: number, estimatedCostUsd: number): number | null {
  if (!(costUsd > 0) || !(estimatedCostUsd > 0)) return null;
  const share = Math.min(1, estimatedCostUsd / costUsd);
  return share >= ESTIMATE_MARK_MIN_SHARE ? share : null;
}

export function isModelCostUnknown(model: ModelTotals): boolean {
  return model.records > 0 && model.unpricedRecords >= model.records;
}

export interface DailyTotals {
  readonly day: string;
  readonly costUsd: number;
  readonly totalTokens: number;
  readonly byGroup: ReadonlyMap<UsageGroupKey, PeriodGroupTotals>;
}

export interface HourlyTotals {
  readonly day: string;
  readonly hourStart: string;
  readonly costUsd: number;
  readonly totalTokens: number;
  readonly byGroup: ReadonlyMap<UsageGroupKey, PeriodGroupTotals>;
}

export interface CostQuality {
  readonly providerReportedShare: number;
  readonly modelPricedShare: number;
  readonly unpricedShare: number;
  readonly cacheSavingsUsd: number;
}

/**
 * `costUsd` by token category. `unsplit` is cost no rates could split,
 * including all cost from servers that predate the split.
 */
export interface CategoryCost {
  readonly input: number;
  readonly cacheRead: number;
  readonly cacheWrite: number;
  readonly output: number;
  readonly unsplit: number;
}

/** `costUsd` by request speed. Servers that predate speeds count as standard. */
export interface SpeedCost {
  readonly standard: number;
  readonly fast: number;
  readonly ultrafast: number;
  /** What fast and ultrafast requests cost above the standard rate. */
  readonly premium: number;
}

export interface UsageContractMismatch {
  readonly environmentId: EnvironmentId;
  readonly direction: "serverBehind" | "clientBehind";
  readonly contractVersion: number;
}

export interface MergedUsage {
  readonly costUsd: number;
  readonly uncachedInputTokens: number;
  readonly cachedInputTokens: number;
  readonly cacheCreationTokens: number;
  readonly outputTokens: number;
  readonly reasoningTokens: number;
  readonly totalTokens: number;
  readonly records: number;
  readonly sessions: number;
  /** Per harness or per model family, by `groupBy`. */
  readonly groups: readonly GroupTotals[];
  /** Per harness and model, or per model across harnesses when grouped by family. */
  readonly models: readonly ModelTotals[];
  readonly daily: readonly DailyTotals[];
  readonly hourly: readonly HourlyTotals[];
  readonly costQuality: CostQuality;
  readonly categoryCost: CategoryCost;
  readonly speedCost: SpeedCost;
  /** Environments whose data was dropped as a duplicate of another's. */
  readonly duplicateSources: readonly string[];
  readonly contributingEnvironments: readonly EnvironmentId[];
  readonly contractMismatches: readonly UsageContractMismatch[];
}

/**
 * Two sources are the same physical transcript directory only when host,
 * provider, path and filesystem identity all agree.
 *
 * `volumeId` is what stops two machines that happen to share a hostname and a
 * home path, which is every Mac in a fleet, from collapsing into one source and
 * having one of them silently dropped.
 */
function fingerprintKey(fingerprint: UsageSourceFingerprint): string {
  return [
    fingerprint.hostId,
    fingerprint.provider,
    fingerprint.resolvedHomePath,
    fingerprint.volumeId,
  ].join(" ");
}

function bucketsForSource(summary: UsageSummary, source: UsageSource): readonly UsageBucket[] {
  const providerSources = summary.sources.filter(
    (entry) => entry.fingerprint.provider === source.fingerprint.provider,
  );
  return summary.buckets.filter(
    (bucket) =>
      bucket.provider === source.fingerprint.provider &&
      (bucket.sourcePath === source.fingerprint.resolvedHomePath ||
        (bucket.sourcePath === undefined && providerSources.length === 1)),
  );
}

function bucketKey(bucket: UsageBucket): string {
  return JSON.stringify([bucket.day, bucket.hourStart ?? null, bucket.provider, bucket.model]);
}

/**
 * Decides which environment owns each physical transcript directory.
 *
 * Several environments on one machine (worktree servers, for instance) resolve
 * the same provider home and would otherwise double count every token. The
 * Complete scans claim a fingerprint ahead of partial scans, then the most
 * recently read scan wins within each status. A newer partial scan can still
 * contribute cells absent from an older complete scan. Environment ids break
 * ties so the result is stable when summaries have the same read time.
 */
function claimSources(environments: readonly EnvironmentUsage[]): {
  readonly ownerByFingerprint: ReadonlyMap<string, EnvironmentId>;
  readonly supplementalBucketsByEnvironment: ReadonlyMap<EnvironmentId, ReadonlySet<UsageBucket>>;
  readonly sessionsByFingerprint: ReadonlyMap<string, number>;
  readonly duplicates: readonly string[];
} {
  const ownerByFingerprint = new Map<string, EnvironmentId>();
  const ownerScanByFingerprint = new Map<
    string,
    { environment: EnvironmentUsage; source: UsageSource }
  >();
  const seenBucketKeysByFingerprint = new Map<string, Set<string>>();
  const supplementalBucketsByEnvironment = new Map<EnvironmentId, Set<UsageBucket>>();
  const sessionsByFingerprint = new Map<string, number>();
  const duplicates: string[] = [];

  const ordered = [...environments].sort(
    (a, b) =>
      (Date.parse(b.summary.readAt) || 0) - (Date.parse(a.summary.readAt) || 0) ||
      a.environmentId.localeCompare(b.environmentId),
  );

  // A complete scan takes precedence over a newer partial scan of the same
  // directory. Partial history still contributes when no complete copy exists.
  for (const status of ["ok", "partial", "failed"] as const) {
    for (const environment of ordered) {
      for (const source of environment.summary.sources) {
        if (source.status !== status) continue;
        const key = fingerprintKey(source.fingerprint);
        if (ownerByFingerprint.has(key)) {
          duplicates.push(`${environment.label}: ${source.fingerprint.resolvedHomePath}`);
          continue;
        }
        ownerByFingerprint.set(key, environment.environmentId);
        ownerScanByFingerprint.set(key, { environment, source });
        sessionsByFingerprint.set(key, source.distinctSessions);
      }
    }
  }

  // A newer partial scan may contain usage recorded after an older complete
  // scan. Keep cells absent from the complete scan. Aggregated cells do not
  // reveal enough to reconcile overlapping records without double counting.
  for (const environment of ordered) {
    for (const source of environment.summary.sources) {
      if (source.status !== "partial") continue;
      const key = fingerprintKey(source.fingerprint);
      const owner = ownerScanByFingerprint.get(key);
      if (
        owner?.source.status !== "ok" ||
        Date.parse(environment.summary.readAt) <= Date.parse(owner.environment.summary.readAt)
      ) {
        continue;
      }
      let seen = seenBucketKeysByFingerprint.get(key);
      if (seen === undefined) {
        seen = new Set(bucketsForSource(owner.environment.summary, owner.source).map(bucketKey));
        seenBucketKeysByFingerprint.set(key, seen);
      }
      const supplemental =
        supplementalBucketsByEnvironment.get(environment.environmentId) ?? new Set<UsageBucket>();
      let added = false;
      for (const bucket of bucketsForSource(environment.summary, source)) {
        const cell = bucketKey(bucket);
        if (seen.has(cell)) continue;
        seen.add(cell);
        supplemental.add(bucket);
        added = true;
      }
      if (!added) continue;
      supplementalBucketsByEnvironment.set(environment.environmentId, supplemental);
      sessionsByFingerprint.set(
        key,
        Math.max(sessionsByFingerprint.get(key) ?? 0, source.distinctSessions),
      );
    }
  }

  return {
    ownerByFingerprint,
    supplementalBucketsByEnvironment,
    sessionsByFingerprint,
    duplicates,
  };
}

/** Sources this environment owns after fingerprint claims, plus their buckets. */
function ownedContribution(
  environment: EnvironmentUsage,
  ownerByFingerprint: ReadonlyMap<string, EnvironmentId>,
  supplementalBuckets: ReadonlySet<UsageBucket>,
  sessionsByFingerprint: ReadonlyMap<string, number>,
): {
  readonly buckets: readonly UsageBucket[];
  readonly sessionsByProvider: ReadonlyMap<UsageProviderKind, number>;
} {
  const ownedProviders = new Set<UsageProviderKind>();
  const ownedSources = new Set<string>();
  const sessionsByProvider = new Map<UsageProviderKind, number>();
  for (const source of environment.summary.sources) {
    if (source.status === "missing") continue;
    const key = fingerprintKey(source.fingerprint);
    if (ownerByFingerprint.get(key) === environment.environmentId) {
      const provider = source.fingerprint.provider;
      ownedProviders.add(provider);
      ownedSources.add(`${provider}\u0000${source.fingerprint.resolvedHomePath}`);
      // Distinct within a directory. Summing per-bucket session counts instead
      // would count a session once per day and model it spans.
      sessionsByProvider.set(
        provider,
        (sessionsByProvider.get(provider) ?? 0) +
          (sessionsByFingerprint.get(key) ?? source.distinctSessions),
      );
    }
  }
  return {
    buckets: environment.summary.buckets.filter(
      (bucket) =>
        supplementalBuckets.has(bucket) ||
        (bucket.sourcePath === undefined
          ? ownedProviders.has(bucket.provider)
          : ownedSources.has(`${bucket.provider}\u0000${bucket.sourcePath}`)),
    ),
    sessionsByProvider,
  };
}

function bucketTokens(bucket: UsageBucket): number {
  // reasoningTokens is a subset of outputTokens and must not be added again.
  return (
    bucket.totals.uncachedInputTokens +
    bucket.totals.cachedInputTokens +
    bucket.totals.cacheCreationTokens +
    bucket.totals.outputTokens
  );
}

/**
 * The part of a bucket's cost priced from model rates. Servers that predate
 * `modelPricedCostUsd` only label the bucket, and a `modelPriced` label covers
 * any mix with reported cost, so their whole bucket counts as estimated.
 * Current servers omit the field only when it rounds to zero, which for a
 * `modelPriced` bucket means rates that price its records at nothing.
 */
function bucketEstimatedCostUsd(bucket: UsageBucket): number {
  if (bucket.modelPricedCostUsd !== undefined) return bucket.modelPricedCostUsd;
  return bucket.costSource === "modelPriced" ? bucket.costUsd : 0;
}

export function isCompatibleUsageContractVersion(version: number, expected: number): boolean {
  return version >= USAGE_MERGE_COMPATIBLE_SINCE && version <= expected;
}

const EMPTY_MERGED: MergedUsage = {
  costUsd: 0,
  uncachedInputTokens: 0,
  cachedInputTokens: 0,
  cacheCreationTokens: 0,
  outputTokens: 0,
  reasoningTokens: 0,
  totalTokens: 0,
  records: 0,
  sessions: 0,
  groups: [],
  models: [],
  daily: [],
  hourly: [],
  costQuality: {
    providerReportedShare: 0,
    modelPricedShare: 0,
    unpricedShare: 0,
    cacheSavingsUsd: 0,
  },
  categoryCost: { input: 0, cacheRead: 0, cacheWrite: 0, output: 0, unsplit: 0 },
  speedCost: { standard: 0, fast: 0, ultrafast: 0, premium: 0 },
  duplicateSources: [],
  contributingEnvironments: [],
  contractMismatches: [],
};

/**
 * Merges every connected environment's summary.
 *
 * `expectedContractVersion` guards against incompatible server code: rather
 * than blocking the page, its data is excluded and the mismatch direction is
 * reported so the UI can identify which side needs updating. Versions in
 * [{@link USAGE_MERGE_COMPATIBLE_SINCE}, expected] still merge, so an additive
 * provider expansion does not drop Claude/Codex totals from older servers.
 *
 * `groupBy` re-keys the groups, the period series and the model rows; every
 * grand total is the same either way.
 */
export function mergeUsage(
  environments: readonly EnvironmentUsage[],
  expectedContractVersion: number,
  groupBy: UsageGroupBy = "harness",
): MergedUsage {
  if (environments.length === 0) return EMPTY_MERGED;

  const current: EnvironmentUsage[] = [];
  const contractMismatches: UsageContractMismatch[] = [];
  for (const environment of environments) {
    if (
      isCompatibleUsageContractVersion(environment.summary.contractVersion, expectedContractVersion)
    ) {
      current.push(environment);
    } else {
      contractMismatches.push({
        environmentId: environment.environmentId,
        direction:
          environment.summary.contractVersion < expectedContractVersion
            ? "serverBehind"
            : "clientBehind",
        contractVersion: environment.summary.contractVersion,
      });
    }
  }

  const {
    ownerByFingerprint,
    supplementalBucketsByEnvironment,
    sessionsByFingerprint,
    duplicates,
  } = claimSources(current);

  let costUsd = 0;
  let uncachedInputTokens = 0;
  let cachedInputTokens = 0;
  let cacheCreationTokens = 0;
  let outputTokens = 0;
  let reasoningTokens = 0;
  let records = 0;
  let sessions = 0;
  let cacheSavingsUsd = 0;
  let providerReportedRecords = 0;
  let unpricedRecords = 0;
  const categoryCost = { input: 0, cacheRead: 0, cacheWrite: 0, output: 0 };
  const speedCost = { fast: 0, ultrafast: 0, premium: 0 };

  const groupAccumulator = new Map<
    UsageGroupKey,
    {
      costUsd: number;
      totalTokens: number;
      records: number;
      sessions: number;
      estimatedCostUsd: number;
    }
  >();
  const familyByModel = new Map<string, ModelFamily>();
  const familyOf = (model: string): ModelFamily => {
    let family = familyByModel.get(model);
    if (family === undefined) {
      family = modelFamily(model);
      familyByModel.set(model, family);
    }
    return family;
  };
  const modelAccumulator = new Map<
    string,
    {
      model: string;
      costByProvider: Map<UsageProviderKind, number>;
      costUsd: number;
      estimatedCostUsd: number;
      totalTokens: number;
      tokens: UsageTokenTotals;
      records: number;
      unpricedRecords: number;
      unpricedTokens: number;
    }
  >();
  const dailyAccumulator = new Map<
    string,
    {
      costUsd: number;
      totalTokens: number;
      byGroup: Map<UsageGroupKey, PeriodGroupTotals>;
    }
  >();
  const hourlyAccumulator = new Map<
    string,
    {
      day: string;
      hourStart: string;
      costUsd: number;
      totalTokens: number;
      byGroup: Map<UsageGroupKey, PeriodGroupTotals>;
    }
  >();
  const addToPeriod = (
    byGroup: Map<UsageGroupKey, PeriodGroupTotals>,
    key: UsageGroupKey,
    costUsd: number,
    totalTokens: number,
    estimatedCostUsd: number,
  ) => {
    const previous = byGroup.get(key);
    byGroup.set(key, {
      costUsd: (previous?.costUsd ?? 0) + costUsd,
      totalTokens: (previous?.totalTokens ?? 0) + totalTokens,
      estimatedCostUsd: (previous?.estimatedCostUsd ?? 0) + estimatedCostUsd,
    });
  };
  const contributingEnvironments: EnvironmentId[] = [];

  for (const environment of current) {
    const { buckets, sessionsByProvider } = ownedContribution(
      environment,
      ownerByFingerprint,
      supplementalBucketsByEnvironment.get(environment.environmentId) ?? new Set(),
      sessionsByFingerprint,
    );
    if (buckets.length > 0) contributingEnvironments.push(environment.environmentId);

    for (const [providerKind, providerSessions] of sessionsByProvider) {
      sessions += providerSessions;
      if (providerSessions === 0 || groupBy !== "harness") continue;
      const provider = groupAccumulator.get(providerKind) ?? {
        costUsd: 0,
        totalTokens: 0,
        records: 0,
        sessions: 0,
        estimatedCostUsd: 0,
      };
      provider.sessions += providerSessions;
      groupAccumulator.set(providerKind, provider);
    }

    for (const bucket of buckets) {
      const tokens = bucketTokens(bucket);
      const family = familyOf(bucket.model);
      const groupKey: UsageGroupKey = groupBy === "family" ? family : bucket.provider;
      const estimatedCostUsd = bucketEstimatedCostUsd(bucket);

      costUsd += bucket.costUsd;
      cacheSavingsUsd += bucket.cacheSavingsUsd;
      uncachedInputTokens += bucket.totals.uncachedInputTokens;
      cachedInputTokens += bucket.totals.cachedInputTokens;
      cacheCreationTokens += bucket.totals.cacheCreationTokens;
      outputTokens += bucket.totals.outputTokens;
      reasoningTokens += bucket.totals.reasoningTokens;
      records += bucket.records;
      unpricedRecords += bucket.unpricedRecords;
      if (bucket.costSource === "providerReported") providerReportedRecords += bucket.records;
      if (bucket.categoryCostUsd !== undefined) {
        categoryCost.input += bucket.categoryCostUsd.input;
        categoryCost.cacheRead += bucket.categoryCostUsd.cacheRead;
        categoryCost.cacheWrite += bucket.categoryCostUsd.cacheWrite;
        categoryCost.output += bucket.categoryCostUsd.output;
      }
      speedCost.fast += bucket.fastCostUsd ?? 0;
      speedCost.ultrafast += bucket.ultrafastCostUsd ?? 0;
      speedCost.premium += bucket.speedPremiumUsd ?? 0;

      const group = groupAccumulator.get(groupKey) ?? {
        costUsd: 0,
        totalTokens: 0,
        records: 0,
        sessions: 0,
        estimatedCostUsd: 0,
      };
      group.costUsd += bucket.costUsd;
      group.totalTokens += tokens;
      group.records += bucket.records;
      group.estimatedCostUsd += estimatedCostUsd;
      groupAccumulator.set(groupKey, group);

      const modelKey = groupBy === "family" ? bucket.model : `${bucket.provider} ${bucket.model}`;
      const model = modelAccumulator.get(modelKey) ?? {
        model: bucket.model,
        costByProvider: new Map<UsageProviderKind, number>(),
        costUsd: 0,
        estimatedCostUsd: 0,
        totalTokens: 0,
        tokens: {
          uncachedInputTokens: 0,
          cachedInputTokens: 0,
          cacheCreationTokens: 0,
          outputTokens: 0,
          reasoningTokens: 0,
        },
        records: 0,
        unpricedRecords: 0,
        unpricedTokens: 0,
      };
      model.costUsd += bucket.costUsd;
      model.estimatedCostUsd += estimatedCostUsd;
      model.costByProvider.set(
        bucket.provider,
        (model.costByProvider.get(bucket.provider) ?? 0) + bucket.costUsd,
      );
      model.totalTokens += tokens;
      model.tokens = {
        uncachedInputTokens: model.tokens.uncachedInputTokens + bucket.totals.uncachedInputTokens,
        cachedInputTokens: model.tokens.cachedInputTokens + bucket.totals.cachedInputTokens,
        cacheCreationTokens: model.tokens.cacheCreationTokens + bucket.totals.cacheCreationTokens,
        outputTokens: model.tokens.outputTokens + bucket.totals.outputTokens,
        reasoningTokens: model.tokens.reasoningTokens + bucket.totals.reasoningTokens,
      };
      model.records += bucket.records;
      model.unpricedRecords += bucket.unpricedRecords;
      if (bucket.records > 0) {
        model.unpricedTokens += (tokens * bucket.unpricedRecords) / bucket.records;
      }
      modelAccumulator.set(modelKey, model);

      const day = dailyAccumulator.get(bucket.day) ?? {
        costUsd: 0,
        totalTokens: 0,
        byGroup: new Map<UsageGroupKey, PeriodGroupTotals>(),
      };
      day.costUsd += bucket.costUsd;
      day.totalTokens += tokens;
      addToPeriod(day.byGroup, groupKey, bucket.costUsd, tokens, estimatedCostUsd);
      dailyAccumulator.set(bucket.day, day);

      if (bucket.hourStart !== undefined) {
        const hour = hourlyAccumulator.get(bucket.hourStart) ?? {
          day: bucket.day,
          hourStart: bucket.hourStart,
          costUsd: 0,
          totalTokens: 0,
          byGroup: new Map<UsageGroupKey, PeriodGroupTotals>(),
        };
        hour.costUsd += bucket.costUsd;
        hour.totalTokens += tokens;
        addToPeriod(hour.byGroup, groupKey, bucket.costUsd, tokens, estimatedCostUsd);
        hourlyAccumulator.set(bucket.hourStart, hour);
      }
    }
  }

  const totalTokens = uncachedInputTokens + cachedInputTokens + cacheCreationTokens + outputTokens;

  const groups: GroupTotals[] = [...groupAccumulator.entries()]
    .map(([key, totals]) => ({
      key,
      costUsd: totals.costUsd,
      totalTokens: totals.totalTokens,
      records: totals.records,
      ...(groupBy === "harness" ? { sessions: totals.sessions } : {}),
      estimatedCostUsd: totals.estimatedCostUsd,
      costShare: costUsd === 0 ? 0 : totals.costUsd / costUsd,
      tokenShare: totalTokens === 0 ? 0 : totals.totalTokens / totalTokens,
    }))
    .sort((a, b) => b.costUsd - a.costUsd);

  const models: ModelTotals[] = [...modelAccumulator.values()]
    .map((totals) => {
      // A stable sort keeps first-seen order between harnesses with equal cost.
      const providers = [...totals.costByProvider.entries()]
        .sort((a, b) => b[1] - a[1])
        .map(([provider]) => provider);
      return {
        model: totals.model,
        provider: providers[0]!,
        providers,
        family: familyOf(totals.model),
        costUsd: totals.costUsd,
        estimatedCostUsd: totals.estimatedCostUsd,
        totalTokens: totals.totalTokens,
        tokens: totals.tokens,
        records: totals.records,
        unpricedRecords: totals.unpricedRecords,
        unpricedTokens: totals.unpricedTokens,
        costShare: costUsd === 0 ? 0 : totals.costUsd / costUsd,
        tokenShare: totalTokens === 0 ? 0 : totals.totalTokens / totalTokens,
      };
    })
    .sort((a, b) => b.costUsd - a.costUsd || b.totalTokens - a.totalTokens);

  const daily: DailyTotals[] = [...dailyAccumulator.entries()]
    .map(([day, totals]) => ({
      day,
      costUsd: totals.costUsd,
      totalTokens: totals.totalTokens,
      byGroup: totals.byGroup,
    }))
    .sort((a, b) => a.day.localeCompare(b.day));

  const hourly: HourlyTotals[] = [...hourlyAccumulator.values()].sort((a, b) =>
    a.hourStart.localeCompare(b.hourStart),
  );

  return {
    costUsd,
    uncachedInputTokens,
    cachedInputTokens,
    cacheCreationTokens,
    outputTokens,
    reasoningTokens,
    totalTokens,
    records,
    sessions,
    groups,
    models,
    daily,
    hourly,
    costQuality: {
      providerReportedShare: records === 0 ? 0 : providerReportedRecords / records,
      unpricedShare: records === 0 ? 0 : unpricedRecords / records,
      modelPricedShare:
        records === 0 ? 0 : (records - providerReportedRecords - unpricedRecords) / records,
      cacheSavingsUsd,
    },
    // Clamped so float error never shows as a negative remainder.
    categoryCost: {
      ...categoryCost,
      unsplit: Math.max(
        0,
        costUsd -
          categoryCost.input -
          categoryCost.cacheRead -
          categoryCost.cacheWrite -
          categoryCost.output,
      ),
    },
    speedCost: {
      ...speedCost,
      standard: Math.max(0, costUsd - speedCost.fast - speedCost.ultrafast),
    },
    duplicateSources: duplicates,
    contributingEnvironments,
    contractMismatches,
  };
}
