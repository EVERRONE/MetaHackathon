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

// Muse Wonder, Meta's most capable model: about four times Spark's price.
const WONDER_INPUT = 4.0 / 1e6;
const WONDER_CACHED_INPUT = 0.2 / 1e6;
const WONDER_OUTPUT = 20.0 / 1e6;

const isWonder = (model: string) => model.startsWith("muse-wonder");

/** USD per uncached input token. */
export function inputRate(model: string): number {
  return isWonder(model) ? WONDER_INPUT : SPARK_INPUT;
}

export function sparkCost(usage: ChatUsage, model = "muse-spark-1.3"): number {
  const prompt = usage.prompt_tokens ?? 0;
  const cached = Math.min(usage.prompt_tokens_details?.cached_tokens ?? 0, prompt);
  const output = usage.completion_tokens ?? 0;
  if (isWonder(model)) {
    return (prompt - cached) * WONDER_INPUT + cached * WONDER_CACHED_INPUT + output * WONDER_OUTPUT;
  }
  return (prompt - cached) * SPARK_INPUT + cached * SPARK_CACHED_INPUT + output * SPARK_OUTPUT;
}

export function samCost(images: number): number {
  return images * SAM_PER_IMAGE;
}

export function asrCost(seconds: number): number {
  // Billed per whole second.
  return Math.floor(seconds) * ASR_PER_SECOND;
}

/** Rough tokens for one inline image, used only when a response carries no usage. */
const TOKENS_PER_IMAGE = 1_600;
/** SSE framing: each streamed chunk carries ~150 bytes of JSON for about one token. */
const SSE_BYTES_PER_TOKEN = 150;

/**
 * Estimate used when a response carries no usage (a stream cut short by barge-in).
 * `textBytes` excludes inline images, which are counted per image instead.
 */
export function sparkFallbackCost(textBytes: number, responseBytes: number, images: number, model = "muse-spark-1.3"): number {
  const input = textBytes / 4 + images * TOKENS_PER_IMAGE;
  const output = Math.min(responseBytes / SSE_BYTES_PER_TOKEN, 4_000);
  return input * inputRate(model) + output * (isWonder(model) ? WONDER_OUTPUT : SPARK_OUTPUT);
}
