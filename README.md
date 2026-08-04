# benfactor-cc — retired legacy repository

This repository is retained only to preserve history for an early, misspelled Benefactor static-site artifact.

It is **not** the canonical editable website, a deployment source, or an active application repository.

- Canonical website: [benefactor.cc](https://benefactor.cc/)
- Canonical Astro source: [`ORESoftware/benefactor.cc`](https://github.com/ORESoftware/benefactor.cc)
- Deliberate generated Pages output: [`benefactor-cc/benefactor-cc.github.io`](https://github.com/benefactor-cc/benefactor-cc.github.io)

## Retirement contract

- `index.html` must remain a minimal, no-index redirect to `https://benefactor.cc/`.
- This repository must not contain a `CNAME`, GitHub Pages deployment workflow, deployment credentials, customer data, lead lists, or active forms.
- Old generated assets remain in Git history; they are not reviewed product claims and must not be republished.
- Do not add new marketing claims, service descriptions, analytics, forms, or application code here.
- Changes to the live website belong in the canonical Astro source and are published through the reviewed generated-output path.

Run the repository guard locally with:

```sh
node scripts/validate-legacy-repo.mjs
```
