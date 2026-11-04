# Site maintenance

The [public website](https://jtsternberg.github.io/claude-plugins/) uses GitHub
Pages' branch-based Jekyll build from `main`, at the repository root. A push to
`main` publishes the site; the `site` workflow builds relevant pull requests
without deploying them.

The homepage is `index.html`. `_layouts/default.html` supplies the header,
footer, fonts, and theme controls for the homepage and existing Markdown pages.
Plugin READMEs remain in their plugin directories; the supported
`jekyll-readme-index` and `jekyll-relative-links` plugins provide their page routes.
The root README also renders at `/guide.html`, preserving the full original site
content. Old homepage section links forward to that guide when the section is
not part of the new homepage. The README and compatibility guide remain the
detailed installation references.
The guide stays at the site root so its relative links retain their original
base; directories without a README link to their source on GitHub.

Colors and responsive layouts live in `assets/css/site.css`. Dark mode uses
chocolate and orange with a pale teal action color; light mode uses warm ivory,
chocolate text, and deep teal actions. Themes follow the system preference until
the visitor chooses one, then persist that choice locally. `assets/js/site.js`
also adds copy buttons to code blocks when the Clipboard API is available.
Headings retain their generated IDs and receive permalink controls; each page's
footer links to its source on GitHub with “Improve this page”.

To build locally without installing Ruby gems, use the official Pages builder
container (requires Docker):

```bash
docker run --rm \
  -e GITHUB_WORKSPACE=/site \
  -e GITHUB_REPOSITORY=jtsternberg/claude-plugins \
  -e INPUT_SOURCE=. \
  -e INPUT_DESTINATION=_site \
  -v "$PWD:/site" \
  ghcr.io/actions/jekyll-build-pages:v1.0.13
```

Serve the generated site with its production base path:

```bash
mkdir -p /tmp/site-preview
ln -s "$PWD/_site" /tmp/site-preview/claude-plugins
python3 -m http.server --directory /tmp/site-preview 4173
```

Open `http://localhost:4173/claude-plugins/` and check both themes, a narrow
viewport, installation copying, and the compatibility guide. The typography
uses Manrope and JetBrains Mono from Google Fonts with local fallbacks.
