# sparsemap 5.8.4: the read cursor's gap resume trusts an unverified `prev_offset`

**Reported by:** pg_fts. Found by a CBMC proof, `pg_fts/test/cbmc/smcursor_harness.c`,
then reproduced natively.

**Affects:** sparsemap v5.8.4 (`sm.c` at 886ab07), chunk mode (not small-set mode). The
code was added in e509319, "a read cursor head-walked for every lookup in the gap before
the cached chunk".

**Severity:**
- **Wrong answer.** `sm_contains` returns the wrong membership for a cursor that the API
  contract calls invalid.
- **Contract mismatch.** The function's own comment says it self-validates against exactly
  this case, so the code does not do what it says.
- **Not observed in practice.** No wrong answer was seen through the public API in random
  testing (numbers below). pg_fts cannot reach this.

**Files** (this copy is pg_fts `bench/data_cbmc_2026-11-03/sparsemap_issue/`; the
working set with `sm.c` / `sm.h` copied in is `/tmp/smissue/`): every `.c` builds
against the upstream v5.8.4 `sm.c` / `sm.h` placed alongside it (`git show v5.8.4:sm.c`).
Each one's build line is at the top of the file.  The CBMC harness is pg_fts
`test/cbmc/smcursor_harness.c`.

---

## 1. The defect

`__sm_get_chunk_offset` (sm.c:2262) has two cursor fast paths. See sm.c:2296-2339 (excerpt
in `excerpt.txt`).

**First path: the cached chunk itself.** It validates the cursor's `offset` by checking
that the chunk header at that offset still holds `start_idx`:

```c
const __sm_idx_t at = __sm_load_idx(base + cur->offset);
if (at == cur->start_idx && idx >= cur->start_idx) { ... resume at the cached chunk ... }
```

This is a real check, because a chunk header stores its own start index.

**Second path, new in 5.8.4: idx precedes the cached chunk.** It resumes the walk at the
cursor's left-neighbour hint, `prev_offset`, and accepts that hint if it passes two checks:

```c
uint8_t *pp = base + cur->prev_offset;
__sm_chunk_init(&pc, pp + SM_SIZEOF_OVERHEAD);
if (idx >= __sm_load_idx(pp) &&
    cur->prev_offset + SM_SIZEOF_OVERHEAD + __sm_chunk_get_size(&pc) == cur->offset) {
	p = pp;            /* the walk starts here */
}
```

The two checks are:
- `idx >=` the 8 bytes at `prev_offset`, read as a start index;
- `prev_offset + 8 + chunk_size(the 8 bytes after those)` lands exactly on the cached
  chunk's offset.

Neither check establishes that `prev_offset` is a chunk boundary. Inside a chunk, the bytes
are bit-vector words. Read as a (start, descriptor) pair, they can satisfy both checks.
When that happens, the walk that follows begins mid-chunk:
- it interprets payload words as chunk headers;
- it can step to the wrong chunk;
- `sm_contains` then returns the wrong membership.

The comment above the check says *"Self-validate the cached offset before trusting it: a
prior mutation (a chunk shrinking to RLE, a leftward coalesce, a separate) can shift or
remove the cached chunk without the caller resetting."* That is true of `offset` (checked
against `start_idx`). It is not true of `prev_offset`, which nothing ties to the current
layout.

## 2. Reproduction (deterministic)

`repro_wrong_answer.c`:

```
cc -std=gnu99 -fsanitize=address,undefined -I. repro_wrong_answer.c -o r && ./r
```

The setup, in chunk mode (all indices >= SM_SMALL_MAX_BITS):
- The map has three adjacent chunks with one member each: 32773, 34821 and 38917. They
  sit at byte offsets 0, 24 and 48, each 24 bytes (start, descriptor, one vector).
- `sm_contains(m, 38479, &cur)` leaves the cursor at offset 48 (start 36864) with
  `prev_offset` 24. That is correct.
- The test then sets `prev_offset` to each multiple of 8 and looks up member 32773:

```
cursor after sm_contains(38479): offset=48 start_idx=36864 prev_offset=24
prev_offset= 0: sm_contains(32773) with cursor 1, without 1 -> agree
prev_offset= 8: sm_contains(32773) with cursor 1, without 1 -> agree
prev_offset=16: sm_contains(32773) with cursor 0, without 1 -> DIFFER
prev_offset=24: sm_contains(32773) with cursor 1, without 1 -> agree
...
exit=1
```

Hint 16 lands on chunk 0's bit-vector word, value 32 (bit 5 set for member +5). It passes
both checks:
- `idx 32773 >= 32`;
- the next word, at byte 24, is chunk 1's start index 34816. Read as a descriptor it gives
  a 24-byte chunk, so 16 + 8 + 24 = 48, which equals the cached offset.

The walk then starts at byte 16 and answers `false` for a member. ASan and UBSan report
nothing: every read stays inside the buffer, and only the answer is wrong. `why.c` prints
the bytes and each check's value for this case.

## 3. Reachability

**Is the hint ever a non-chunk-start in a correct API use?** Within one unmodified map, no.
`prev_offset` is only written in `__sm_get_chunk_offset`:
- as the offset of a chunk the forward walk passed; or
- as `cur->prev_offset`, carried over when the resume lands in the same chunk.

Both are chunk starts of that map. The CBMC proof C3 shows that for any hint that is a
chunk of the map (or SIZE_MAX), lookups through the cursor equal cursor-free lookups. It
covers 4 layouts and every index from a chunk before the map to past its end.

**After a mutation the cursor is kept, which `sm.h` calls undefined.** Here the hint does go
stale while `offset` and `start_idx` still validate:

- `stale_hint_api.c`: sm_add or sm_remove with the cursor not reset, in 300,000 random
  trials. The hint was no longer a chunk start in 24,168 of them. The lookups made after
  those trials gave 0 wrong answers.
- `stale_hint_search.c`: targets the shape above (a later chunk cached, an earlier chunk
  grown or shrunk), in 2,000,000 trials. 0 wrong answers.
- `stale_hint_mutation.c`: the hint also feeds `__sm_coalesce_chunk`'s `left_hint` through
  `__sm_map_set` (sm.c:5192) and `sm_add_grow_cursor`. A cursor was kept across
  sm_add/sm_remove and then used for `sm_add_grow_cursor`, in 300,000 trials. Results:
  `sm_validate` failed 0 times, and the contents differed from a bit-array oracle 0 times.
  That path re-checks the neighbour (`adj_offset < offset` and
  `adj_start + adj_length == start`), so a bad hint degrades to a slower walk or a
  rejected merge rather than corruption. CBMC did not prove this path; it was only tested.
- `grow_cursor_check.c`: the documented `sm_add_grow_cursor` pattern (cursor threaded,
  reset after a grow), in 20,000 sequences with 2.1M inserts. The hint was a non-chunk-start
  0 times, and there were 0 wrong answers.

**Summary of reachability:**
- Valid API use is fine.
- A cursor kept across a mutation (undefined per `sm.h`) can hold a bad hint. Random
  mutations did not produce bytes that also pass the resume checks.
- A hint of arbitrary value (memory corruption, or a cursor copied from another map) can
  fail on the first lookup.
- The comment overstates the self-validation either way.

**pg_fts is not affected.** Its tombstone and trigram maps are read-only while a cursor is
live. Its bulk-delete path resets its cursor after the last `sm_add_many_grow`.

## 4. Cheap plausibility checks do not close it

`plausibility_search.c` searched 200,000 random chunk-mode maps, checking every 8-byte
offset that is **not** a chunk start against every cached chunk after it.

| check | non-chunk hints that pass |
|---|---|
| v5.8.4's ("ends exactly at the cached offset") | 1,376,174 |
| plus: the start word is chunk-aligned (% 2048 == 0), below the cached start, and start + capacity <= cached start | 55,555 |

A bit-vector word with its low 11 bits clear looks like an aligned start, so alignment and
ordering checks narrow the problem but do not prove the hint is a chunk.

## 5. Suggested fixes (for the sparsemap team to choose)

1. **Record the neighbour's start index in the cursor and check it.** Add
   `uint64_t prev_start_idx` to `sm_cursor_t` and require
   `__sm_load_idx(base + prev_offset) == prev_start_idx`. This also needs the
   end-at-offset check, as `offset` has today. It makes the hint as trustworthy as the
   cached offset.
   - Cost: `sizeof(sm_cursor_t)` grows from 24 to 32 bytes, and `SM_CURSOR_INIT` gains a
     field. That is an ABI change for callers that allocate cursors, which every caller
     does, so it belongs in a minor release.
   - Even this only validates against the same class of staleness that `offset` survives.
     It is the strongest option short of a map mutation counter.
2. **A map mutation counter.** Store a per-map generation (bumped where
   `__sm_card_invalidate` runs) in the cursor and compare it. This makes every stale
   cursor detectable, for `offset` too. It grows both `sm_t` and `sm_cursor_t`, so it is
   also an ABI change.
3. **No ABI change.** Keep the 5.8.4 fast path but correct the documentation: say that
   `prev_offset` is trusted, and that a cursor kept across a mutation may give wrong
   answers, not merely be slower. Optionally add the section 4 plausibility checks to
   shrink the window. This is honest, but it leaves the defect in place.
4. **Revert the gap resume** to a head walk, as 5.8.3 did. This is correct but brings back
   the O(lookups x chunks) cost that e509319 fixed: 2,960 ms to 3.8 ms for 100,000 gap
   lookups over 20,000 chunks.

For option 1, the regression to add to `tests/test_cursor_gap.c` is
`repro_wrong_answer.c`'s loop: every `prev_offset` value, a lookup that must agree with
`sm_contains(m, x, NULL)`. With the fix, it should agree for every value.

## 6. The proof harness

`smcursor_harness.c` + `smcursor_layouts.h` (in pg_fts `test/cbmc/`; it builds against
`vendor/sm.c`, which equals upstream v5.8.4 plus a symbol-prefix block):

- `harness_ascending` (C1/C2) and `harness_any_cursor` (C3): verified with CBMC 6.6.0 on 4
  layouts (one member per chunk with gaps; adjacent chunks; a 2-chunk RLE run, a gap, then
  a sparse chunk; one chunk).
- `harness_stale_hint` (C3x): fails with the counterexample above.
- `mutate_sm.py` removes the neighbour check entirely. C3 must then fail, and it does.

Run, from pg_fts:
`cbmc smcursor_harness.c -I../../vendor -DLAYOUT=1 --function harness_stale_hint --unwind 40 --unwindset layout_map.0:260 --unwinding-assertions --object-bits 12`.
It finishes in about 30 s.
