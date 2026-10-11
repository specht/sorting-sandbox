// The dark/light theme switch, the same in all three sandboxes. The local
// server keeps the choice in .settings.yaml next to the app (ignored by Git)
// and writes it into the page, so the page never flashes the wrong colors.
(() => {
  const root = document.documentElement;
  if (!root) return;
  const apply = theme => {
    root.dataset.theme = theme;
    const button = document.getElementById('theme-toggle');
    if (button) {
      const next = theme === 'light' ? 'dark' : 'light';
      button.title = `Switch to the ${next} theme`;
      button.setAttribute('aria-label', button.title);
      button.querySelector('use')?.setAttribute('href', `/vendor/tabler-icons.svg#ti-${next === 'light' ? 'sun' : 'moon'}`);
    }
    window.dispatchEvent(new CustomEvent('sandbox-theme', { detail: theme }));
  };
  const start = () => {
    apply(root.dataset.theme === 'light' ? 'light' : 'dark');
    document.getElementById('theme-toggle')?.addEventListener('click', () => {
      const theme = root.dataset.theme === 'light' ? 'dark' : 'light';
      apply(theme);
      fetch('/api/settings', {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ theme }),
      }).catch(() => {}); // without the server, the theme still applies until the next reload
    });
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
