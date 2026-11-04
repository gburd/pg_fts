/*-------------------------------------------------------------------------
 *
 * shdoclen_harness.c
 *		CBMC bounded model check of the shared doclen slot protocol
 *		(pg_fts_shdoclen.c, 1.10.0, ROADMAP I6): one control table under
 *		an LWLock, slots FREE -> BUILDING -> READY, a reference count per
 *		scan, retirement when a segment is dropped, eviction of unreferenced
 *		copies, and payload unpins done AFTER the lock is released.
 *
 *	INVARIANTS PROVED, over every interleaving of the actors below:
 *	  S1  no use after free: a scan that holds a reference on a copy never
 *	      sees that copy's payload unpinned before it drops the reference;
 *	  S2  no double unpin: every payload is unpinned at most once;
 *	  S3  no leak at quiescence: when every actor has finished, a payload
 *	      is pinned only if its slot still lists it as READY (a later
 *	      shdl_get or shdl_retire_segment can reclaim it);
 *	  S4  the reference count never goes negative and is exactly the
 *	      number of scans holding the copy.
 *
 *	WHAT IS MODELLED: the slot fields the protocol reads (state, retired,
 *	refcnt, handle) and the five transitions of pg_fts_shdoclen.c, each a
 *	critical section under the control lock exactly as the source takes
 *	it: shdl_get's lookup/claim (taking a reference, or claiming a slot to
 *	build), the builder's publish (BUILDING -> READY with refcnt 1, or
 *	FREE if the build failed), shdl_unref_slot (drop a reference, never
 *	unpin), shdl_retire_segment (free an unreferenced copy, otherwise mark
 *	it retired) and shdl_claim_slot's eviction (free an unreferenced READY
 *	copy, retired first).  The payload is a pinned/unpinned flag per
 *	handle; dsm_unpin_segment is "set unpinned", called outside the lock
 *	as the source does (shdl_unpin after LWLockRelease).  The control lock
 *	is a CAS spinlock with a bounded spin (assume-away beyond it, as
 *	libxtc's refcount harness does); DSM, the key comparison and the
 *	resource-owner callback are not modelled (a reference is dropped by
 *	the same actor that took it, which is what the callback guarantees).
 *	If the transitions in pg_fts_shdoclen.c change, this must change with
 *	them.
 *
 *	BOUND: one slot, three actors: a scan that builds or attaches and
 *	then releases, a second scan doing the same (the main thread), and a
 *	merge that retires the segment and may then evict it (another
 *	segment's shdl_get).  Every interleaving of their critical sections
 *	and unlocked unpins; S3 and S4 are checked once all three are done.
 *
 *	TEETH: -DTEETH_RETIRE_REFD frees a referenced copy at retire (the
 *	"retired" flag skipped): S1 must fail.  -DTEETH_UNREF_UNPINS unpins in
 *	shdl_unref_slot for the last reader of a retired copy while another
 *	path also reclaims it: S2 must fail.
 *
 *	Run: cbmc shdoclen_harness.c --unwind 4 (see run.sh)
 *
 * IDENTIFICATION
 *	  test/cbmc/shdoclen_harness.c
 *
 *-------------------------------------------------------------------------
 */
#include <stdbool.h>
#include <stdint.h>

int			nondet_int(void);
bool		nondet_bool(void);

#define SHDL_FREE 0
#define SHDL_BUILDING 1
#define SHDL_READY 2
#define NHANDLES 4				/* handles 1..3; 0 = DSM_HANDLE_INVALID */

/* the slot (BM25ShDoclenSlot) */
static int	s_state;
static int	s_handle;
static int	s_refcnt;
static bool s_retired;
static int	s_builder;			/* actor id while BUILDING */

/* payloads: pinned[h], and how many times each was unpinned */
static bool pinned[NHANDLES];
static int	unpins[NHANDLES];
static int	next_handle = 1;

/* per scan actor: the handle it holds a reference on (0 = none) */
static int	holds[3];

/* the control lock */
static int	lock;
#define SPINS 3
static void
lock_acquire(void)
{
	int			i;

	for (i = 0; i < SPINS; i++)
	{
		bool		got;

		__CPROVER_atomic_begin();
		got = (lock == 0);
		lock = 1;				/* a no-op when it was already held */
		__CPROVER_atomic_end();
		if (got)
			return;
	}
	__CPROVER_assume(0);		/* deeper contention than modelled */
}
static void
lock_release(void)
{
	__CPROVER_atomic_begin();
	lock = 0;
	__CPROVER_atomic_end();
}

/* dsm_unpin_segment: outside the lock (shdl_unpin) */
static void
unpin(int h)
{
	if (h == 0)
		return;
	__CPROVER_atomic_begin();
	__CPROVER_assert(unpins[h] == 0, "S2: a payload is unpinned at most once");
	unpins[h]++;
	pinned[h] = false;
	__CPROVER_atomic_end();
}

/* shdl_free_slot: lock held, refcnt == 0; returns the handle to unpin */
static int
free_slot(void)
{
	int			h = s_handle;

	s_state = SHDL_FREE;
	s_retired = false;
	s_handle = 0;
	s_refcnt = 0;
	return h;
}

/* a scan: shdl_get (attach or build+publish), use the copy, release */
static void
scan(int me)
{
	int			h = 0;
	bool		mine = false;
	int			evicted = 0;

	lock_acquire();
	if (s_state != SHDL_FREE && !s_retired)
	{
		if (s_state != SHDL_READY)
		{
			lock_release();		/* another backend is building: go private */
			return;
		}
		h = s_handle;
		s_refcnt++;				/* take the reference under the lock */
	}
	else
	{
		/* shdl_claim_slot: free, or an unreferenced READY (retired first) */
		if (s_state == SHDL_FREE)
			mine = true;
		else if (s_state == SHDL_READY && s_refcnt == 0)
		{
			evicted = free_slot();
			mine = true;
		}
		if (mine)
		{
			s_state = SHDL_BUILDING;
			s_builder = me;
			s_refcnt = 0;
			s_retired = false;
		}
	}
	lock_release();
	unpin(evicted);				/* shdl_unpin(evicted), outside the lock */
	if (!h && !mine)
		return;					/* every slot in use: private path */

	if (mine)
	{
		/* build privately, publish into a new pinned payload (may fail) */
		bool		built = nondet_bool();
		int			nh = 0;

		if (built)
		{
			__CPROVER_atomic_begin();
			nh = next_handle++;
			pinned[nh] = true;
			__CPROVER_atomic_end();
		}
		lock_acquire();
		if (nh)
		{
			/* READY even if retired meanwhile: this scan holds the only ref */
			s_state = SHDL_READY;
			s_handle = nh;
			s_refcnt = 1;
		}
		else
			s_state = SHDL_FREE;
		lock_release();
		if (!nh)
			return;
		h = nh;
	}
	holds[me] = h;

	/* use the copy: it must still be pinned */
	__CPROVER_assert(pinned[h], "S1: a held copy is pinned (no use after free)");

	/* shdl_unref_slot: drop the reference under the lock, never unpin */
	lock_acquire();
	if (s_state == SHDL_READY && s_handle == h && s_refcnt > 0)
		s_refcnt--;
#ifdef TEETH_UNREF_UNPINS
	{
		int			last = (s_state == SHDL_READY && s_handle == h &&
							s_refcnt == 0 && s_retired) ? free_slot() : 0;

		lock_release();
		holds[me] = 0;
		unpin(last);
		unpin(last ? h : 0);	/* and the payload again: the double free */
		return;
	}
#endif
	holds[me] = 0;
	lock_release();
}

/* a merge dropping the segment: shdl_retire_segment */
static void
retire(void)
{
	int			freed = 0;

	lock_acquire();
	if (s_state == SHDL_READY && s_retired && s_refcnt == 0)
		freed = free_slot();	/* left by its last reader */
	else if (s_state != SHDL_FREE)
	{
#ifndef TEETH_RETIRE_REFD
		if (s_state == SHDL_READY && s_refcnt == 0)
			freed = free_slot();
		else
			s_retired = true;	/* BUILDING, or READY with readers */
#else
		if (s_state == SHDL_READY)
			freed = free_slot();	/* mutant: ignores readers */
		else
			s_retired = true;
#endif
	}
	lock_release();
	unpin(freed);
}

/* another segment's shdl_get evicting this slot via shdl_claim_slot */
static void
evict(void)
{
	int			evicted = 0;

	lock_acquire();
	if (s_state == SHDL_READY && s_refcnt == 0)
		evicted = free_slot();
	lock_release();
	unpin(evicted);
}

static bool done[3];

static void
merge_thread(void)
{
	retire();
	if (nondet_bool())
		evict();
	__CPROVER_atomic_begin();
	done[2] = true;
	__CPROVER_atomic_end();
}

static void
scan_thread(int me)
{
	scan(me);
	__CPROVER_atomic_begin();
	done[me] = true;
	__CPROVER_atomic_end();
}

int
main(void)
{
	int			h;

	s_state = SHDL_FREE;
	s_handle = 0;
	s_refcnt = 0;
	s_retired = false;
	lock = 0;
	for (h = 0; h < NHANDLES; h++)
	{
		pinned[h] = false;
		unpins[h] = 0;
	}
	holds[0] = holds[1] = holds[2] = 0;
	done[0] = done[1] = done[2] = false;

__CPROVER_ASYNC_1:
	scan_thread(1);
__CPROVER_ASYNC_2:
	merge_thread();
	scan(2);

	/* S3 and S4 are about quiescence: join the other two actors (each sets
	 * its done flag as its last step, after any unlocked unpin) */
	__CPROVER_assume(done[1] && done[2]);
	__CPROVER_assert(s_refcnt >= 0, "S4: refcnt never negative");
	__CPROVER_assert(s_refcnt == (holds[1] != 0) + (holds[2] != 0),
					 "S4: refcnt == scans holding the copy");
	/* S3: a pinned payload is reachable from the slot */
	for (h = 1; h < NHANDLES; h++)
		if (pinned[h])
			__CPROVER_assert(s_state == SHDL_READY && s_handle == h,
							 "S3: a pinned payload is still listed READY");
	return 0;
}
