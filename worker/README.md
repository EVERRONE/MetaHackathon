# Pip Worker

A small Cloudflare Worker at `https://pip.unveil.be`, between the Pip app and the Meta Model API. It keeps the API key off the phone, turns SAM masks into outlines, and caps spend.

## Routes

Every route except `/v1/health` needs `Authorization: Bearer <PIP_APP_TOKEN>`.

| Route | What it does |
|---|---|
| `GET /v1/health` | Liveness check. |
| `POST /v1/chat` | OpenAI-style chat completion for `muse-spark-1.3`. Streams pass through byte for byte. The Worker forces `store: false` and records usage. |
| `POST /v1/segment` | SAM 3.1. Concept prompts run in parallel; box/point prompts run as one request. Returns merged instances with outlines, numbered in reading order. |
| `POST /v1/transcribe` | Body: a mono 16-bit WAV (16 or 24 kHz). Query: `mode` (`PUSH_TO_TALK` or `ENDPOINTING`), `languages` (e.g. `English,Dutch`), `keywords`. |
| `GET /v1/asr` | WebSocket relay to realtime transcription. The first frame is the handshake without a key (`audioEncoding`, `mode`, `partialMode`, `languageBias`, `keywords`). Then send binary PCM and `{"type":"endStream"}` to finish. |
| `POST /v1/speak` | `{ text, voice, language }` → ElevenLabs Flash v2.5 speech as newline-delimited JSON: base64 PCM (24 kHz, 16-bit mono) plus each character's start time, used to time the cues. ElevenLabs is the only non-Meta model: Meta has no text-to-speech. |
| `GET /v1/usage` | Estimated spend: today and total, in USD. |

### `/v1/segment`

```jsonc
// Request
{
  "image": "data:image/jpeg;base64,…",   // or bare base64
  "prompts": ["breaker", "switch"],      // 1–4 short noun phrases, or:
  "objects": [{ "id": 1, "box": [x1, y1, x2, y2] }, { "id": 2, "points": [{ "x": 10, "y": 20 }] }],
  "width": 1280, "height": 960,          // required with objects
  "minConfidence": 0.3,                  // default 0.3
  "maxInstances": 40                     // default 40
}

// Response
{
  "width": 1280, "height": 960,
  "instances": [{
    "id": 1,                       // mark number, reading order
    "prompts": ["breaker"],        // which prompts found it
    "confidence": 0.71,
    "box": [858, 335, 1010, 645],  // half-open pixels
    "area": 31877,
    "centroid": [933, 489],
    "polygons": [[858, 340, …]],   // outer contours, flat x,y pairs, largest first
    "contains": [4, 5]             // optional: other marks this one mostly covers
  }],
  "calls": [{ "prompt": "breaker", "found": 22, "ms": 1350 }],
  "dropped": 0
}
```

Duplicate instances across prompts (mask IoU > 0.75) are merged. `contains` flags a mask that covers other instances, which is a sign that SAM merged neighbouring objects.

## Safeguards

- App token, checked in constant time.
- A rate limit of 300 requests per minute.
- Daily and total spend caps (`DAILY_CAP_USD`, `TOTAL_CAP_USD`). Spend is estimated from token usage, images and audio seconds, and stored in a Durable Object.
- Logs hold metadata only (route, status, time), never images, audio or text.
- Requests to Meta set `store: false` and use Standard mode, so content is not used for training.

## Develop

```sh
npm install
npm test            # unit tests (geometry, costs, WAV parsing, stream tap)
npm run typecheck
```

The secrets `MODEL_API_KEY`, `PIP_APP_TOKEN` and `ELEVENLABS_API_KEY` live in the repo-root `.dev.vars`, which is gitignored. `worker/.dev.vars` is a symlink to it.

Deploy with `npx wrangler deploy`. The first deploy also passes `--secrets-file ../.dev.vars`. The account needs the Workers Paid plan, because decoding SAM masks takes more than the free plan's 10 ms of CPU time.
