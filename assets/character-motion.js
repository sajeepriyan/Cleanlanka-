/* Motion controls only; service click handlers and account logic stay intact. */
(() => {
  const services = document.getElementById('services-section');
  const hero = document.querySelector('.cl-hero');
  if (!services) return;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let visible = false;
  const update = () => {
    services.dataset.characterMotion = visible && !document.hidden && !reduced.matches && hero?.dataset.motionPaused !== 'true' ? 'active' : 'paused';
  };
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(entries => { visible = entries[0].isIntersecting; update(); })
      .observe(services);
  } else { visible = true; update(); }
  if (hero) new MutationObserver(update).observe(hero, { attributes:true, attributeFilter:['data-motion-paused'] });
  reduced.addEventListener?.('change', update);
  document.addEventListener('visibilitychange', update);
})();
