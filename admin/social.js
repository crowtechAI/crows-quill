/* Studio → Social posts
 * Watermarks an uploaded artwork and places it in the Instagram post template (1080×1350, 4:5).
 * Everything happens in the browser: the original image is never uploaded or stored.
 * Watermark recipe mirrors Crows-Quill-originals/watermark.sh:
 *   logo = 18% of width, 20% opacity, two staggered logos per tile, tile rotated -22°, repeated edge to edge.
 */
(function () {
  const W = 1080, H = 1350, M = 65;
  const GOLD = '#DCBC7C', INK = '#0E0C16', PARCH = '#F4EFE6', LILAC = '#CDC4D9';
  const ART = { x: M, y: 170, w: W - 2 * M, h: 810 };
  const WM = { widthPct: 0.18, opacity: 0.20, angle: 22 };

  const state = {
    img: null, zoom: 1, ox: 0, oy: 0,
    label: 'CHARACTER PORTRAIT',
    name: 'Character Name',
    line: 'A single line of voice from the book goes here.',
    series: 'NIGHTWILD RISING',
    handle: '@thecrowsquill',
  };
  let logo = null, built = false, raf = 0, objectUrl = null;

  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const slug = s => (s || 'post').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'post';

  function loadLogo() {
    return new Promise((resolve, reject) => {
      const i = new Image();
      i.onload = () => resolve(i);
      i.onerror = reject;
      i.src = '/images/crows-quill-logo.png';
    });
  }

  // ---------- watermark: tiled, rotated logo over a rectangle ----------
  function watermark(ctx, x, y, w, h) {
    const lw = Math.round(w * WM.widthPct);
    const lh = Math.round(lw * logo.naturalHeight / logo.naturalWidth);
    const tw = Math.round(lw * 2.4), th = Math.round(lh * 3.6);
    const t = document.createElement('canvas'); t.width = tw; t.height = th;
    const tc = t.getContext('2d');
    tc.imageSmoothingQuality = 'high';
    tc.globalAlpha = WM.opacity;
    tc.drawImage(logo, lw * 0.3, lh * 0.4, lw, lh);
    tc.drawImage(logo, lw * 1.4, lh * 2.2, lw, lh);
    const a = WM.angle * Math.PI / 180;
    const rw = Math.ceil(tw * Math.cos(a) + th * Math.sin(a));
    const rh = Math.ceil(tw * Math.sin(a) + th * Math.cos(a));
    const r = document.createElement('canvas'); r.width = rw; r.height = rh;
    const rc = r.getContext('2d');
    rc.imageSmoothingQuality = 'high';
    rc.translate(rw / 2, rh / 2); rc.rotate(-a); rc.drawImage(t, -tw / 2, -th / 2);
    ctx.save();
    ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
    ctx.translate(x, y);
    ctx.fillStyle = ctx.createPattern(r, 'repeat');
    ctx.fillRect(0, 0, w, h);
    ctx.restore();
  }

  // ---------- artwork: cover-fit with pan/zoom ----------
  function artGeometry(w, h) {
    const img = state.img;
    const s = Math.max(w / img.width, h / img.height) * state.zoom;
    const dw = img.width * s, dh = img.height * s;
    const mx = (dw - w) / 2, my = (dh - h) / 2;
    return { dw, dh, mx, my };
  }
  function drawArt(ctx, x, y, w, h) {
    const g = artGeometry(w, h);
    state.ox = clamp(state.ox, -g.mx, g.mx); state.oy = clamp(state.oy, -g.my, g.my);
    ctx.save();
    ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(state.img, x + (w - g.dw) / 2 + state.ox, y + (h - g.dh) / 2 + state.oy, g.dw, g.dh);
    ctx.restore();
  }

  // ---------- text helpers ----------
  function spaced(ctx, text, x, y, sp, align) {
    const chars = [...text];
    const ws = chars.map(c => ctx.measureText(c).width);
    const total = ws.reduce((a, b) => a + b, 0) + sp * Math.max(0, chars.length - 1);
    let cx = align === 'right' ? x - total : align === 'center' ? x - total / 2 : x;
    ctx.textAlign = 'left';
    chars.forEach((c, i) => { ctx.fillText(c, cx, y); cx += ws[i] + sp; });
    return total;
  }
  function wrapLines(ctx, text, maxW) {
    const out = []; let cur = '';
    text.split(/\s+/).filter(Boolean).forEach(word => {
      const test = cur ? cur + ' ' + word : word;
      if (ctx.measureText(test).width <= maxW || !cur) cur = test; else { out.push(cur); cur = word; }
    });
    if (cur) out.push(cur);
    return out;
  }

  // ---------- the post ----------
  function draw() {
    const cv = document.getElementById('socCanvas');
    if (!cv || !logo) return;
    const ctx = cv.getContext('2d');
    ctx.clearRect(0, 0, W, H);
    ctx.fillStyle = INK; ctx.fillRect(0, 0, W, H);
    ctx.textBaseline = 'alphabetic';

    ctx.strokeStyle = 'rgba(220,188,124,.30)'; ctx.lineWidth = 1;
    ctx.strokeRect(32.5, 32.5, W - 65, H - 65);

    // header: label left, wordmark right
    ctx.fillStyle = GOLD; ctx.font = '500 22px Cinzel, serif';
    spaced(ctx, (state.label || '').toUpperCase(), M, M + 18, 6, 'left');
    ctx.font = '600 22px Cinzel, serif';
    ['THE', 'CROWS', 'QUILL'].forEach((t, i) => spaced(ctx, t, W - M, M + 18 + i * 26, 5, 'right'));

    // artwork
    if (state.img) {
      drawArt(ctx, ART.x, ART.y, ART.w, ART.h);
      watermark(ctx, ART.x, ART.y, ART.w, ART.h);
      ctx.strokeStyle = GOLD; ctx.lineWidth = 2;
      ctx.strokeRect(ART.x - 1, ART.y - 1, ART.w + 2, ART.h + 2);
    } else {
      ctx.fillStyle = '#16121f'; ctx.fillRect(ART.x, ART.y, ART.w, ART.h);
      ctx.setLineDash([10, 8]); ctx.strokeStyle = 'rgba(220,188,124,.5)'; ctx.lineWidth = 2;
      ctx.strokeRect(ART.x, ART.y, ART.w, ART.h); ctx.setLineDash([]);
      ctx.fillStyle = 'rgba(220,188,124,.7)'; ctx.font = 'italic 500 44px "Cormorant Garamond", serif';
      ctx.textAlign = 'center'; ctx.fillText('Add artwork', ART.x + ART.w / 2, ART.y + ART.h / 2 + 12);
    }

    // character name (shrinks to fit)
    ctx.textAlign = 'left'; ctx.fillStyle = PARCH;
    let size = 92;
    const name = state.name || '';
    for (; size > 40; size -= 2) {
      ctx.font = `italic 500 ${size}px "Cormorant Garamond", serif`;
      if (ctx.measureText(name).width <= W - 2 * M) break;
    }
    ctx.fillText(name, M, 1082);

    // voice line (shrinks until it fits two lines; three at the smallest size)
    ctx.fillStyle = LILAC;
    let ls = 38, lines = [];
    for (; ls >= 26; ls -= 2) {
      ctx.font = `italic 500 ${ls}px "Cormorant Garamond", serif`;
      lines = wrapLines(ctx, state.line || '', W - 2 * M);
      if (lines.length <= 2) break;
    }
    lines.slice(0, 3).forEach((l, i) => ctx.fillText(l, M, 1136 + i * Math.round(ls * 1.3)));

    // footer
    ctx.strokeStyle = 'rgba(220,188,124,.30)'; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(M, 1236.5); ctx.lineTo(W - M, 1236.5); ctx.stroke();
    ctx.fillStyle = GOLD; ctx.font = '500 20px Cinzel, serif';
    spaced(ctx, (state.series || '').toUpperCase(), M, 1285, 5, 'left');
    spaced(ctx, state.handle || '', W - M, 1285, 3, 'right');

    document.getElementById('socDownload').disabled = !state.img;
    document.getElementById('socDownloadWm').disabled = !state.img;
  }
  function schedule() { cancelAnimationFrame(raf); raf = requestAnimationFrame(draw); }

  // ---------- downloads ----------
  function save(canvas, filename, quality) {
    canvas.toBlob(blob => {
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob); a.download = filename;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    }, 'image/jpeg', quality);
  }
  function downloadPost() {
    if (!state.img) return;
    draw();
    save(document.getElementById('socCanvas'), `${slug(state.name)}-post-1080x1350.jpg`, 0.92);
  }
  function downloadWatermarkedOnly() {
    if (!state.img) return;
    const maxSide = 4096;
    const k = Math.min(1, maxSide / Math.max(state.img.width, state.img.height));
    const w = Math.round(state.img.width * k), h = Math.round(state.img.height * k);
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const ctx = c.getContext('2d');
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(state.img, 0, 0, w, h);
    watermark(ctx, 0, 0, w, h);
    save(c, `${slug(state.name)}-watermarked.jpg`, 0.9);
  }

  // ---------- UI ----------
  function build(wrap) {
    wrap.innerHTML = `
      <style>
        #socLayout { display:grid; grid-template-columns:minmax(260px,370px) 1fr; gap:28px; align-items:start; }
        @media (max-width:900px) { #socLayout { grid-template-columns:1fr; } }
        #socCanvas { width:100%; max-width:540px; height:auto; aspect-ratio:4/5; border:1px solid var(--line); border-radius:4px; background:#0e0c16; touch-action:pan-y; display:block; }
        #socCanvas.can-drag { cursor:grab; } #socCanvas.dragging { cursor:grabbing; }
        .soc-btns { display:flex; gap:10px; flex-wrap:wrap; margin-top:6px; }
        .soc-btns button:disabled { opacity:.4; cursor:not-allowed; }
      </style>
      <h2 style="font-size:30px;margin-bottom:6px;">Social posts</h2>
      <p style="font-size:14px;color:var(--lilac-dim);max-width:640px;margin-bottom:22px;line-height:1.55;">
        Add a finished piece, fill in the text, and download a watermarked 1080 × 1350 post. Your original is processed in this browser only; nothing is uploaded or stored.</p>
      <div id="socLayout">
        <div>
          <div class="field"><label class="field-label" for="socFile">Artwork</label><input type="file" id="socFile" accept="image/*"></div>
          <div class="field"><label class="field-label" for="socZoom">Zoom</label><input type="range" id="socZoom" min="100" max="300" value="100" style="padding:0;"></div>
          <div class="field"><button class="btn-ghost" type="button" id="socReset" style="width:100%;">Reset position</button>
            <p style="font-size:12px;color:var(--lilac-dim);margin-top:6px;">Drag the preview to reposition the artwork inside the frame.</p></div>
          <div class="field"><label class="field-label" for="socLabel">Label</label>
            <input id="socLabel" list="socLabels" value="${esc(state.label)}">
            <datalist id="socLabels"><option value="CHARACTER PORTRAIT"><option value="ILLUSTRATED SCENE"><option value="COVER REVEAL"><option value="WORK IN PROGRESS"><option value="NEW COMMISSION"></datalist></div>
          <div class="field"><label class="field-label" for="socName">Character name</label><input id="socName" value="${esc(state.name)}"></div>
          <div class="field"><label class="field-label" for="socLine">Line from the book</label><textarea id="socLine" rows="3">${esc(state.line)}</textarea></div>
          <div class="field"><label class="field-label" for="socSeries">Series</label><input id="socSeries" value="${esc(state.series)}"></div>
          <div class="field"><label class="field-label" for="socHandle">Handle</label><input id="socHandle" value="${esc(state.handle)}"></div>
          <div class="soc-btns">
            <button class="btn" type="button" id="socDownload" disabled>Download post (JPG)</button>
            <button class="btn-ghost" type="button" id="socDownloadWm" disabled>Watermarked image only</button>
          </div>
          <p id="socMsg" style="font-size:13px;color:var(--lilac-dim);margin-top:10px;"></p>
        </div>
        <div>
          <canvas id="socCanvas" width="${W}" height="${H}" aria-label="Post preview"></canvas>
          <p style="font-size:12px;color:var(--lilac-dim);margin-top:8px;">Preview is the exact export (1080 × 1350 px, 65 px margins).</p>
        </div>
      </div>`;

    const bind = (id, key) => wrap.querySelector('#' + id).addEventListener('input', e => { state[key] = e.target.value; schedule(); });
    bind('socLabel', 'label'); bind('socName', 'name'); bind('socLine', 'line'); bind('socSeries', 'series'); bind('socHandle', 'handle');

    wrap.querySelector('#socZoom').addEventListener('input', e => { state.zoom = e.target.value / 100; schedule(); });
    wrap.querySelector('#socReset').addEventListener('click', () => {
      state.ox = 0; state.oy = 0; state.zoom = 1; wrap.querySelector('#socZoom').value = 100; schedule();
    });
    wrap.querySelector('#socDownload').addEventListener('click', downloadPost);
    wrap.querySelector('#socDownloadWm').addEventListener('click', downloadWatermarkedOnly);

    wrap.querySelector('#socFile').addEventListener('change', e => {
      const f = e.target.files && e.target.files[0];
      const msg = wrap.querySelector('#socMsg');
      if (!f) return;
      if (!f.type.startsWith('image/')) { msg.textContent = 'That file is not an image.'; return; }
      if (objectUrl) URL.revokeObjectURL(objectUrl);
      objectUrl = URL.createObjectURL(f);
      const img = new Image();
      img.onload = () => {
        state.img = img; state.ox = 0; state.oy = 0; state.zoom = 1;
        wrap.querySelector('#socZoom').value = 100;
        cv.classList.add('can-drag'); msg.textContent = '';
        schedule();
      };
      img.onerror = () => { msg.textContent = 'Could not read that image. Try a JPG or PNG.'; };
      img.src = objectUrl;
    });

    // drag to reposition
    const cv = wrap.querySelector('#socCanvas');
    let drag = null;
    cv.addEventListener('pointerdown', e => {
      if (!state.img) return;
      drag = { x: e.clientX, y: e.clientY, ox: state.ox, oy: state.oy };
      cv.setPointerCapture(e.pointerId); cv.classList.add('dragging');
    });
    cv.addEventListener('pointermove', e => {
      if (!drag) return;
      const k = W / cv.getBoundingClientRect().width;
      state.ox = drag.ox + (e.clientX - drag.x) * k;
      state.oy = drag.oy + (e.clientY - drag.y) * k;
      schedule();
    });
    const end = () => { drag = null; cv.classList.remove('dragging'); };
    cv.addEventListener('pointerup', end); cv.addEventListener('pointercancel', end);
  }

  window.renderSocialStudio = async function () {
    const wrap = document.getElementById('socialWrap');
    if (!wrap) return;
    if (!built) {
      wrap.innerHTML = '<p class="loading-msg">Loading…</p>';
      try {
        logo = await loadLogo();
        await Promise.all([
          document.fonts.load('500 20px Cinzel'), document.fonts.load('600 20px Cinzel'),
          document.fonts.load('italic 500 40px "Cormorant Garamond"'),
        ]).catch(() => {});
      } catch (err) {
        wrap.innerHTML = '<p class="empty">Could not load the logo (/images/crows-quill-logo.png).</p>'; return;
      }
      build(wrap); built = true;
    }
    schedule();
  };
})();
