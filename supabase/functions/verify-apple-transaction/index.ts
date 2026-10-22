// Supabase Edge Function: verify-apple-transaction
//
// The iOS app (StoreKit 2) sends the signed transaction JWS it receives from Apple.
// We verify the JWS against Apple's certificate chain, then upsert the organization's
// subscription row (service role — bypasses RLS). The app never writes subscriptions directly.
//
// Request (POST, Authorization: Bearer <user access token>):
//   { "signedTransaction": "<JWS>" }
// Response:
//   { "ok": true, "productId": "...", "expiresAt": "...", "status": "active" }

import { createClient } from "npm:@supabase/supabase-js@2";
import { X509Certificate } from "node:crypto";
import { decodeProtectedHeader, importX509, compactVerify } from "npm:jose@5";

// SHA-256 fingerprint of "Apple Root CA - G3" (DER). Verify against
// https://www.apple.com/certificateauthority/ before shipping to production.
const APPLE_ROOT_G3_SHA256 =
  "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179";

// Map App Store product ids → whether it's a subscription (true) or a consumable credit pack (count)
const PRODUCTS: Record<string, { kind: "subscription" } | { kind: "credits"; amount: number }> = {
  "com.lixisoft.roomscan.pro.monthly": { kind: "subscription" },
  "com.lixisoft.roomscan.pro.yearly": { kind: "subscription" },
  "com.lixisoft.roomscan.credits10": { kind: "credits", amount: 10 },
};

function pem(der: string) {
  return `-----BEGIN CERTIFICATE-----\n${der.match(/.{1,64}/g)!.join("\n")}\n-----END CERTIFICATE-----`;
}

async function verifyChainAndSignature(jws: string) {
  const header = decodeProtectedHeader(jws);
  const x5c = header.x5c as string[] | undefined;
  if (!x5c || x5c.length < 2) throw new Error("missing x5c chain");

  const certs = x5c.map((c) => new X509Certificate(pem(c)));
  // 1) root must be Apple Root CA - G3
  const root = certs[certs.length - 1];
  if (root.fingerprint256.replace(/:/g, "").toUpperCase() !== APPLE_ROOT_G3_SHA256) {
    throw new Error("untrusted root certificate");
  }
  // 2) each cert must be signed by the next, root self-signed, all within validity
  const now = Date.now();
  for (let i = 0; i < certs.length; i++) {
    const c = certs[i];
    if (now < Date.parse(c.validFrom) || now > Date.parse(c.validTo)) throw new Error("certificate expired");
    const issuer = i + 1 < certs.length ? certs[i + 1] : c;
    if (!c.verify(issuer.publicKey)) throw new Error(`certificate ${i} chain verification failed`);
  }
  // 3) verify JWS signature with leaf public key
  const leafKey = await importX509(pem(x5c[0]), (header.alg as string) ?? "ES256");
  const { payload } = await compactVerify(jws, leafKey);
  return JSON.parse(new TextDecoder().decode(payload));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const auth = req.headers.get("Authorization") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Identify the calling user with their own token
  const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return Response.json({ error: "unauthorized" }, { status: 401 });

  const admin = createClient(supabaseUrl, serviceKey);
  const { data: profile } = await admin.from("profiles").select("org_id").eq("id", user.id).single();
  if (!profile) return Response.json({ error: "no profile" }, { status: 400 });

  let body: { signedTransaction?: string };
  try { body = await req.json(); } catch { return Response.json({ error: "bad json" }, { status: 400 }); }
  if (!body.signedTransaction) return Response.json({ error: "signedTransaction required" }, { status: 400 });

  let tx: Record<string, unknown>;
  try {
    tx = await verifyChainAndSignature(body.signedTransaction);
  } catch (e) {
    return Response.json({ error: `verification failed: ${(e as Error).message}` }, { status: 400 });
  }

  const productId = String(tx.productId ?? "");
  const product = PRODUCTS[productId];
  if (!product) return Response.json({ error: `unknown product ${productId}` }, { status: 400 });

  const expiresAt = tx.expiresDate ? new Date(Number(tx.expiresDate)).toISOString() : null;
  const revoked = tx.revocationDate != null;

  if (product.kind === "subscription") {
    const status = revoked ? "revoked" : (expiresAt && Date.parse(expiresAt) < Date.now() ? "expired" : "active");
    const { error } = await admin.from("subscriptions").upsert({
      org_id: profile.org_id,
      platform: "apple",
      product_id: productId,
      original_transaction_id: String(tx.originalTransactionId),
      status,
      expires_at: expiresAt,
      environment: tx.environment ?? null,
      raw: tx,
      updated_at: new Date().toISOString(),
    }, { onConflict: "platform,original_transaction_id" });
    if (error) return Response.json({ error: error.message }, { status: 500 });
    return Response.json({ ok: true, productId, expiresAt, status });
  }

  // consumable credit pack — idempotent on transaction id
  const { error } = await admin.from("scan_credits").upsert({
    org_id: profile.org_id,
    amount: product.amount,
    reason: `apple:${productId}`,
    transaction_id: String(tx.transactionId),
  }, { onConflict: "transaction_id", ignoreDuplicates: true });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ ok: true, productId, credits: product.amount });
});
