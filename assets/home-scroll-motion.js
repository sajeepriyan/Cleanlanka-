/* Presentation only: content stays visible and usable without this enhancement. */
(() => {
  'use strict';
  if (!('IntersectionObserver' in window) || !Element.prototype.animate) return;
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const hero = document.querySelector('.cl-hero');
  const seen = new WeakSet();
  const running = new Set();
  const selector = [
    '#services-section .cl-home-cat',
    '#homeMarketplace .cl-market-heading',
    '#homeMarketplace .cl-market-trust > *',
    '#how-it-works h2', '#how-it-works h2 + p',
    '#how-it-works .grid > div',
    '#why-choose-us h2', '#why-choose-us h2 + p',
    '#why-choose-us .space-y-6 > div'
  ].join(',');
  const disabled = () => reduced.matches || hero?.dataset.motionPaused === 'true';
  function stop() {
    running.forEach(animation => animation.cancel());
    running.clear();
  }
  const observer = new IntersectionObserver(entries => {
    let order = 0;
    for (const entry of entries) {
      const node = entry.target;
      if (!entry.isIntersecting || !node.getClientRects().length) continue;
      observer.unobserve(node);
      if (seen.has(node)) continue;
      seen.add(node);
      if (disabled()) continue;
      try {
        // Start only on entry: no pending hidden state, layout changes or click delay.
        const animation = node.animate([
          { opacity: 0.65, translate: '0 12px' },
          { opacity: 1, translate: '0 0' }
        ], { duration: 480, delay: Math.min(order++ * 45, 135), easing: 'cubic-bezier(.2,.7,.2,1)' });
        running.add(animation);
        animation.finished.catch(() => {}).finally(() => running.delete(animation));
      } catch (_) { /* Unsupported animation leaves the original content untouched. */ }
    }
  }, { threshold: 0.08 });
  document.querySelectorAll(selector).forEach(node => observer.observe(node));
  for (const id of ['homeJobResults', 'homeWorkerResults']) {
    const host = document.getElementById(id);
    if (!host) continue;
    const watchCards = () => host.querySelectorAll(':scope > article:not([aria-hidden="true"])')
      .forEach(node => { if (!seen.has(node)) observer.observe(node); });
    watchCards();
    new MutationObserver(watchCards).observe(host, { childList: true });
  }
  // Reuse the existing homepage pause control; never replace its click handler.
  if (hero) new MutationObserver(() => { if (disabled()) stop(); })
    .observe(hero, { attributes: true, attributeFilter: ['data-motion-paused'] });
  reduced.addEventListener?.('change', () => { if (disabled()) stop(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
})();
