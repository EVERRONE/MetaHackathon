import { describe, expect, it } from "vitest";
import {
  boxIoU,
  maskCentroid,
  maskIntersection,
  outerRings,
  parseSvgPath,
  readingOrder,
  ringArea,
  simplifyRing,
  simplifyToBudget,
  type BoxMask,
  type Ring,
} from "../src/geometry";

function square(x: number, y: number, size: number, step = 1): Ring {
  const r: Ring = [];
  for (let i = 0; i < size; i += step) r.push([x + i, y]);
  for (let i = 0; i < size; i += step) r.push([x + size, y + i]);
  for (let i = 0; i < size; i += step) r.push([x + size - i, y + size]);
  for (let i = 0; i < size; i += step) r.push([x, y + size - i]);
  return r;
}

function boxMask(left: number, top: number, w: number, h: number, fill: (x: number, y: number) => boolean): BoxMask {
  const data = new Uint8Array(w * h);
  let area = 0;
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++)
      if (fill(x, y)) {
        data[y * w + x] = 1;
        area++;
      }
  return { box: [left, top, left + w, top + h], width: w, height: h, data, area };
}

describe("parseSvgPath", () => {
  it("reads subpaths with negative and fractional coordinates", () => {
    const rings = parseSvgPath("M58.5 0L59 -0.5L60 -0.5L60.5 0ZM1 1L4 1L4 4L1 4Z");
    expect(rings).toHaveLength(2);
    expect(rings[0][1]).toEqual([59, -0.5]);
    expect(rings[1]).toEqual([[1, 1], [4, 1], [4, 4], [1, 4]]);
  });

  it("returns nothing for an empty mask", () => {
    expect(parseSvgPath("")).toEqual([]);
  });
});

describe("outerRings", () => {
  it("drops holes and small specks, keeps large separate parts", () => {
    const outer = square(0, 0, 100);
    const hole = square(40, 40, 20);
    const speck = square(200, 200, 3);
    const part = square(150, 0, 60);
    const result = outerRings([hole, speck, outer, part]);
    expect(result).toEqual([outer, part]);
  });
});

describe("simplifyRing", () => {
  it("reduces a densely sampled square to its corners", () => {
    const dense = square(10, 10, 50);
    const simple = simplifyRing(dense, 0.5);
    expect(simple.length).toBeLessThanOrEqual(5);
    expect(Math.abs(ringArea(simple))).toBeCloseTo(2500, -1);
  });

  it("respects a point budget", () => {
    const circle: Ring = Array.from({ length: 720 }, (_, i) => [
      100 + 80 * Math.cos((i * Math.PI) / 360),
      100 + 80 * Math.sin((i * Math.PI) / 360),
    ]);
    const out = simplifyToBudget(circle, 0.25, 32);
    expect(out.length).toBeLessThanOrEqual(32);
    expect(Math.abs(ringArea(out)) / (Math.PI * 80 * 80)).toBeGreaterThan(0.95);
  });
});

describe("masks", () => {
  it("intersects masks in frame coordinates", () => {
    const a = boxMask(0, 0, 10, 10, () => true);
    const b = boxMask(5, 5, 10, 10, () => true);
    expect(maskIntersection(a, b)).toBe(25);
    expect(maskIntersection(b, a)).toBe(25);
    expect(boxIoU(a.box, b.box)).toBeCloseTo(25 / 175);
  });

  it("finds the centroid of the set pixels, not the box", () => {
    const m = boxMask(100, 50, 20, 10, (x) => x < 10);
    expect(maskCentroid(m)).toEqual([105, 55]);
  });
});

describe("readingOrder", () => {
  it("orders rows top to bottom and items left to right", () => {
    const items = [
      { n: "b2", c: [300, 210] },
      { n: "a1", c: [100, 98] },
      { n: "b1", c: [100, 200] },
      { n: "a2", c: [300, 104] },
    ] as { n: string; c: [number, number] }[];
    const ordered = readingOrder(items, (i) => i.c, () => 40).map((i) => i.n);
    expect(ordered).toEqual(["a1", "a2", "b1", "b2"]);
  });
});
