import { describe, expect, it } from "vitest";
import { MAX_COMPLETION_TOKENS, validateChat } from "../src/chat";
import { outerRings, type Ring } from "../src/geometry";
import { publicHttps, validate } from "../src/responses";

const jpeg = "data:image/jpeg;base64,/9j/4AAQ";

function chatBody(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    model: "muse-wonder-1.0",
    stream: true,
    reasoning_effort: "minimal",
    prompt_cache_key: "pip-look-v15",
    messages: [
      { role: "system", content: "You are Pip." },
      { role: "user", content: [{ type: "text", text: "Where is the alt key?" }, { type: "image_url", image_url: { url: jpeg } }] },
    ],
    ...extra,
  };
}

describe("chat requests", () => {
  it("lets what the app sends through, with a bounded output always set", () => {
    const body = chatBody();
    expect(validateChat(body)).toEqual({ images: 1, maxOutput: 4_000 });
    expect(body.max_completion_tokens).toBe(4_000);
    const big = chatBody({ max_completion_tokens: 100_000 });
    expect(validateChat(big).maxOutput).toBe(MAX_COMPLETION_TOKENS);
    expect(big.max_completion_tokens).toBe(MAX_COMPLETION_TOKENS);
  });

  it("refuses fields, efforts and parts that could run up the cost", () => {
    expect(() => validateChat(chatBody({ n: 16 }))).toThrow(/Unsupported fields: n/);
    expect(() => validateChat(chatBody({ tools: [{ type: "function" }] }))).toThrow(/Unsupported/);
    expect(() => validateChat(chatBody({ reasoning_effort: "max" }))).toThrow(/reasoning_effort/);
    expect(() => validateChat(chatBody({ model: "some-other-model" }))).toThrow(/Allowed models/);
    const linked = chatBody();
    (linked.messages as { content: unknown }[])[1].content = [{ type: "image_url", image_url: { url: "https://example.com/a.jpg" } }];
    expect(() => validateChat(linked)).toThrow(/inline data:image/);
    const stored = chatBody();
    (stored.messages as { content: unknown }[])[1].content = [{ type: "file", file: { file_id: "file-123" } }];
    expect(() => validateChat(stored)).toThrow(/inline data:image/);
  });

  it("caps the number of images (the memory search sends up to 12 sheets)", () => {
    const sheets = Array.from({ length: 12 }, () => ({ type: "image_url", image_url: { url: jpeg } }));
    const ok = chatBody({ messages: [{ role: "user", content: sheets }] });
    expect(validateChat(ok).images).toBe(12);
    const tooMany = chatBody({ messages: [{ role: "user", content: [...sheets, ...sheets] }] });
    expect(() => validateChat(tooMany)).toThrow(/At most 16 images/);
  });
});

describe("responses requests", () => {
  it("always bound the output, also when the client sends no limit", () => {
    const body: Record<string, unknown> = { model: "muse-spark-1.3", input: "Find the manual", tools: [{ type: "web_search" }] };
    validate(body);
    expect(body.max_output_tokens).toBe(16_000);
  });

  it("let Meta fetch only public https files", () => {
    const file = (url: string) => ({ model: "muse-wonder-1.0", input: [{ role: "user", content: [{ type: "input_file", file_url: url }] }] });
    expect(() => validate(file("https://www.download.p4c.philips.com/manual.pdf"))).not.toThrow();
    expect(() => validate(file("https://10.0.0.1/secret.pdf"))).toThrow(/public https/);
    expect(() => validate(file("https://localtest.me/x.pdf"))).toThrow(/public https/);
  });
});

describe("source check hosts", () => {
  it("refuse zones that resolve to this machine, also written with trailing dots", () => {
    for (const host of ["localtest.me", "lvh.me", "app.lvh.me", "unveil.be..", "printer.local..", "pip.unveil.be."]) {
      expect(publicHttps(new URL(`https://${host}/x`))).toBe(false);
    }
    expect(publicHttps(new URL("https://www.philips.com/support"))).toBe(true);
  });
});

describe("outer rings", () => {
  it("stay few and fast for a mask of thousands of specks", () => {
    const specks: Ring[] = [];
    for (let i = 0; i < 40_000; i++) {
      const x = (i % 200) * 4, y = Math.floor(i / 200) * 4;
      specks.push([[x, y], [x + 2, y], [x + 2, y + 2], [x, y + 2]]);
    }
    const t0 = Date.now();
    const rings = outerRings(specks);
    expect(rings.length).toBeLessThanOrEqual(8);
    expect(Date.now() - t0).toBeLessThan(2_000);
  });
});
