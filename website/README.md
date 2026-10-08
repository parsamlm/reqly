# reqly.net

Reqly's website: the home page, the docs and the privacy page, built with [Astro](https://astro.build) and [Starlight](https://starlight.astro.build). It needs Node.js 22.12 or later.

To work on it, from this folder:

```bash
npm install
npm run dev
```

| Path | What's in it |
|---|---|
| `src/pages/` | The home page and the privacy page. |
| `src/content/docs/docs/` | The docs, one Markdown file per page. The sidebar's order is in `astro.config.mjs`. |
| `src/styles/` | Reqly's colors and type (`brand.css`), the home and privacy pages' styles (`site.css`) and the docs' (`docs.css`). |
| `src/links.ts` | Where the site links to, such as the download and GitHub. |
| `public/images/` | Screenshots of the app, as `<name>-light.webp` and `<name>-dark.webp`, taken at 2x with the window's shadow. Until a pair exists, the page shows a placeholder. |

The [Website workflow](../.github/workflows/website.yml) builds the site for every change.
