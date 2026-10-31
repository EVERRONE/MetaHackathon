export const META_API = "https://api.meta.ai/v1";

/** A non-2xx (or bodyless) answer from an upstream model API, passed on to the app. */
export class UpstreamError extends Error {
  constructor(
    readonly status: number,
    readonly service: string,
    message: string,
  ) {
    super(message);
  }

  static async from(res: Response, service: string): Promise<UpstreamError> {
    let message = res.statusText;
    try {
      const body = (await res.json()) as {
        error?: { message?: string } | string;
        message?: string;
        detail?: { message?: string } | string;
      };
      const detail = typeof body.detail === "string" ? body.detail : body.detail?.message;
      message = (typeof body.error === "string" ? body.error : body.error?.message) ?? body.message ?? detail ?? message;
    } catch {
      // Body was not JSON; keep the status text.
    }
    return new UpstreamError(res.status, service, message || `HTTP ${res.status}`);
  }

  /**
   * The status the app sees. Upstream auth failures are the Worker's problem (a bad or missing
   * key), not the app's, so they must not look like a bad app token.
   */
  get appStatus(): number {
    if (this.status >= 500 || this.status === 401 || this.status === 403 || this.status < 400) return 502;
    return this.status;
  }
}
