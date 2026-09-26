// Marks a commission's deposit/balance as paid once Stripe confirms the
// Checkout session completed. Public endpoint (verify_jwt = false in
// config.toml) — authenticity comes from the Stripe signature, not a JWT.
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig!, webhookSecret);
  } catch (err) {
    console.error("Signature verification failed", err);
    return new Response("Invalid signature", { status: 400 });
  }

  // Idempotency: Stripe retries webhook deliveries, so skip anything we've
  // already recorded rather than re-applying the update.
  const { error: dedupeError } = await admin.from("stripe_events").insert({ id: event.id });
  if (dedupeError) {
    // Unique-violation means we've already processed this event.
    return new Response(JSON.stringify({ received: true, duplicate: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (event.type === "checkout.session.completed") {
    const session = event.data.object as Stripe.Checkout.Session;
    const commissionId = session.metadata?.commission_id;
    const kind = session.metadata?.payment_kind;
    if (commissionId) {
      const patch = kind === "balance" ? { balance_paid: true } : { deposit_paid: true };
      const { error } = await admin.from("commissions")
        .update({ ...patch, updated_at: new Date().toISOString() })
        .eq("id", commissionId);
      if (error) console.error("Failed to update commission", error);
    } else {
      console.error("Webhook missing commission_id metadata");
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
