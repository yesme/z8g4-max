// Acceptance test for storage-sequential-fill.patch. Dockerfile.storage
// copies this file into the patched bb-storage tree and runs it before
// building the binary, so the image cannot be built from a tree in
// which the Chunk Storage still opens its "current" blocks for writing.
package z8_test

import (
	"fmt"
	"testing"

	"github.com/buildbarn/bb-storage/pkg/blobstore/configuration"
	"github.com/buildbarn/bb-storage/pkg/blobstore/local"
	"github.com/buildbarn/bb-storage/pkg/digest"
)

// Geometry of the middle cold shard of a disk, as set in
// tiered-cache.jsonnet. Blobs in this test are one byte, so a block
// holds blockSize of them.
const (
	oldBlocks     = 22
	currentBlocks = 65
	newBlocks     = 3
	ringBlocks    = oldBlocks + currentBlocks + newBlocks
	blockSize     = 56
)

// The eight shards of a disk split the same 87 blocks differently
// between old and current, so that they refresh a batch of objects at
// different times.
var staggeredOldBlocks = []int{14, 16, 18, 20, 22, 24, 26, 28}

// blockList is a BlockList that only tracks how full every block is.
type blockList struct {
	used           []int64
	pushed, popped int
}

func (bl *blockList) BlockReferenceToBlockIndex(local.BlockReference) (int, uint64, bool) {
	return 0, 0, false
}

func (bl *blockList) BlockIndexToBlockReference(int) (local.BlockReference, uint64) {
	return local.BlockReference{}, 0
}

func (bl *blockList) PopFront() {
	bl.used = bl.used[1:]
	bl.popped++
}

func (bl *blockList) PushBack() error {
	bl.used = append(bl.used, 0)
	bl.pushed++
	return nil
}

func (bl *blockList) Get(int, digest.Digest, int64, int64) ([]byte, error) {
	return nil, nil
}

func (bl *blockList) HasSpace(blockIndex int, sizeBytes int64) bool {
	return bl.used[blockIndex]+sizeBytes <= blockSize
}

func (bl *blockList) Put(blockIndex int, sizeBytes int64) local.BlockListPutWriter {
	offsetBytes := bl.used[blockIndex]
	bl.used[blockIndex] += sizeBytes
	return func([]byte) local.BlockListPutFinalizer {
		return func() (int64, error) { return offsetBytes, nil }
	}
}

// writable returns the number of blocks that can still take a blob.
// On dm-zoned each of them keeps a partially filled zone in the cache.
func (bl *blockList) writable() int {
	n := 0
	for _, used := range bl.used {
		if used < blockSize {
			n++
		}
	}
	return n
}

type store struct {
	t      *testing.T
	blocks *blockList
	lbm    *local.OldCurrentNewLocationBlobMap
	errors int
}

func (s *store) Log(error) { s.errors++ }

// newStore creates a store whose BlockList already holds the given
// blocks, the way a restart restores them from the persistent state.
func newStore(t *testing.T, policy local.BlockListGrowthPolicy, restored ...int64) *store {
	s := &store{t: t, blocks: &blockList{used: restored}}
	s.lbm = local.NewOldCurrentNewLocationBlobMap(s.blocks, policy, s, t.Name(), blockSize, oldBlocks, newBlocks, len(restored))
	return s
}

// put stores one blob and returns the index of the block it went to.
func (s *store) put() int {
	s.t.Helper()
	writer, err := s.lbm.Put(1)
	if err != nil {
		s.t.Fatal(err)
	}
	location, err := writer(nil)()
	if err != nil {
		s.t.Fatal(err)
	}
	return location.BlockIndex
}

// fill stores the given number of blocks' worth of blobs. With
// maximumWritable set it fails as soon as more blocks than that are
// writable at the same time.
func (s *store) fill(blocks, maximumWritable int) {
	s.t.Helper()
	for i := 0; i < blocks*blockSize; i++ {
		s.put()
		if n := s.blocks.writable(); maximumWritable > 0 && n > maximumWritable {
			s.t.Fatalf("%d blocks are writable after %d more blobs, want at most %d", n, i+1, maximumWritable)
		}
		if n := len(s.blocks.used); n > ringBlocks {
			s.t.Fatalf("Store holds %d blocks, want at most %d", n, ringBlocks)
		}
	}
}

func (s *store) needsRefresh(blockIndex int) bool {
	_, needsRefresh := s.lbm.Get(local.Location{BlockIndex: blockIndex, SizeBytes: 1})
	return needsRefresh
}

// reportCorruption does what FlatBlobAccess does when the blob at the
// given block fails its checksum.
func (s *store) reportCorruption(blockIndex int) {
	getter, _ := s.lbm.Get(local.Location{BlockIndex: blockIndex, SizeBytes: 1})
	_, integrityErrorCallback, _ := getter(digest.BadDigest)
	integrityErrorCallback()
}

func (s *store) expect(what string, got, want int) {
	s.t.Helper()
	if got != want {
		s.t.Errorf("%s: got %d, want %d", what, got, want)
	}
}

// chunkStoragePolicy returns the policy bb_storage gives to a local
// Chunk Storage backend. This is the wiring the patch changes.
func chunkStoragePolicy(t *testing.T) local.BlockListGrowthPolicy {
	policy, err := configuration.NewCSBlobAccessCreator(nil, 0).NewBlockListGrowthPolicy(currentBlocks, newBlocks)
	if err != nil {
		t.Fatal(err)
	}
	return policy
}

func upstreamPolicy() local.BlockListGrowthPolicy {
	return local.NewImmutableBlockListGrowthPolicy(currentBlocks, newBlocks)
}

// restoredBlocks returns the fill levels of a store that was stopped
// after it had filled the given number of blocks.
func restoredBlocks(full int) []int64 {
	var used []int64
	for i := 0; i < full; i++ {
		used = append(used, blockSize)
	}
	return append(used, 24, 8, 0)
}

func TestFirstFillWritesOnlyToNewBlocks(t *testing.T) {
	s := newStore(t, chunkStoragePolicy(t))

	// The first blobs go to the three "new" blocks in the 4:2:1
	// ratio that a full store uses.
	var got [newBlocks]int
	for i := 0; i < 7; i++ {
		got[s.put()]++
	}
	if got != [...]int{4, 2, 1} {
		t.Errorf("First seven blobs were spread %v over the new blocks, want [4 2 1]", got)
	}
	s.expect("blocks opened by the first blobs", s.blocks.pushed, newBlocks)

	// While the "current" group fills up, no block is "old" yet.
	s.fill(currentBlocks, newBlocks)
	if s.needsRefresh(0) {
		t.Error("Oldest block needs a refresh before the store has any old block")
	}
	s.expect("blocks released during the first fill", s.blocks.popped, 0)

	// Three more turns of the ring never need more than the three
	// "new" blocks.
	s.fill(3*ringBlocks, newBlocks)
	s.expect("blocks in the full store", len(s.blocks.used), ringBlocks)
	if !s.needsRefresh(oldBlocks-1) || s.needsRefresh(oldBlocks) {
		t.Errorf("Refresh boundary is not at block %d", oldBlocks)
	}
}

// The behaviour the patch removes. If this test starts to fail,
// upstream has changed its first fill and the patch needs a new look.
func TestUpstreamFirstFillOpensEveryCurrentBlock(t *testing.T) {
	s := newStore(t, upstreamPolicy())
	s.put()
	s.expect("blocks opened by the first blob", s.blocks.pushed, currentBlocks+newBlocks)
	s.expect("writable blocks", s.blocks.writable(), currentBlocks+newBlocks)
}

func TestFullStoreRotatesLikeUpstream(t *testing.T) {
	patched := newStore(t, chunkStoragePolicy(t))
	upstream := newStore(t, upstreamPolicy())
	patched.fill(3*ringBlocks, 0)
	upstream.fill(3*ringBlocks, 0)

	// From here on both policies answer every question the same
	// way. The stores keep the same number of blocks, write to at
	// most three of them, and open and release blocks at the same
	// rate. The moment of a rotation may differ by a few blobs,
	// because the two first fills left the new blocks filled to
	// slightly different levels.
	for i := 0; i < ringBlocks*blockSize; i++ {
		patched.put()
		upstream.put()
		for name, s := range map[string]*store{"patched": patched, "upstream": upstream} {
			if n := s.blocks.writable(); n > newBlocks {
				t.Fatalf("%s store has %d writable blocks", name, n)
			}
			if n := len(s.blocks.used); n != ringBlocks {
				t.Fatalf("%s store holds %d blocks", name, n)
			}
		}
		if d := patched.blocks.pushed - upstream.blocks.pushed; d < -1 || d > 1 {
			t.Fatalf("After %d blobs the patched store opened %d blocks, upstream %d",
				i+1, patched.blocks.pushed, upstream.blocks.pushed)
		}
	}
	for _, s := range []*store{patched, upstream} {
		if !s.needsRefresh(oldBlocks-1) || s.needsRefresh(oldBlocks) {
			t.Errorf("Refresh boundary is not at block %d", oldBlocks)
		}
	}
}

func TestRestartDuringFirstFillKeepsThreeWritableBlocks(t *testing.T) {
	// Thirty blocks restored: 27 full and the three that were being
	// written.
	s := newStore(t, chunkStoragePolicy(t), restoredBlocks(27)...)
	if s.needsRefresh(0) {
		t.Error("Oldest restored block became old, while the current group has room for it")
	}
	s.fill(currentBlocks, newBlocks)
	s.expect("blocks opened after the restart", s.blocks.pushed, currentBlocks)

	// Upstream opens fresh blocks until current + new are writable
	// again.
	u := newStore(t, upstreamPolicy(), restoredBlocks(27)...)
	u.put()
	u.expect("blocks opened by upstream after the restart", u.blocks.pushed, currentBlocks+newBlocks-30)
}

func TestRestartOfFullStore(t *testing.T) {
	s := newStore(t, chunkStoragePolicy(t), restoredBlocks(ringBlocks-newBlocks)...)
	if !s.needsRefresh(oldBlocks-1) || s.needsRefresh(oldBlocks) {
		t.Errorf("Refresh boundary is not at block %d", oldBlocks)
	}
	s.put()
	s.expect("blocks opened by the first blob", s.blocks.pushed, 0)
	s.fill(ringBlocks, newBlocks)
	s.expect("blocks in the store", len(s.blocks.used), ringBlocks)
}

func TestCorruptCurrentBlockDoesNotReopenCurrentBlocks(t *testing.T) {
	// Block 50 is a "current" block. Reporting it releases the 22
	// old blocks and the 29 oldest current blocks.
	const corrupt, lostCurrent = 50, 50 + 1 - oldBlocks

	s := newStore(t, chunkStoragePolicy(t), restoredBlocks(ringBlocks-newBlocks)...)
	s.reportCorruption(corrupt)
	s.expect("integrity errors logged", s.errors, 1)
	s.put()
	s.expect("blocks released", s.blocks.popped, corrupt+1)
	s.expect("blocks opened", s.blocks.pushed, 0)

	// The store grows back to its full size through the three "new"
	// blocks alone.
	s.fill(ringBlocks, newBlocks)
	s.expect("blocks in the store", len(s.blocks.used), ringBlocks)

	// Upstream replaces every lost current block with a writable one.
	u := newStore(t, upstreamPolicy(), restoredBlocks(ringBlocks-newBlocks)...)
	u.fill(1, 0)
	opened := u.blocks.pushed
	u.reportCorruption(corrupt)
	u.put()
	u.expect("blocks opened by upstream", u.blocks.pushed-opened, lostCurrent)
}

func TestEveryConfiguredSplitWritesThreeBlocks(t *testing.T) {
	for _, old := range staggeredOldBlocks {
		current := ringBlocks - newBlocks - old
		policy, err := configuration.NewCSBlobAccessCreator(nil, 0).NewBlockListGrowthPolicy(current, newBlocks)
		if err != nil {
			t.Fatal(err)
		}
		open := func(name string, restored ...int64) *store {
			s := &store{t: t, blocks: &blockList{used: restored}}
			s.lbm = local.NewOldCurrentNewLocationBlobMap(s.blocks, policy, s, fmt.Sprintf("%s/%d/%s", t.Name(), old, name), blockSize, old, newBlocks, len(restored))
			return s
		}
		atOld := func(s *store) bool { return s.needsRefresh(old-1) && !s.needsRefresh(old) }

		s := open("empty")
		s.fill(2*ringBlocks, newBlocks)
		s.expect("blocks in the full store", len(s.blocks.used), ringBlocks)
		if !atOld(s) {
			t.Errorf("old=%d: refresh boundary is not at block %d after the first fill", old, old)
		}

		r := open("restart", restoredBlocks(ringBlocks-newBlocks)...)
		if !atOld(r) {
			t.Errorf("old=%d: refresh boundary is not at block %d after a restart", old, old)
		}
		r.put()
		r.expect("blocks released by a restart", r.blocks.popped, 0)
		r.expect("blocks opened by a restart", r.blocks.pushed, 0)
		r.fill(ringBlocks, newBlocks)
		r.expect("blocks in the restarted store", len(r.blocks.used), ringBlocks)
	}
}
