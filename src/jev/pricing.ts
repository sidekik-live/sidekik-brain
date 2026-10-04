import { PRICE_TABLE, type DecisionProvider } from "@sidekik/contracts";
import type { JevUsage } from "./types.js";

const JEV = PRICE_TABLE.typesafe["jev-1.13.0"];
const HAIKU = PRICE_TABLE.anthropic["claude-haiku-4-5"];

/** USD per token, from the dated PRICE_TABLE in @sidekik/contracts. */
export const PRICES = {
  jev: { in: JEV.tokens_in, out: JEV.tokens_out },
  haiku: { in: HAIKU.tokens_in, out: HAIKU.tokens_out },
} as const;

/** Output tokens Haiku spends per question for `{answer, probability}` (used for the counterfactual). */
export const HAIKU_OUTPUT_TOKENS_PER_QUESTION = 20;

export function costUsd(provider: DecisionProvider, usage: JevUsage): number {
  if (usage.cost_usd !== undefined) return usage.cost_usd;
  const p = provider === "llm" ? PRICES.haiku : PRICES.jev;
  return usage.input_tokens * p.in + usage.output_tokens * p.out;
}

/** The same decision priced on Haiku 4.5: the input tokens plus a short JSON answer per question. */
export function counterfactualUsd(provider: DecisionProvider, usage: JevUsage, questionCount: number): number {
  if (provider === "llm") return costUsd(provider, usage);
  return usage.input_tokens * PRICES.haiku.in + questionCount * HAIKU_OUTPUT_TOKENS_PER_QUESTION * PRICES.haiku.out;
}
