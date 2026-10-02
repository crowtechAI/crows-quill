// Marks a commission's deposit/balance as paid once Stripe confirms the
// Checkout session was paid. Public endpoint (verify_jwt = false in
// config.toml) — authenticity comes from the Stripe signature, not a JWT.
// A DB trigger moves an "accepted" commission to "in_progress" when the
// deposit flips to paid.
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", { apiVersion: "2024-06-20" });
const cryptoProvider = Stripe.createSubtleCryptoProvider();

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const ok = (body: unknown) =>
  new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  // Fail closed: never process events without a signing secret to check them against.
  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!webhookSecret) {
    console.error("STRIPE_WEBHOOK_SECRET is not set");
    return new Response("Webhook not configured", { status: 500 });
  }

  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("Missing signature", { status: 400 });

  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, webhookSecret, undefined, cryptoProvider);
  } catch (err) {
    console.error("Signature verification failed", err);
    return new Response("Invalid signature", { status: 400 });
  }

  if (event.type !== "checkout.session.completed" && event.type !== "checkout.session.async_payment_succeeded") {
    return ok({ received: true, ignored: true });
  }
  const session = event.data.object as Stripe.Checkout.Session;
  if (session.payment_status !== "paid") return ok({ received: true, ignored: "not paid" });

  const commissionId = session.metadata?.commission_id;
  const kind = session.metadata?.payment_kind;
  if (!commissionId) {
    console.error("Webhook missing commission_id metadata", event.id);
    return ok({ received: true, ignored: "no commission_id" });
  }

  // Idempotency: Stripe retries deliveries. Only a unique violation means "already processed".
  const { error: dedupeError } = await admin.from("stripe_events").insert({ id: event.id });
  if (dedupeError) {
    if (dedupeError.code === "23505") return ok({ received: true, duplicate: true });
    console.error("stripe_events insert failed", dedupeError);
    return new Response("Database error", { status: 500 });
  }

  const patch = kind === "balance" ? { balance_paid: true } : { deposit_paid: true };
  const { data, error } = await admin.from("commissions")
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq("id", commissionId)
    .select("id");
  if (error) {
    console.error("Failed to update commission", error);
    // Release the dedupe row so Stripe's retry can try again.
    await admin.from("stripe_events").delete().eq("id", event.id);
    return new Response("Database error", { status: 500 });
  }
  if (!data?.length) console.error("No commission matched", commissionId, event.id);

  return ok({ received: true });
});
