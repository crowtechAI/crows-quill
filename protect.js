// Light deterrent for casual image saving: blocks the right-click menu and
// image dragging on public pages. Form fields keep their menu so people can
// paste into the booking form. This cannot stop determined copying
// (screenshots, dev tools), and it is deliberately not loaded on /admin.
(function () {
  document.addEventListener('contextmenu', function (e) {
    var t = e.target;
    if (t && t.closest && t.closest('input, textarea, select, [contenteditable="true"]')) return;
    e.preventDefault();
  });
  document.addEventListener('dragstart', function (e) {
    if (e.target && e.target.tagName === 'IMG') e.preventDefault();
  });
  var style = document.createElement('style');
  style.textContent = 'img{-webkit-user-drag:none;-webkit-touch-callout:none;user-select:none;-webkit-user-select:none}';
  document.head.appendChild(style);
})();
