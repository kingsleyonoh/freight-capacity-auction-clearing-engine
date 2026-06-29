let render () =
  {|<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Freight Capacity Auction Clearing Engine</title>
  <script src="https://unpkg.com/htmx.org@1.9.12" defer></script>
  <style>
    :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, sans-serif; }
    body { margin: 0; background: #eef3f7; color: #172033; }
    a, button { min-height: 44px; }
    .shell { max-width: 1180px; margin: 0 auto; padding: 32px 20px 48px; }
    .hero { background: #10233f; color: #f8fbff; border-radius: 24px; padding: clamp(24px, 5vw, 56px); }
    .eyebrow { color: #8fd4ff; font-size: 0.82rem; font-weight: 800; letter-spacing: 0.08em; text-transform: uppercase; }
    h1 { max-width: 760px; margin: 12px 0; font-size: clamp(2rem, 5vw, 4.2rem); line-height: 0.98; }
    .hero p { max-width: 760px; color: #dcecff; font-size: 1.08rem; }
    .actions { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 24px; }
    .button { display: inline-flex; align-items: center; justify-content: center; border-radius: 999px; padding: 0 18px; font-weight: 800; text-decoration: none; }
    .primary { background: #f9c74f; color: #172033; }
    .secondary { border: 1px solid #6b85aa; color: #f8fbff; }
    .grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; margin-top: 20px; }
    .panel { background: #fff; border: 1px solid #cfd9e6; border-radius: 18px; padding: 18px; box-shadow: 0 14px 35px rgba(16, 35, 63, 0.08); }
    .panel h2, .panel h3 { margin-top: 0; }
    .badge { display: inline-flex; align-items: center; gap: 6px; border-radius: 999px; padding: 6px 10px; font-size: 0.78rem; font-weight: 800; background: #e5f6eb; color: #14532d; }
    .warning { background: #fff7df; color: #7a4d00; }
    table { width: 100%; border-collapse: collapse; font-size: 0.94rem; }
    caption { text-align: left; font-weight: 900; margin-bottom: 10px; }
    th, td { padding: 10px; border-bottom: 1px solid #d7e0eb; text-align: left; }
    th { color: #334155; font-size: 0.78rem; letter-spacing: 0.04em; text-transform: uppercase; }
    :focus-visible { outline: 3px solid #0ea5e9; outline-offset: 3px; }
    @media (max-width: 760px) { .grid { grid-template-columns: 1fr; } .shell { padding: 16px; } }
    @media (prefers-reduced-motion: reduce) { * { scroll-behavior: auto !important; transition: none !important; } }
  </style>
</head>
<body>
  <main class="shell">
    <section class="hero" aria-labelledby="page-title">
      <div class="eyebrow">Standalone freight auction control plane</div>
      <h1 id="page-title">Freight Capacity Auction Clearing Engine</h1>
      <p>Run tenant-scoped spot-capacity auctions, preserve solver evidence, and explain every accepted or rejected bid without exposing sealed-bid competitor data.</p>
      <div class="actions" aria-label="Primary actions">
        <a class="button primary" href="/login">Open API key login</a>
        <a class="button secondary" href="/dashboard" hx-boost="true">Review auction dashboard</a>
      </div>
    </section>

    <section class="grid" aria-label="Operations readiness">
      <article class="panel" data-testid="ops-status-panel">
        <span class="badge">Core ready</span>
        <h2>Local service stack</h2>
        <p>PostgreSQL, Redis, DuckDB replay storage, and solver process adapters are configured as independent local dependencies.</p>
      </article>
      <article class="panel" data-privacy-scope="sealed-bid">
        <span class="badge warning">Privacy guard</span>
        <h2>sealed-bid privacy</h2>
        <p>Operator views explain binding constraints; redacted carrier view labels own-bid facts and suppresses competitor amounts.</p>
      </article>
      <article class="panel">
        <span class="badge">Audit-first</span>
        <h2>Solver evidence</h2>
        <p>Clearing jobs preserve policy snapshots, input facts, solver model artifacts, output artifacts, and explanation snapshots.</p>
      </article>
    </section>

    <section class="panel" aria-labelledby="readiness-heading">
      <h2 id="readiness-heading">Setup baseline</h2>
      <div role="status" aria-live="polite">No live auction selected — setup baseline only.</div>
      <table>
        <caption>Auction readiness</caption>
        <thead>
          <tr><th scope="col">Surface</th><th scope="col">Status</th><th scope="col">Evidence</th></tr>
        </thead>
        <tbody>
          <tr><td>Tenant path</td><td>Required</td><td>API key/JWT context planned for all routes</td></tr>
          <tr><td>Replay</td><td>Configured</td><td>DuckDB file-backed store under data/</td></tr>
          <tr><td>Responsive flows</td><td>Baseline</td><td>Login, dashboard status, approvals, carrier bid view</td></tr>
        </tbody>
      </table>
    </section>
  </main>
</body>
</html>|}
