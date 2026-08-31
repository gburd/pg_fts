# Pre-existing WAND recall gap on multi-term AND (found during 1.5.3 soak prep)

On a 2.19M Wikipedia-body index, the ranked scan of `slovakia & hungary`
(2-term AND) misses the true top-k:

  index top-10 exact scores: 19.907,19.716,...,18.900,17.683,15.914
  true  top-10 exact scores: 20.542,19.907,...,19.264,19.245

The index misses the true #1 (20.542) and admits two low docs (17.683, 15.914).

CRITICAL: this is PRESENT ON BOTH doclen_sidecar=on (v4) AND doclen_sidecar=off
(inline / v3 / 1.4.x scoring), IDENTICALLY (same genuine_misses=1@k10, same
exact_kth=19.245). So it is NOT a v4/sidecar regression -- it is a pre-existing
block-max WAND / MaxScore recall gap on multi-term AND that has been in the
engine since the 1.x line. Single-term ranked (slovakia/hungary/year) is exact
(genuine_misses=0) on both formats.

An earlier cross-session "inline passes AND" observation was confounded (it was
a different corpus on a different host); on identical data inline and sidecar
behave identically on AND.

Deferred as a separate investigation (multi-term WAND top-k exactness). It does
not gate the 1.5.3 sidecar validation: the task was whether v4 regresses vs the
proven inline path, and on AND they are identical (no regression).
