// Verifies a Sign in with Apple identity token (a JWT signed by Apple, RS256).
// https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_rest_api/verifying_a_user

export const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";

export class AuthError extends Error {}

export function b64urlDecode(s) {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

const decodeJson = (part) => JSON.parse(new TextDecoder().decode(b64urlDecode(part)));

/**
 * @param {string} token        identity token from ASAuthorizationAppleIDCredential
 * @param {string[]} audiences  accepted bundle ids
 * @param {() => Promise<{keys: object[]}>} getJwks  Apple's public keys (cached by the caller)
 * @returns {Promise<{sub: string, email?: string}>}
 */
export async function verifyAppleToken(token, audiences, getJwks, now = Date.now()) {
  const parts = typeof token === "string" ? token.split(".") : [];
  if (parts.length !== 3) throw new AuthError("malformed identity token");
  let header, claims;
  try {
    header = decodeJson(parts[0]);
    claims = decodeJson(parts[1]);
  } catch {
    throw new AuthError("malformed identity token");
  }
  if (header.alg !== "RS256") throw new AuthError("unexpected token algorithm");

  const jwk = (await getJwks()).keys.find((k) => k.kid === header.kid);
  if (!jwk) throw new AuthError("unknown signing key");
  const key = await crypto.subtle.importKey(
    "jwk", { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"],
  );
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5", key, b64urlDecode(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!ok) throw new AuthError("bad token signature");

  const nowSec = Math.floor(now / 1000);
  if (claims.iss !== APPLE_ISSUER) throw new AuthError("wrong token issuer");
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.some((a) => audiences.includes(a))) throw new AuthError("token is for a different app");
  if (typeof claims.exp !== "number" || claims.exp < nowSec - 60) throw new AuthError("token expired");
  if (typeof claims.sub !== "string" || !claims.sub) throw new AuthError("token has no subject");
  return { sub: claims.sub, email: claims.email };
}
