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

  add(usd: number): void {
    if (!(usd > 0)) return;
    this.ctx.storage.sql.exec(
      "INSERT INTO spend (day, usd, calls) VALUES (?, ?, 1) ON CONFLICT(day) DO UPDATE SET usd = usd + excluded.usd, calls = calls + 1",
      utcDay(),
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
