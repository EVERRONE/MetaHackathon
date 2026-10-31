export const META_API = "https://api.meta.ai/v1";

/** A non-2xx answer from the Meta Model API, passed on to the app with its status. */
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
      const body = (await res.json()) as { error?: { message?: string } | string; message?: string };
      message = (typeof body.error === "string" ? body.error : body.error?.message) ?? body.message ?? message;
    } catch {
      // Body was not JSON; keep the status text.
    }
    return new UpstreamError(res.status, service, message);
  }
}
