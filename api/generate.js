// Serveur : la clé OpenAI reste ici, jamais dans la page.
module.exports = async (req, res) => {
  if (req.method !== "POST") return res.status(405).end();
  const prompt = req.body && req.body.prompt;
  if (typeof prompt !== "string" || !prompt.trim() || prompt.length > 6000) {
    return res.status(400).json({ error: "Requête invalide" });
  }
  try {
    const r = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + process.env.OPENAI_API_KEY,
      },
      body: JSON.stringify({
        model: process.env.OPENAI_MODEL || "gpt-4o-mini",
        input: prompt,
        max_output_tokens: 1200,
      }),
    });
    if (!r.ok) return res.status(r.status === 429 ? 429 : 502).json({ error: "OpenAI" });
    const d = await r.json();
    const text = (d.output || [])
      .flatMap((o) => o.content || [])
      .filter((c) => c.type === "output_text")
      .map((c) => c.text)
      .join("");
    return res.status(200).json({ text });
  } catch (e) {
    return res.status(502).json({ error: "Serveur" });
  }
};
