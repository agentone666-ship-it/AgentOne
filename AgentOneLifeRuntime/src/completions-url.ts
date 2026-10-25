/** Accept the same base-or-full-endpoint input as the native settings client. */
export function chatCompletionsEndpoint(value: string): string {
  const url = new URL(value.trim());
  url.pathname = url.pathname.replace(/\/+$/, "");
  if (!url.pathname.endsWith("/chat/completions")) url.pathname += "/chat/completions";
  url.hash = "";
  return url.toString();
}

/** Pi's streaming provider accepts a base URL rather than a full endpoint. */
export function chatCompletionsBaseURL(value: string): string {
  const url = new URL(value);
  url.pathname = url.pathname.replace(/\/+$/, "").replace(/\/chat\/completions$/, "");
  url.hash = "";
  return url.toString().replace(/\/$/, "");
}
