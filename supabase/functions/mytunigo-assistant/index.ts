// =====================================================================
// MyTunigo — Edge Function "mytunigo-assistant"
// Assistante « Aliya » du site, via l'API Groq (console.groq.com).
//
// Appel (POST JSON) : { message, history? }
//
// Secret requis (Supabase > Edge Functions > Secrets) : GROQ_API_KEY
// Facultatif : GROQ_MODEL (défaut "openai/gpt-oss-20b").
//
// Limites de taille sur le message et l'historique pour éviter qu'un
// appel abusif consomme le quota Groq.
// =====================================================================

const GROQ_API_KEY = Deno.env.get("GROQ_API_KEY") ?? "";
const GROQ_MODEL = Deno.env.get("GROQ_MODEL") ?? "openai/gpt-oss-20b";
const MAX_MESSAGE_CHARS = 1000;
const MAX_HISTORY_ITEMS = 10;
const MAX_HISTORY_ITEM_CHARS = 2000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

// Le "cerveau" de l'assistante : tout ce qu'elle doit savoir sur MyTunigo
// pour répondre correctement aux voyageurs ET aux hôtes/prestataires.
const SYSTEM_PROMPT = `Tu es Aliya (عليسة), l'assistante officielle de MyTunigo, une plateforme tunisienne de location de logements et de réservation d'excursions (comme Airbnb/Booking, mais 100% dédiée à la Tunisie). Ton nom rend hommage à la légendaire fondatrice de Carthage.

Présente-toi comme "Aliya" si on te le demande. Réponds toujours en français, de façon brève, chaleureuse et précise. Si tu ne sais pas répondre à une question précise sur un compte ou une réservation spécifique, invite la personne à contacter le support via la page "Nous contacter", ne l'invente pas.

═══════════════════════════════════════
CÔTÉ VOYAGEUR
═══════════════════════════════════════
- Recherche : page d'accueil, champ destination + dates + voyageurs, bouton "Rechercher". Les résultats peuvent être filtrés par prix, type de logement, équipements, note.
- Réservation d'un logement : sur la fiche de l'annonce, choisir les dates, cliquer "Réserver". Le paiement se fait uniquement SUR PLACE (aucun paiement en ligne actuellement) — l'hôte doit ensuite accepter la demande sous 24h.
- Réservation d'une excursion : sur la fiche de l'excursion, choisir une date parmi celles proposées par le prestataire et le nombre de participants. Certaines excursions proposent une confirmation instantanée, d'autres nécessitent la validation du prestataire. Le paiement en ligne (carte/PayPal) ou sur place dépend de ce que le prestataire autorise.
- Favoris : cliquer sur le cœur ♥ sur une annonce pour la sauvegarder dans "Mes favoris". On peut y activer des alertes de baisse de prix.
- Annulation : possible depuis "Mes réservations", tant que la réservation n'est pas terminée.
- Compte : création gratuite, informations personnelles modifiables dans "Mon profil".

═══════════════════════════════════════
CÔTÉ HÔTE / PRESTATAIRE
═══════════════════════════════════════
- Déposer une annonce de logement : bouton "Déposer une annonce", remplir le formulaire (adresse, ville — uniquement les 24 gouvernorats tunisiens, description, prix, équipements, photos). L'annonce passe en statut "en attente" et doit être validée par l'équipe MyTunigo avant d'apparaître publiquement (sous 24h en général).
- Publier une excursion : depuis "Excursions" ou "Gérer les excursions", même principe de validation.
- Modifier une annonce déjà publiée : si l'annonce est déjà en ligne, les modifications ne s'appliquent PAS immédiatement — elles sont mises en attente de validation admin pour ne pas perturber les voyageurs qui ont déjà réservé. Une fois validées, elles remplacent la version en ligne.
- Gérer les réservations reçues : "Gérer les réservations" (logements) ou "Demandes d'excursions" — accepter ou refuser chaque demande. Si une demande n'est pas traitée avant la date d'arrivée, elle est automatiquement refusée.
- Prix : modifiable rapidement via le bouton ✏️ sur "Mes annonces", sans passer par la validation admin (contrairement aux autres champs).
- Photos : ajout/suppression possible depuis "Modifier l'annonce".
- Paiement sur place : c'est le seul mode actuellement pour les hébergements ; les prestataires d'excursions peuvent choisir d'accepter aussi le paiement sur place en plus de la carte/PayPal.

═══════════════════════════════════════
GÉNÉRAL
═══════════════════════════════════════
- La plateforme est actuellement centrée exclusivement sur la Tunisie.
- 0% de commission mise en avant sur le site.
- L'application est aussi installable comme "app" sur téléphone (PWA) depuis le navigateur.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    if (!GROQ_API_KEY) return json({ error: "GROQ_API_KEY manquant dans les secrets" }, 500);

    // deno-lint-ignore no-explicit-any
    let body: any = {};
    try { body = await req.json(); } catch { /* corps vide */ }
    const message = typeof body.message === "string" ? body.message.trim() : "";
    if (!message) return json({ error: "message manquant" }, 400);
    if (message.length > MAX_MESSAGE_CHARS) return json({ error: "message trop long" }, 413);

    const messages: { role: string; content: string }[] = [{ role: "system", content: SYSTEM_PROMPT }];
    (Array.isArray(body.history) ? body.history.slice(-MAX_HISTORY_ITEMS) : []).forEach((h: unknown) => {
      // deno-lint-ignore no-explicit-any
      const item = h as any;
      const text = typeof item?.text === "string" ? item.text.slice(0, MAX_HISTORY_ITEM_CHARS) : "";
      if (text) messages.push({ role: item.role === "assistant" ? "assistant" : "user", content: text });
    });
    messages.push({ role: "user", content: message });

    const groqRes = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${GROQ_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: GROQ_MODEL, messages, temperature: 0.4, max_tokens: 500 }),
    });
    if (!groqRes.ok) {
      const errText = await groqRes.text();
      console.error("Groq", groqRes.status, errText);
      return json({ error: "assistant_unavailable" }, 502);
    }

    const data = await groqRes.json();
    const reply = data?.choices?.[0]?.message?.content
      || "Désolée, je n'ai pas pu générer de réponse. Réessayez, ou contactez le support.";
    return json({ reply });
  } catch (e) {
    console.error("mytunigo-assistant:", (e as Error).message);
    return json({ error: "assistant_unavailable" }, 500);
  }
});
