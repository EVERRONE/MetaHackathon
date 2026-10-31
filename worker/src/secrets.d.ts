// Secrets come from `wrangler secret put` (and .dev.vars locally), so `wrangler types` cannot see them.
interface Env {
  MODEL_API_KEY: string;
  PIP_APP_TOKEN: string;
  ELEVENLABS_API_KEY: string;
}
