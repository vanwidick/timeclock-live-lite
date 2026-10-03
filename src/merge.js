/* TimeClock sync merge (keep identical to pc/TimeClockSync.ps1 Merge-Punches3).
   punches = {"yyyy-MM-dd":[[kind,sec],...]}. 3-way merge per date against the last synced base:
   a day changed on one side only -> that side wins verbatim; changed on both -> multiset merge
   (additions from both kept once, a removal on either side wins), then stable-sorted by seconds. */
function tcMerge3(base, a, b) {
  base = base || {}; a = a || {}; b = b || {};
  const key = e => e[0] + ":" + e[1];
  const eq = (x, y) => { x = x || []; y = y || []; if (x.length !== y.length) return false; for (let i = 0; i < x.length; i++) if (x[i][0] !== y[i][0] || x[i][1] !== y[i][1]) return false; return true; };
  const cnt = l => { const m = new Map(); for (const e of l || []) m.set(key(e), (m.get(key(e)) || 0) + 1); return m; };
  const out = {};
  const days = Array.from(new Set([...Object.keys(base), ...Object.keys(a), ...Object.keys(b)])).sort();
  for (const d of days) {
    const B = base[d] || [], A = a[d] || [], C = b[d] || [];
    let r;
    if (eq(A, B)) r = C; else if (eq(C, B)) r = A; else if (eq(A, C)) r = A;
    else {
      const cB = cnt(B), cA = cnt(A), cC = cnt(C), order = [], seen = new Set(), items = new Map();
      for (const e of [...A, ...C, ...B]) { const k = key(e); if (!seen.has(k)) { seen.add(k); order.push(k); items.set(k, [String(e[0]), e[1] | 0]); } }
      r = [];
      for (const k of order) {
        const nb = cB.get(k) || 0, dA = (cA.get(k) || 0) - nb, dC = (cC.get(k) || 0) - nb;
        let n = (dA > 0 && dC > 0) ? nb + Math.max(dA, dC) : (dA < 0 && dC < 0) ? nb + Math.min(dA, dC) : nb + dA + dC;
        for (let i = 0; i < n; i++) r.push(items.get(k).slice());
      }
      r = r.map((e, i) => [e, i]).sort((x, y) => x[0][1] - y[0][1] || x[1] - y[1]).map(x => x[0]);
    }
    if (r && r.length) out[d] = r.map(e => [String(e[0]), e[1] | 0]);
  }
  return out;
}
/* At most 2 breaks a day. A 3rd+ "bs" is dropped; if no break was open it is dropped together with the "be" that closes it
   (if a break was still open, e.g. break 2 started on both devices, that "be" still ends the open break and is kept). */
function tcLimitBreaks(P) { const out = {};
  for (const d of Object.keys(P || {})) { let n = 0, open = false, skipBe = false; const l = [];
    for (const e of P[d]) { const k = e[0];
      if (k === "bs") { n++; if (n > 2) { if (!open) skipBe = true; continue; } open = true; skipBe = false; }
      else if (k === "be") { if (skipBe) { skipBe = false; continue; } open = false; }
      else { open = false; skipBe = false; }
      l.push([k, e[1] | 0]); }
    if (l.length) out[d] = l; }
  return out; }
function tcPunchJson(P) { const ks = Object.keys(P).filter(k => P[k] && P[k].length).sort();
  return "{" + ks.map(k => JSON.stringify(k) + ":[" + P[k].map(e => `[${JSON.stringify(e[0])},${e[1] | 0}]`).join(",") + "]").join(",") + "}"; }
if (typeof module !== "undefined") module.exports = { tcMerge3, tcLimitBreaks, tcPunchJson };
