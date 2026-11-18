// Sidebar: open on wide screens, collapsed on narrow ones. The CSS already shows it on desktop if
// this never runs, so the navigation cannot be lost to a script error.
(function () {
  var side = document.querySelector('details.side');
  if (!side || !window.matchMedia) return;
  var wide = window.matchMedia('(min-width: 1025px)');
  var sync = function () { side.open = wide.matches; };
  sync();
  if (wide.addEventListener) wide.addEventListener('change', sync);
  else if (wide.addListener) wide.addListener(sync);
})();

// Search: a tiny client-side index over the page headings. `/` or cmd/ctrl-K focuses it.
(function () {
  var input = document.querySelector('.search input');
  var panel = document.querySelector('.results');
  if (!input || !panel) return;
  var index = [], current = -1;

  fetch('assets/search.json').then(function (r) { return r.json(); }).then(function (data) {
    index = data;
  }).catch(function () { /* offline or file://: search simply stays empty */ });

  function render(items) {
    if (!items.length) {
      panel.innerHTML = '<div class="empty">No match. Try “pair”, “tailscale”, “permissions”.</div>';
      panel.setAttribute('open', '');
      current = -1;
      return;
    }
    panel.innerHTML = items.map(function (it, i) {
      return '<a href="' + it.u + '" aria-selected="' + (i === current) + '">' +
        '<span class="r-page">' + it.p + '</span>' + it.h + '</a>';
    }).join('');
    panel.setAttribute('open', '');
  }

  function search(term) {
    term = term.trim().toLowerCase();
    if (!term) { panel.removeAttribute('open'); return; }
    var hits = index.filter(function (it) {
      return (it.h + ' ' + it.p + ' ' + (it.b || '')).toLowerCase().indexOf(term) >= 0;
    }).slice(0, 10);
    current = hits.length ? 0 : -1;
    render(hits);
  }

  input.addEventListener('input', function () { search(input.value); });
  input.addEventListener('keydown', function (e) {
    var links = panel.querySelectorAll('a');
    if (e.key === 'Escape') { panel.removeAttribute('open'); input.blur(); return; }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (!links.length) return;
      current = (current + (e.key === 'ArrowDown' ? 1 : -1) + links.length) % links.length;
      links.forEach(function (a, i) { a.setAttribute('aria-selected', i === current); });
      return;
    }
    if (e.key === 'Enter' && links.length) { window.location.href = links[Math.max(current, 0)].href; }
  });
  document.addEventListener('keydown', function (e) {
    var typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName);
    if ((e.key === '/' && !typing) || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k')) {
      e.preventDefault(); input.focus(); input.select();
    }
  });
  document.addEventListener('click', function (e) {
    if (!panel.contains(e.target) && e.target !== input) panel.removeAttribute('open');
  });
})();

// Copy buttons: report what actually happened.
document.querySelectorAll('.copy').forEach(function (button) {
  button.addEventListener('click', function () {
    var code = button.parentElement.querySelector('code');
    if (!code) return;
    var text = code.textContent;
    var done = function (label) {
      button.textContent = label; button.dataset.done = '1';
      setTimeout(function () { button.textContent = 'Copy'; delete button.dataset.done; }, 1600);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { done('Copied'); }, function () { done('Select it'); });
    } else { done('Select it'); }
  });
});

// On this page: mark the section you are reading.
(function () {
  var links = Array.prototype.slice.call(document.querySelectorAll('.toc a'));
  if (!links.length || !('IntersectionObserver' in window)) return;
  var map = {};
  links.forEach(function (a) { map[a.getAttribute('href').slice(1)] = a; });
  var seen = [];
  var obs = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      seen = seen.filter(function (id) { return id !== e.target.id; });
      if (e.isIntersecting) seen.push(e.target.id);
    });
    links.forEach(function (a) { a.classList.remove('active'); });
    if (seen.length && map[seen[0]]) map[seen[0]].classList.add('active');
  }, { rootMargin: '-10% 0px -70% 0px' });
  Object.keys(map).forEach(function (id) {
    var el = document.getElementById(id);
    if (el) obs.observe(el);
  });
})();
