import { describe, expect, it } from "vitest";
import { publicHttps, validate } from "../src/responses";
import { sparkFallbackCost } from "../src/cost";

const msg = (parts: unknown[]) => [{ role: "user", content: parts }];

describe("responses validation", () => {
  it("accepts what the app sends", () => {
    expect(validate({ model: "muse-spark-1.3", input: "find the manual", tools: [{ type: "web_search" }], reasoning: { effort: "low" } })).toEqual({ images: 0, files: 0, searches: true });
    const parts = [
      { type: "input_text", text: "steps" },
      { type: "input_file", file_url: "https://www.ikea.com/manual.pdf" },
      { type: "input_image", image_url: "data:image/jpeg;base64,AAAA" },
    ];
    expect(validate({ model: "muse-wonder-1.0", input: msg(parts), text: { format: {} } })).toEqual({ images: 1, files: 1, searches: false });
  });

  it("rejects unknown fields, other tools, linked images, stored files and non-boolean stream", () => {
    const bad: Record<string, unknown>[] = [
      { model: "muse-spark-1.3", input: "x", background: true },
      { model: "muse-spark-1.3", input: "x", previous_response_id: "r1" },
      { model: "muse-spark-1.3", input: "x", tools: [{ type: "code_interpreter" }] },
      { model: "muse-spark-1.3", input: "x", stream: 1 },
      { model: "muse-spark-1.3", input: "x", reasoning: { effort: "high" } },
      { model: "muse-spark-1.3", input: msg([{ type: "input_image", image_url: "http://10.0.0.1/x.jpg" }]) },
      { model: "muse-spark-1.3", input: msg([{ type: "input_file", file_id: "file_123" }]) },
      { model: "muse-spark-1.3", input: msg([{ type: "input_file", file_url: "http://example.com/a.pdf" }]) },
      { model: "gpt-x", input: "x" },
    ];
    for (const body of bad) expect(() => validate(body), JSON.stringify(body)).toThrow();
  });

  it("clamps the output length", () => {
    const body: Record<string, unknown> = { model: "muse-spark-1.3", input: "x", max_output_tokens: 1e9 };
    validate(body);
    expect(body.max_output_tokens).toBe(16_000);
  });
});

describe("source check hosts", () => {
  const ok = (u: string) => publicHttps(new URL(u));
  it("allows public https sites", () => {
    expect(ok("https://www.ikea.com/be/nl/assembly_instructions/pax.pdf")).toBe(true);
    expect(ok("https://support.hp.com/doc.pdf")).toBe(true);
  });
  it("blocks addresses, local names, credentials, ports and this zone", () => {
    for (const u of [
      "http://www.ikea.com/a.pdf",
      "https://127.0.0.1/",
      "https://2130706433/",
      "https://0x7f000001/",
      "https://[::1]/",
      "https://[::ffff:127.0.0.1]/",
      "https://a.b@[fd00::1]/",
      "https://a.b@localhost./",
      "https://foo.local./",
      "https://127.0.0.1.nip.io/",
      "https://metadata.google.internal/",
      "https://ikea.com:8443/",
      "https://user:pw@ikea.com/",
      "https://pip.unveil.be/v1/usage",
      "https://10.0.0.1.example.com/",
    ]) expect(ok(u), u).toBe(false);
  });
});

describe("costs by model", () => {
  it("prices a cut-short Wonder stream at Wonder rates", () => {
    expect(sparkFallbackCost(4_000, 30_000, 1, "muse-wonder-1.0")).toBeGreaterThan(3 * sparkFallbackCost(4_000, 30_000, 1));
  });
});
