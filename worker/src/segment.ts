import {
  buildObjectPrompt,
  decodeMaskToRaster,
  decodeMaskToSVGPath,
  formats,
  recordsOfKind,
  type PromptObject,
  type SegmentationMaskRecord,
} from "@meta-sam/parser";
import {
  boxIntersection,
  boxIoU,
  maskArea,
  maskCentroid,
  maskIntersection,
  outerRings,
  parseSvgPath,
  readingOrder,
  simplifyToBudget,
  type Box,
  type BoxMask,
  type Point,
} from "./geometry";
import { META_API, UpstreamError } from "./upstream";

export interface ObjectPromptInput {
  id: number;
  box?: Box;
  points?: { x: number; y: number; negative?: boolean }[];
}

export interface SegmentRequest {
  /** JPEG/PNG as a data URL or bare base64. */
  image: string;
  /** Concept noun phrases; each one is a separate SAM request run in parallel. */
  prompts?: string[];
  /** Box/point prompts on known locations; one SAM request. Needs width and height. */
  objects?: ObjectPromptInput[];
  width?: number;
  height?: number;
  minConfidence?: number;
  maxInstances?: number;
}

export interface Instance {
  /** Mark number, 1-based, in reading order. */
  id: number;
  /** The concept prompts that found this instance, or "object:<id>" for box/point prompts. */
  prompts: string[];
  objectId?: number;
  confidence: number;
  box: Box;
  area: number;
  centroid: Point;
  /** Outer contours as flat [x0, y0, x1, y1, …] in image pixels, largest first. */
  polygons: number[][];
  /** Marks of other instances this one mostly covers: a hint that SAM merged neighbours. */
  contains?: number[];
}

export interface SegmentResult {
  width: number | null;
  height: number | null;
  instances: Instance[];
  calls: { prompt: string; found: number; ms: number }[];
  dropped: number;
}

export const MAX_PROMPTS = 4;
const DUPLICATE_IOU = 0.75;
const CONTAINS_FRACTION = 0.85;
const MIN_AREA_PX = 16;
const POLYGON_EPSILON = 1.0;
const POLYGON_MAX_POINTS = 96;

interface Candidate {
  record: SegmentationMaskRecord;
  mask: BoxMask;
  confidence: number;
  prompts: string[];
  objectId?: number;
}

export function toDataUrl(image: string): string {
  return image.startsWith("data:") ? image : `data:image/jpeg;base64,${image}`;
}

export async function callSam(apiKey: string, imageUrl: string, text: string): Promise<string> {
  const res = await fetch(`${META_API}/responses`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "sam-3.1",
      store: false,
      metadata: { include_confidence: "true", mask_encoding: "one_bit" },
      input: [
        {
          type: "message",
          role: "user",
          content: [
            { type: "input_text", text },
            { type: "input_image", image_url: imageUrl },
          ],
        },
      ],
    }),
  });
  if (!res.ok) throw await UpstreamError.from(res, "sam");
  const json = (await res.json()) as {
    output?: { content?: { type?: string; text?: string }[] }[];
  };
  let out = "";
  for (const item of json.output ?? []) {
    for (const part of item.content ?? []) if (part.type === "output_text") out += part.text ?? "";
  }
  return out;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(Math.max(v, lo), hi);
}

/** Whole pixels inside the image, with right/bottom half-open and at least one pixel wide. */
function clampBox(b: Box, width: number, height: number) {
  const left = clamp(Math.floor(b[0]), 0, width - 1);
  const top = clamp(Math.floor(b[1]), 0, height - 1);
  const right = clamp(Math.ceil(b[2]), left + 1, width);
  const bottom = clamp(Math.ceil(b[3]), top + 1, height);
  return { left, top, right, bottom };
}

export function buildObjectText(objects: ObjectPromptInput[], width: number, height: number): string {
  const prompt: PromptObject[] = objects.map((o) => ({
    id: o.id,
    prompts: [
      {
        box: o.box ? clampBox(o.box, width, height) : undefined,
        points: o.points?.map((p) => ({
          x: clamp(Math.floor(p.x), 0, width - 1),
          y: clamp(Math.floor(p.y), 0, height - 1),
          label: p.negative ? ("negative" as const) : ("positive" as const),
        })),
      },
    ],
  }));
  return buildObjectPrompt({ size: { width, height }, objects: prompt });
}

/** Parses one SAM output text into candidates above the confidence threshold. */
export function candidatesFrom(text: string, label: string | null, minConfidence: number): Candidate[] {
  if (!text) return [];
  const parser = formats.segmentation.image().createParser();
  parser.push(text);
  const { result } = parser.finish({ status: "completed" });
  const out: Candidate[] = [];
  for (const record of recordsOfKind(result.records, "mask")) {
    const confidence = record.confidence ?? 0;
    if (confidence < minConfidence) continue;
    const data = decodeMaskToRaster(record.mask);
    const area = maskArea(data);
    if (area < MIN_AREA_PX) continue;
    const b = record.bounds;
    out.push({
      record,
      confidence,
      mask: { box: [b.left, b.top, b.right, b.bottom], width: record.mask.width, height: record.mask.height, data, area },
      prompts: [label ?? `object:${record.objectId}`],
      objectId: label === null ? Number(record.objectId) : undefined,
    });
  }
  return out;
}

export function frameSize(text: string): { width: number; height: number } | null {
  const w = /;w=(\d+)/.exec(text);
  const h = /;h=(\d+)/.exec(text);
  return w && h ? { width: Number(w[1]), height: Number(h[1]) } : null;
}

function iou(a: BoxMask, b: BoxMask, inter: number): number {
  return inter / (a.area + b.area - inter);
}

/** Merges duplicates across prompt variants, then outlines, orders and numbers the instances. */
export function buildInstances(all: Candidate[], maxInstances: number): { instances: Instance[]; dropped: number } {
  const sorted = all.slice().sort((a, b) => b.confidence - a.confidence);
  const kept: Candidate[] = [];
  for (const c of sorted) {
    // Box/point prompts keep the caller's ids, so only concept results are merged.
    const dup =
      c.objectId === undefined
        ? kept.find(
            (k) =>
              k.objectId === undefined &&
              // Mask IoU > 0.75 needs the boxes to overlap by at least 0.75 of the larger mask.
              boxIntersection(k.mask.box, c.mask.box) >= DUPLICATE_IOU * Math.max(k.mask.area, c.mask.area) &&
              iou(k.mask, c.mask, maskIntersection(k.mask, c.mask)) > DUPLICATE_IOU,
          )
        : undefined;
    if (dup) {
      for (const p of c.prompts) if (!dup.prompts.includes(p)) dup.prompts.push(p);
    } else {
      kept.push(c);
    }
  }
  const limited = kept.slice(0, maxInstances);
  const dropped = kept.length - limited.length;

  const withCentre = limited.map((c) => ({ c, centre: maskCentroid(c.mask) }));
  const ordered = readingOrder(withCentre, (x) => x.centre, (x) => x.c.mask.box[3] - x.c.mask.box[1]);

  const instances: Instance[] = ordered.map(({ c, centre }, i) => {
    const [left, top] = c.mask.box;
    const rings = outerRings(parseSvgPath(decodeMaskToSVGPath(c.record.mask)));
    const polygons = rings.map((r) =>
      // The parser puts pixel centres on integers; outlines run along pixel edges (+0.5).
      simplifyToBudget(r, POLYGON_EPSILON, POLYGON_MAX_POINTS).flatMap(([x, y]) => [
        Math.round(x + left + 0.5),
        Math.round(y + top + 0.5),
      ]),
    );
    return {
      id: i + 1,
      prompts: c.prompts,
      ...(c.objectId !== undefined ? { objectId: c.objectId } : {}),
      confidence: Math.round(c.confidence * 1000) / 1000,
      box: c.mask.box,
      area: c.mask.area,
      centroid: [Math.round(centre[0]), Math.round(centre[1])],
      polygons,
    };
  });

  for (let i = 0; i < ordered.length; i++) {
    const a = ordered[i].c.mask;
    const contains: number[] = [];
    for (let j = 0; j < ordered.length; j++) {
      const b = ordered[j].c.mask;
      if (i === j || a.area < 1.6 * b.area || boxIoU(a.box, b.box) === 0) continue;
      if (maskIntersection(a, b) / b.area >= CONTAINS_FRACTION) contains.push(j + 1);
    }
    if (contains.length) instances[i].contains = contains;
  }
  return { instances, dropped };
}

export async function segment(apiKey: string, req: SegmentRequest, charge: (calls: number) => void): Promise<SegmentResult> {
  const imageUrl = toDataUrl(req.image);
  const minConfidence = Number.isFinite(req.minConfidence) ? clamp(req.minConfidence!, 0, 1) : 0.3;
  const maxInstances = Number.isFinite(req.maxInstances) ? clamp(Math.floor(req.maxInstances!), 1, 200) : 40;

  const jobs: { label: string | null; text: string }[] = [];
  for (const p of new Set((req.prompts ?? []).map((p) => p.trim()))) jobs.push({ label: p, text: p });
  if (req.objects?.length) {
    jobs.push({ label: null, text: buildObjectText(req.objects, Math.floor(req.width!), Math.floor(req.height!)) });
  }

  // One failed prompt does not sink the others; each call that ran is charged.
  const settled = await Promise.allSettled(
    jobs.map(async (job) => {
      const t0 = Date.now();
      const text = await callSam(apiKey, imageUrl, job.text);
      return { job, text, ms: Date.now() - t0 };
    }),
  );
  charge(settled.filter((r) => r.status === "fulfilled" || !(r.reason instanceof UpstreamError && r.reason.status === 400)).length);
  const outputs = settled.flatMap((r) => (r.status === "fulfilled" ? [r.value] : []));
  if (outputs.length === 0) {
    const first = settled[0];
    throw first?.status === "rejected" ? first.reason : new Error("no segmentation calls");
  }

  const candidates: Candidate[] = [];
  const calls: SegmentResult["calls"] = [];
  let size: { width: number; height: number } | null = null;
  for (const { job, text, ms } of outputs) {
    const found = candidatesFrom(text, job.label, minConfidence);
    candidates.push(...found);
    calls.push({ prompt: job.label ?? "objects", found: found.length, ms });
    size ??= frameSize(text);
  }
  settled.forEach((r, i) => {
    if (r.status === "rejected") calls.push({ prompt: jobs[i].label ?? "objects", found: -1, ms: 0 });
  });
  const { instances, dropped } = buildInstances(candidates, maxInstances);
  return {
    width: size?.width ?? req.width ?? null,
    height: size?.height ?? req.height ?? null,
    instances,
    calls,
    dropped,
  };
}
