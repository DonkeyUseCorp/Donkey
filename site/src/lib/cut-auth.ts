import { isDonkeycutHost } from "@/cut/lib/hosts";

// better-auth stamps Domain=donkeyuse.com on every auth cookie
// (crossSubDomainCookies in src/lib/auth.ts) so sessions ride the apex and its
// subdomains. donkeycut.com is a different registrable domain: browsers reject
// a Set-Cookie whose Domain does not cover the responding host, so cookies for
// donkeycut.com responses must drop the attribute and become host-only. The
// signed cookie value is domain-independent — the server accepts it either way.
export function stripCookieDomain(setCookie: string): string {
  return setCookie.replace(/;\s*Domain=[^;]*/i, "");
}

/** Re-scope every Set-Cookie on a response to host-only when it is being served
 * to donkeycut.com; responses for other hosts pass through untouched. */
export function withHostScopedAuthCookies(
  res: Response,
  host: string | null | undefined,
): Response {
  if (!isDonkeycutHost(host)) return res;
  const cookies = res.headers.getSetCookie();
  if (cookies.length === 0) return res;

  const headers = new Headers(res.headers);
  headers.delete("set-cookie");
  for (const cookie of cookies) headers.append("set-cookie", stripCookieDomain(cookie));
  return new Response(res.body, {
    status: res.status,
    statusText: res.statusText,
    headers,
  });
}
