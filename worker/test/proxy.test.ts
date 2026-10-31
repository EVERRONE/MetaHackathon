import { describe, expect, it } from "vitest";
import { wavDurationSeconds } from "../src/asr";
import { usageTap } from "../src/chat";
import { asrCost, samCost, sparkCost, sparkFallbackCost } from "../src/cost";

function wav(seconds: number, rate = 16_000): ArrayBuffer {
  const dataBytes = seconds * rate * 2;
  const buf = new ArrayBuffer(44 + dataBytes);
  const v = new DataView(buf);
  const put = (o: number, s: string) => [...s].forEach((ch, i) => v.setUint8(o + i, ch.charCodeAt(0)));
  put(0, "RIFF");
  v.setUint32(4, 36 + dataBytes, true);
  put(8, "WAVE");
  put(12, "fmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);
  v.setUint16(22, 1, true);
  v.setUint32(24, rate, true);
  v.setUint32(28, rate * 2, true);
  v.setUint16(32, 2, true);
  v.setUint16(34, 16, true);
  put(36, "data");
  v.setUint32(40, dataBytes, true);
  return buf;
}

describe("wavDurationSeconds", () => {
  it("reads the duration from the header", () => {
    expect(wavDurationSeconds(wav(3))).toBe(3);
    expect(wavDurationSeconds(wav(2, 24_000))).toBe(2);
  });

  it("ignores a forged byte rate and rejects unsupported formats", () => {
    const forged = wav(3);
    new DataView(forged).setUint32(28, 0xffffffff, true);
    expect(wavDurationSeconds(forged)).toBe(3);
    const stereo = wav(1);
    new DataView(stereo).setUint16(22, 2, true);
    expect(wavDurationSeconds(stereo)).toBeNull();
    expect(wavDurationSeconds(wav(1, 44_100))).toBeNull();
  });

  it("rejects non-WAV data", () => {
    expect(wavDurationSeconds(new TextEncoder().encode("x".repeat(64)).buffer as ArrayBuffer)).toBeNull();
  });
});

describe("costs", () => {
  it("prices cached input lower than uncached input", () => {
    const cold = sparkCost({ prompt_tokens: 10_000, completion_tokens: 100 });
    const warm = sparkCost({ prompt_tokens: 10_000, completion_tokens: 100, prompt_tokens_details: { cached_tokens: 9_000 } });
    expect(cold).toBeCloseTo(10_000 * 1.25e-6 + 100 * 4.25e-6);
    expect(warm).toBeLessThan(cold);
  });

  it("prices a cut-short stream per image, not per base64 byte", () => {
    // One 300 KB JPEG and 4 KB of text, cancelled after 30 KB of SSE.
    expect(sparkFallbackCost(4_000, 30_000, 1)).toBeLessThan(0.005);
  });

  it("prices SAM per image and ASR per whole second", () => {
    expect(samCost(4)).toBeCloseTo(0.01);
    expect(asrCost(3600.9)).toBeCloseTo(0.18);
  });
});

describe("usageTap", () => {
  it("passes bytes through unchanged and reports the usage chunk", async () => {
    const lines = [
      'data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n',
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":15,"completion_tokens":7}}\n\n',
      "data: [DONE]\n\n",
    ];
    const text = lines.join("");
    const bytes = new TextEncoder().encode(text);
    // Split mid-line to make sure lines are reassembled across chunks.
    const source = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(bytes.slice(0, 70));
        c.enqueue(bytes.slice(70));
        c.close();
      },
    });
    let reported: unknown = null;
    const out = await new Response(source.pipeThrough(usageTap((u) => (reported = u)))).text();
    expect(out).toBe(text);
    expect(reported).toEqual({ prompt_tokens: 15, completion_tokens: 7 });
  });
});
