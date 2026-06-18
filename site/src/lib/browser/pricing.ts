// Browser Use cost knobs in one place, so the credit charge and the hard spend
// cap can't drift apart in separate files.
//
// `perStepUsd` is what we charge per agent step (the 1.3x margin is applied in
// provider-pricing.ts via usdWithMargin). `defaultMaxCostUsd` is the per-run USD
// budget sent to Browser Use, which stops a run if reached. Keep them consistent:
// a run that hits the cap is roughly defaultMaxCostUsd / perStepUsd steps.
export const browserUsePerStepUsd = "0.02";
export const browserUseDefaultMaxCostUsd = 0.5;
