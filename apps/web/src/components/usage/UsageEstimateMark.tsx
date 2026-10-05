import { estimatedCostShare } from "@t3tools/shared/usageMerge";

import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";

/** Copy for the footnote that explains {@link EstimateMark}. */
export const ESTIMATE_FOOTNOTE = "≈ API estimate from model rates";

/**
 * Prefixes a cost when at least 1% of it was priced from model rates rather
 * than reported by the provider. Only grouping by model family shows it: a
 * family mixes harnesses whose costs come from different sources. The tooltip
 * states the estimated share.
 */
export function EstimateMark({
  costUsd,
  estimatedCostUsd,
}: {
  readonly costUsd: number;
  readonly estimatedCostUsd: number;
}) {
  const share = estimatedCostShare(costUsd, estimatedCostUsd);
  if (share === null) return null;
  const label = `${formatEstimateShare(share)} estimated from model rates`;
  return (
    <Tooltip>
      <TooltipTrigger
        render={<span tabIndex={0} className="cursor-default text-muted-foreground outline-none" />}
      >
        <span aria-hidden>≈</span>
        <span className="sr-only">{`${label} `}</span>
      </TooltipTrigger>
      <TooltipPopup side="top">{label}</TooltipPopup>
    </Tooltip>
  );
}

function formatEstimateShare(share: number): string {
  if (share >= 0.995) return "100%";
  return `${Math.round(share * 100)}%`;
}
