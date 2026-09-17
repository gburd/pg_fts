# Should the SIMD work go in sparsemap?

**Date:** 2026-09-14 · **Analysis only — no code changed.**
Follows `bench/NOTE_TIN_FEASIBILITY_2026-09-14.md`.

## Answer: no, and the strongest argument is our own history

Four reasons, each checkable against the tree.

### 1. sparsemap is not on the path we are slow on

Every `sm_*` call in pg_fts serves one of two subsystems:

| subsystem | what the map holds |
|---|---|
| tombstones (`livedocs`) | which docids are deleted, per segment |
| trigram index | which docids contain a term matching a trigram |

**Postings are not sparsemaps.** The hot path TIN's bitmaps accelerate — per-term docid
lists, intersected and unioned to answer a query — is our FOR delta-packed posting format,
which never touches sparsemap.

And the profiles agree: grepping `NOTE_PROFILE_COMMON_TERM`, `PROFILE_STEP0` and
`NOTE_PHRASE_PROFILE` for `sm_`/`sparsemap`/`__sm_` returns **nothing**. sparsemap has never
appeared as a query hotspot. Our measured breakdown is 45% doclen path + 37% candidate
iteration, neither of which is sparsemap. Vectorizing it would speed up tombstone lookups
and trigram funnels — not the queries we lose on.

### 2. The one time sparsemap *was* the bottleneck, SIMD was the wrong fix

The 1.6.1 P0: `VACUUM` never completed, **99.75% of samples in `__sm_get_chunk_offset`**,
4h39m of CPU. That is as strong a hotspot signal as this project has ever produced.

The fix was **algorithmic** — decode the read-only tombstone map **once** into a dense
bitmap, then O(1) lookups — taking it to **393 s**. Vectorizing `__sm_get_chunk_offset`
would have optimised a chunk-chain walk that the real fix *deleted*.

That is the durable lesson: sparsemap's cost is pointer-chasing through a compressed
variable-length chunk chain, and the answer to pointer-chasing is to stop doing it, not to
do it with wider registers.

### 3. Its representation is close to SIMD-hostile, by design

From `vendor/sm.h`: a descriptor word carries **2-bit flags** for up to 32 bit-vectors;
uniform vectors are **not stored at all** (represented by their flag); only mixed vectors
follow the descriptor; and whole chunks may instead be **RLE** (a 64-bit descriptor encoding
capacity + run length).

SIMD wants flat, aligned, fixed-size data. You cannot load "256 bits of the bitmap" into a
register here because the bitmap is not laid out that way — the bits are implied by flags,
elided, or run-length encoded. That compression is exactly why sparsemap is a good fit for
sparse tombstones, and exactly why it is a bad vectorization target.

**TIN's bitmaps are SIMD-friendly precisely because they are uncompressed and fixed-size**:
a 256-bit page-level bitmap that fits one AVX2 register, plus small fixed offset bitmaps.
Compression and vectorization are in tension, and the two designs sit on opposite sides of
it deliberately.

### 4. It would end a vendoring arrangement that keeps paying

`vendor/sm.c` is upstream 5.5.1 plus an 8-line prefix block; `vendor/sm.h` is
**byte-identical** to upstream. That discipline made 5.4.0 → 5.5.0 → 5.5.1 mechanical, and
those upgrades delivered fixes we actually depend on — big-endian chunk-descriptor reads
(we call `sm_next_member`) and `__sm_append_data` returning `bool`, which our
`sm_add_many_grow` grow-retry relies on for ENOSPC.

Adding intrinsics to `vendor/sm.c` converts every future upstream release into a merge
against our vectorized fork. That is a permanent maintenance cost, taken on for a subsystem
that has never shown up in a query profile. If sparsemap should be vectorized, the venue is
**upstream**, where its authors can weigh portability for all their users — not our vendor
copy.

## Where a SIMD-friendly structure *would* pay, if we ever build one

Not by replacing sparsemap, but by adding a **dense bitmap** where density is already
established:

- **The dense tombstone bitmap already exists.** The P0 fix builds one per merge source
  (`src->tombdense`, sized by `sm_maximum`). It is flat, aligned and word-addressable —
  i.e. already the right shape. If tombstone filtering ever became hot, that structure,
  not sparsemap, is what one would vectorize, and it is our own code.
- **Page-level posting bitmaps** (TIN's actual advantage) would be a *new* sidecar
  alongside the delta postings, per the 1.5.0 dual-read precedent — again our code, not
  sparsemap's.

Both keep the vendored library untouched and put any intrinsics in files we own, behind the
runtime-dispatch and scalar-fallback infrastructure that item D in the feasibility note says
we would have to build first.

## Recommendation

**Do not vectorize sparsemap.** Keep it byte-identical to upstream and keep taking its
fixes. If SIMD work is ever authorised, it belongs in pg_fts-owned dense structures on the
posting path, which is where the measured 45%/37% actually sits — and it should still be
justified by our own profile rather than by TIN's unreproducible numbers.
