// Pure geometry helpers for turning SAM masks into compact outlines. No Workers APIs here.

export type Point = [number, number];
export type Ring = Point[];
/** Half-open pixel box: [left, top, right, bottom]. */
export type Box = [number, number, number, number];

/** Parses the `M x y L x y … Z` paths produced by decodeMaskToSVGPath into closed rings. */
export function parseSvgPath(d: string): Ring[] {
  const rings: Ring[] = [];
  let current: Ring | null = null;
  const re = /([MLZ])\s*(-?[\d.]+)?[\s,]*(-?[\d.]+)?/g;
  for (const m of d.matchAll(re)) {
    const cmd = m[1];
    if (cmd === "Z") {
      if (current && current.length >= 3) rings.push(current);
      current = null;
      continue;
    }
    const x = Number(m[2]);
    const y = Number(m[3]);
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
    if (cmd === "M") {
      if (current && current.length >= 3) rings.push(current);
      current = [[x, y]];
    } else {
      (current ??= []).push([x, y]);
    }
  }
  if (current && current.length >= 3) rings.push(current);
  return rings;
}

/** Signed shoelace area. */
export function ringArea(ring: Ring): number {
  let a = 0;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    a += (ring[j][0] + ring[i][0]) * (ring[j][1] - ring[i][1]);
  }
  return a / 2;
}

export function pointInRing([x, y]: Point, ring: Ring): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

/** Outer contours, largest first. Holes and rings below `minFraction` of the largest are dropped. */
export function outerRings(rings: Ring[], minFraction = 0.1): Ring[] {
  const sorted = rings
    .map((r) => ({ r, area: Math.abs(ringArea(r)) }))
    .sort((a, b) => b.area - a.area);
  if (sorted.length === 0) return [];
  const min = sorted[0].area * minFraction;
  const outer: Ring[] = [];
  for (const { r, area } of sorted) {
    if (area < min) break;
    if (outer.some((o) => pointInRing(r[0], o))) continue; // a hole (or something inside one)
    outer.push(r);
  }
  return outer;
}

function perpendicularDistance(p: Point, a: Point, b: Point): number {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len = Math.hypot(dx, dy);
  if (len === 0) return Math.hypot(p[0] - a[0], p[1] - a[1]);
  return Math.abs(dy * p[0] - dx * p[1] + b[0] * a[1] - b[1] * a[0]) / len;
}

function rdp(points: Point[], epsilon: number): Point[] {
  if (points.length < 3) return points.slice();
  const keep = new Uint8Array(points.length);
  keep[0] = keep[points.length - 1] = 1;
  const stack: [number, number][] = [[0, points.length - 1]];
  while (stack.length) {
    const [s, e] = stack.pop()!;
    let maxD = 0;
    let idx = -1;
    for (let i = s + 1; i < e; i++) {
      const d = perpendicularDistance(points[i], points[s], points[e]);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx !== -1 && maxD > epsilon) {
      keep[idx] = 1;
      stack.push([s, idx], [idx, e]);
    }
  }
  return points.filter((_, i) => keep[i]);
}

/** Ramer–Douglas–Peucker for a closed ring: split at the vertex farthest from the first one. */
export function simplifyRing(ring: Ring, epsilon: number): Ring {
  if (ring.length <= 4) return ring.slice();
  let far = 0;
  let farD = -1;
  for (let i = 1; i < ring.length; i++) {
    const d = Math.hypot(ring[i][0] - ring[0][0], ring[i][1] - ring[0][1]);
    if (d > farD) {
      farD = d;
      far = i;
    }
  }
  const a = rdp(ring.slice(0, far + 1), epsilon);
  const b = rdp([...ring.slice(far), ring[0]], epsilon);
  return [...a.slice(0, -1), ...b.slice(0, -1)];
}

/** Simplifies until the ring has at most `maxPoints` vertices. */
export function simplifyToBudget(ring: Ring, epsilon: number, maxPoints: number): Ring {
  let eps = epsilon;
  let out = simplifyRing(ring, eps);
  while (out.length > maxPoints && eps < 64) {
    eps *= 1.6;
    out = simplifyRing(ring, eps);
  }
  return out;
}

export function boxIoU(a: Box, b: Box): number {
  const iw = Math.min(a[2], b[2]) - Math.max(a[0], b[0]);
  const ih = Math.min(a[3], b[3]) - Math.max(a[1], b[1]);
  if (iw <= 0 || ih <= 0) return 0;
  const inter = iw * ih;
  return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter);
}

/** A binary mask cropped to its box, row-major. */
export interface BoxMask {
  box: Box;
  width: number;
  height: number;
  data: Uint8Array;
  area: number;
}

export function maskArea(data: Uint8Array): number {
  let n = 0;
  for (let i = 0; i < data.length; i++) n += data[i];
  return n;
}

/** Pixels set in both masks, in full-frame coordinates. */
export function maskIntersection(a: BoxMask, b: BoxMask): number {
  const left = Math.max(a.box[0], b.box[0]);
  const top = Math.max(a.box[1], b.box[1]);
  const right = Math.min(a.box[0] + a.width, b.box[0] + b.width);
  const bottom = Math.min(a.box[1] + a.height, b.box[1] + b.height);
  let n = 0;
  for (let y = top; y < bottom; y++) {
    const ra = (y - a.box[1]) * a.width - a.box[0];
    const rb = (y - b.box[1]) * b.width - b.box[0];
    for (let x = left; x < right; x++) n += a.data[ra + x] & b.data[rb + x];
  }
  return n;
}

export function maskCentroid(m: BoxMask): Point {
  let sx = 0;
  let sy = 0;
  let n = 0;
  for (let y = 0; y < m.height; y++) {
    for (let x = 0; x < m.width; x++) {
      if (m.data[y * m.width + x]) {
        sx += x;
        sy += y;
        n++;
      }
    }
  }
  if (n === 0) return [(m.box[0] + m.box[2]) / 2, (m.box[1] + m.box[3]) / 2];
  return [m.box[0] + sx / n + 0.5, m.box[1] + sy / n + 0.5];
}

/**
 * Reading order: rows top to bottom, then left to right. Items whose centre lies within
 * half a median height of the row's first item share the row.
 */
export function readingOrder<T>(items: T[], centre: (t: T) => Point, height: (t: T) => number): T[] {
  if (items.length < 2) return items.slice();
  const heights = items.map(height).sort((a, b) => a - b);
  const tol = heights[Math.floor(heights.length / 2)] / 2;
  const byY = items.slice().sort((a, b) => centre(a)[1] - centre(b)[1]);
  const rows: T[][] = [];
  for (const it of byY) {
    const row = rows[rows.length - 1];
    if (row && centre(it)[1] - centre(row[0])[1] <= tol) row.push(it);
    else rows.push([it]);
  }
  return rows.flatMap((r) => r.sort((a, b) => centre(a)[0] - centre(b)[0]));
}
