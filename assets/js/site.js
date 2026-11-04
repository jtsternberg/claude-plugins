(() => {
  const root = document.documentElement;
  const preference = window.matchMedia('(prefers-color-scheme: dark)');
  const toggle = document.querySelector('.theme-toggle');
  const isDark = () => root.dataset.theme ? root.dataset.theme === 'dark' : preference.matches;
  const updateLabel = () => {
    if (!toggle) return;
    const label = `Switch to ${isDark() ? 'light' : 'dark'} mode`;
    toggle.setAttribute('aria-label', label);
    toggle.title = label;
  };

  const forwardLegacySection = () => {
    const guide = document.querySelector('main[data-guide-url]');
    if (!guide || !window.location.hash) return;
    let id;
    try { id = decodeURIComponent(window.location.hash.slice(1)); } catch { return; }
    if (!document.getElementById(id)) window.location.replace(guide.dataset.guideUrl + window.location.hash);
  };
  forwardLegacySection();
  window.addEventListener('hashchange', forwardLegacySection);

  for (const heading of document.querySelectorAll('main :is(h2,h3,h4,h5,h6)[id]')) {
    const anchor = document.createElement('a');
    anchor.className = 'heading-anchor';
    anchor.href = `#${heading.id}`;
    anchor.setAttribute('aria-label', `Permalink to ${heading.textContent}`);
    anchor.textContent = '#';
    heading.append(anchor);
  }

  if (toggle) {
    toggle.hidden = false;
    toggle.addEventListener('click', () => {
      const theme = isDark() ? 'light' : 'dark';
      root.dataset.theme = theme;
      try { localStorage.setItem('claude-plugins-theme', theme); } catch {}
      updateLabel();
    });
    preference.addEventListener('change', updateLabel);
    window.addEventListener('storage', (event) => {
      if (event.key !== 'claude-plugins-theme' && event.key !== null) return;
      if (event.newValue === 'dark' || event.newValue === 'light') root.dataset.theme = event.newValue;
      else delete root.dataset.theme;
      updateLabel();
    });
    updateLabel();
  }

  if (!navigator.clipboard?.writeText) return;
  for (const block of document.querySelectorAll('pre')) {
    const code = block.querySelector('code');
    if (!code) continue;
    const card = block.closest('.install-card');
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'copy-button';
    const label = card ? `Copy ${card.querySelector('h3').textContent} commands` : 'Copy code';
    button.setAttribute('aria-label', label);
    button.title = label;
    button.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><rect x="8" y="8" width="12" height="13" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/></svg><span class="sr-only" aria-live="polite"></span>';
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(code.textContent);
        button.dataset.copied = 'true';
        button.setAttribute('aria-label', 'Copied');
        button.querySelector('span').textContent = 'Copied';
        setTimeout(() => {
          delete button.dataset.copied;
          button.setAttribute('aria-label', label);
          button.querySelector('span').textContent = '';
        }, 1800);
      } catch {
        button.setAttribute('aria-label', 'Could not copy. Select and copy the code.');
        button.querySelector('span').textContent = 'Could not copy. Select and copy the code.';
      }
    });
    (card || block).append(button);
  }
})();
