// Standard-mode prices (dev.meta.ai/docs/pricing-rate-limits, 30 Oct 2026).
const SPARK_INPUT = 1.25 / 1e6;
const SPARK_CACHED_INPUT = 0.15 / 1e6;
const SPARK_OUTPUT = 4.25 / 1e6;
const SAM_PER_IMAGE = 2.5 / 1000;
const ASR_PER_SECOND = 0.18 / 3600;

export interface ChatUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  prompt_tokens_details?: { cached_tokens?: number } | null;
}

export function sparkCost(usage: ChatUsage): number {
  const prompt = usage.prompt_tokens ?? 0;
  const cached = Math.min(usage.prompt_tokens_details?.cached_tokens ?? 0, prompt);
  const output = usage.completion_tokens ?? 0;
  return (prompt - cached) * SPARK_INPUT + cached * SPARK_CACHED_INPUT + output * SPARK_OUTPUT;
}

export function samCost(images: number): number {
  return images * SAM_PER_IMAGE;
}

export function asrCost(seconds: number): number {
  // Billed per whole second.
  return Math.floor(seconds) * ASR_PER_SECOND;
}

/** Upper-bound estimate used when a response carries no usage (e.g. a stream cut short). */
export function sparkFallbackCost(requestBytes: number, responseBytes: number): number {
  return (requestBytes / 3) * SPARK_INPUT + (responseBytes / 3) * SPARK_OUTPUT;
}
