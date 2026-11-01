import { DurableObject } from "cloudflare:workers";

export interface SpendStatus {
  today: number;
  total: number;
}

/** One global instance that records estimated spend per UTC day (SQLite-backed). */
export class Meter extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS spend (day TEXT PRIMARY KEY, usd REAL NOT NULL, calls INTEGER NOT NULL)",
    );
  }

  status(): SpendStatus {
    const today = this.ctx.storage.sql
      .exec<{ usd: number }>("SELECT usd FROM spend WHERE day = ?", utcDay())
      .toArray()[0]?.usd ?? 0;
    const total = this.ctx.storage.sql
      .exec<{ usd: number | null }>("SELECT SUM(usd) AS usd FROM spend")
      .one().usd ?? 0;
    return { today, total };
  }

  /**
   * Reserves `usd` for a call about to be made, unless that would pass a cap: the check and the
   * charge happen in one step here (a Durable Object runs one call at a time), so concurrent
   * requests cannot all pass the check before any of them is charged. The caller settles the
   * difference with the real cost afterwards (`add(actual - reserved, 0)`).
   */
  reserve(usd: number): boolean {
    if (!Number.isFinite(usd) || usd < 0) return false;
    const { today, total } = this.status();
    if (today + usd > Number(this.env.DAILY_CAP_USD) || total + usd > Number(this.env.TOTAL_CAP_USD)) return false;
    this.add(usd, 1);
    return true;
  }

  /**
   * Records spend. A negative amount corrects an estimate charged before the call (calls = 0),
   * so the total never drops below what was really used. A day never goes below zero, also
   * not when the correction is the first entry of a new UTC day.
   */
  add(usd: number, calls = 1): void {
    if (!Number.isFinite(usd) || usd === 0) return;
    this.ctx.storage.sql.exec(
      "INSERT INTO spend (day, usd, calls) VALUES (?, MAX(0, ?), ?) ON CONFLICT(day) DO UPDATE SET usd = MAX(0, usd + ?), calls = calls + excluded.calls",
      utcDay(),
      usd,
      calls,
      usd,
    );
  }
}

function utcDay(): string {
  return new Date().toISOString().slice(0, 10);
}

export function meter(env: Env): DurableObjectStub<Meter> {
  return env.METER.get(env.METER.idFromName("global"));
}
