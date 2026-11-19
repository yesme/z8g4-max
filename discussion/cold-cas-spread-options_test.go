// Experiments behind discussion/cold-cas-spread-options.md. They are not part
// of the kit or of the image build.
//
// To run them, apply z8-kit/buildbarn/storage-sequential-fill.patch and
// discussion/cold-cas-spread-options-experiment.diff to bb-storage ca3d8b49a5,
// copy this file, cold-cas-refresh-sim_test.go and
// z8-kit/buildbarn/storage-sequential-fill_test.go into z8/, and run:
//
//	go test ./z8/ -run 'TestOption' -v
//	Z8_WEIGHTS=capped go test ./z8/ -run 'TestOptionNewBlocks|TestOptionStaggeredOld' -v
//	Z8_WEIGHTS=equal  go test ./z8/ -run TestOptionNewBlocks -v
package z8_test

import (
	"fmt"
	"os"
	"testing"

	"github.com/buildbarn/bb-storage/pkg/blobstore/local"
)

// writableLimit is option 1: a growth policy with one number, the most blocks
// that may be writable while the store has fewer current blocks than
// configured. Three is the kit's patch, current + new is upstream.
type writableLimit struct {
	writable int
	variant  string // "", "current-never" or "current-full"
}

func (p writableLimit) ShouldGrowNewBlocks(current, new int) bool {
	return new < newBlocks || (new < p.writable && current+new < currentBlocks+newBlocks)
}

func (p writableLimit) ShouldGrowCurrentBlocks(current int) bool {
	switch p.variant {
	case "current-never":
		return false
	case "current-full":
		return current < currentBlocks
	}
	// The extra writable blocks become current blocks once they are full.
	return current < currentBlocks-(p.writable-newBlocks)
}

type outcome struct {
	maxWritable, maxBlocks, releasedByFirstPut, finalBlocks int
	refreshBoundaryAtOld                                    bool
}

func runScenario(t *testing.T, p local.BlockListGrowthPolicy, restored []int64, corrupt, blocksToWrite int) outcome {
	s := newStore(t, p, restored...)
	var o outcome
	if corrupt >= 0 {
		s.reportCorruption(corrupt)
	}
	for i := 0; i < blocksToWrite*blockSize; i++ {
		s.put()
		if i == 0 {
			o.releasedByFirstPut = s.blocks.popped
		}
		o.maxWritable = max(o.maxWritable, s.blocks.writable())
		o.maxBlocks = max(o.maxBlocks, len(s.blocks.used))
	}
	o.finalBlocks = len(s.blocks.used)
	o.refreshBoundaryAtOld = len(s.blocks.used) > oldBlocks && s.needsRefresh(oldBlocks-1) && !s.needsRefresh(oldBlocks)
	return o
}

// Option 1 on first fill, restarts and corruption, and two ways of getting
// the restart wrong.
func TestOptionWritableLimit(t *testing.T) {
	full := func() []int64 { return restoredBlocks(ringBlocks - newBlocks) }
	for _, w := range []int{3, 5, 8, 68} {
		fmt.Printf("writable=%d\n", w)
		fmt.Printf("  first fill, 3 turns:      %+v\n", runScenario(t, writableLimit{writable: w}, nil, -1, 3*ringBlocks))
		fmt.Printf("  restart of a full store:  %+v\n", runScenario(t, writableLimit{writable: w}, full(), -1, ringBlocks))
		fmt.Printf("  restart with 30 blocks:   %+v\n", runScenario(t, writableLimit{writable: w}, restoredBlocks(27), -1, ringBlocks))
		fmt.Printf("  block 51 corrupt, full:   %+v\n", runScenario(t, writableLimit{writable: w}, full(), 50, ringBlocks))
	}
	fmt.Println("writable=8 without lowering the current limit, restart of a full store")
	fmt.Printf("  current never grows:      %+v\n", runScenario(t, writableLimit{8, "current-never"}, full(), -1, ringBlocks))
	fmt.Printf("  current grows to 65:      %+v\n", runScenario(t, writableLimit{8, "current-full"}, full(), -1, ringBlocks))
}

// batchStore follows two batches of objects that every build touches: one
// uploaded first and one uploaded after two turns of the ring.
type batchStore struct {
	*simStore
	t *testing.T
}

func (s batchStore) upload(objects int) (batch []int) {
	for j := 0; j < objects; j++ {
		batch = append(batch, s.put(s.t))
	}
	return
}

func (s batchStore) touch(batch []int) (refreshed int) {
	for i, abs := range batch {
		rel := abs - s.blocks.popped
		if rel < 0 {
			continue
		}
		if _, needsRefresh := s.lbm.Get(local.Location{BlockIndex: rel, SizeBytes: 1}); needsRefresh {
			batch[i] = s.put(s.t)
			refreshed++
		}
	}
	return
}

type batchResult struct {
	firstSeries, lateSeries []int // objects refreshed by every build
	firstBusy, lateBusy     []int // busiest build per turn
	gapLow, gapHigh         float64
	unused                  float64 // blocks of unused space in the new blocks, averaged over the last turn
	maxWritable, batchSize  int
}

func runBatches(t *testing.T, policy local.BlockListGrowthPolicy, old, newCount int, name string) batchResult {
	const buildsPerBlock, turns = 7, 6
	r := batchResult{firstBusy: make([]int, turns), lateBusy: make([]int, turns), batchSize: simBlock / 5}
	s := batchStore{&simStore{blocks: &bigBlockList{}, old: old}, t}
	s.lbm = local.NewOldCurrentNewLocationBlobMap(s.blocks, policy, s.simStore, name, simBlock, old, newCount, 0)
	first := s.upload(r.batchSize)
	var late []int
	var rotationAt []int
	puts, pushed, samples := 0, s.blocks.pushed, 0
	per := ringBlocks * buildsPerBlock
	for b := 0; b < turns*per; b++ {
		if b == 2*per {
			late = s.upload(r.batchSize)
		}
		for j := 0; j < simBlock/buildsPerBlock; j++ {
			s.put(t)
			puts++
			if s.blocks.pushed != pushed {
				pushed = s.blocks.pushed
				rotationAt = append(rotationAt, puts)
			}
		}
		r.firstSeries = append(r.firstSeries, s.touch(first))
		r.lateSeries = append(r.lateSeries, s.touch(late))
		r.firstBusy[b/per] = max(r.firstBusy[b/per], r.firstSeries[b])
		r.lateBusy[b/per] = max(r.lateBusy[b/per], r.lateSeries[b])
		writable := 0
		for _, used := range s.blocks.used {
			if used < simBlock {
				writable++
			}
		}
		r.maxWritable = max(r.maxWritable, writable)
		if b >= (turns-1)*per {
			for _, used := range s.blocks.used {
				if used < simBlock {
					r.unused += 1 - float64(used)/simBlock
				}
			}
			samples++
		}
	}
	r.unused /= float64(samples)
	// Spacing of the last 90 rotations, in blocks' worth of new data.
	r.gapLow = 1e9
	for i := len(rotationAt) - 90; i < len(rotationAt); i++ {
		gap := float64(rotationAt[i]-rotationAt[i-1]) / simBlock
		r.gapLow, r.gapHigh = min(r.gapLow, gap), max(r.gapHigh, gap)
	}
	return r
}

func (r batchResult) String() string {
	pct := func(v int) string { return fmt.Sprintf("%5.1f%%", 100*float64(v)/float64(r.batchSize)) }
	return fmt.Sprintf("writable blocks %2d | first batch, busiest build: turn 1 %s, turn 2 %s | late batch: turns 3-4 %s, turns 5-6 %s | rotation gap in the last turn %.2f-%.2f blocks | unused in writable blocks %.1f",
		r.maxWritable, pct(r.firstBusy[0]), pct(r.firstBusy[1]), pct(max(r.lateBusy[2], r.lateBusy[3])), pct(max(r.lateBusy[4], r.lateBusy[5])),
		r.gapLow, r.gapHigh, r.unused)
}

// Option 1: how much does a larger number spread the first batch, and what
// does it do for a later one?
func TestOptionWritableLimitBatches(t *testing.T) {
	for _, w := range []int{3, 4, 5, 8, 16, 68} {
		fmt.Printf("writable=%2d  positions/disk during first fill %3d | %v\n", w, 8*w,
			runBatches(t, writableLimit{writable: w}, oldBlocks, newBlocks, fmt.Sprintf("limit-%d", w)))
	}
}

// Options 2 and 3: only new blocks are written and there are more of them.
// Z8_WEIGHTS selects how a round is divided: unset is upstream (powers of
// two), "capped" doubles from the newest block up to eight, "equal" gives
// every block eight.
func TestOptionNewBlocks(t *testing.T) {
	weights := os.Getenv("Z8_WEIGHTS")
	if weights == "" {
		weights = "upstream"
	}
	for _, n := range []int{3, 4, 5, 6, 8, 10, 16} {
		policy := local.NewSequentialBlockListGrowthPolicy(currentBlocks+newBlocks-n, n)
		fmt.Printf("%s new=%2d  positions/disk %3d | %v\n", weights, n, 8*n, runBatches(t, policy, oldBlocks, n, fmt.Sprintf("new-%d-%s", n, weights)))
	}
}

// Staggered old: the eight shards of a disk get different old/current splits,
// so the same batch turns old at different times in each of them. The number
// of blocks per shard and the number of new blocks stay the same.
func TestOptionStaggeredOld(t *testing.T) {
	weights := os.Getenv("Z8_WEIGHTS")
	if weights == "" {
		weights = "upstream"
	}
	for _, n := range []int{3, 5} {
		var first, late []int
		batch := 0
		for shard, old := range []int{14, 16, 18, 20, 22, 24, 26, 28} {
			current := oldBlocks + currentBlocks + newBlocks - old - n
			r := runBatches(t, local.NewSequentialBlockListGrowthPolicy(current, n), old, n, fmt.Sprintf("stagger-%d-%d-%s", n, shard, weights))
			if first == nil {
				first, late = make([]int, len(r.firstSeries)), make([]int, len(r.lateSeries))
			}
			for b := range first {
				first[b] += r.firstSeries[b]
				late[b] += r.lateSeries[b]
			}
			batch += r.batchSize
		}
		per := len(first) / 6
		busiest := func(series []int, turn int) string {
			m := 0
			for _, v := range series[turn*per : (turn+1)*per] {
				m = max(m, v)
			}
			return fmt.Sprintf("%4.1f%%", 100*float64(m)/float64(batch))
		}
		fmt.Printf("%s new=%d, old 14-28 over eight shards  positions/disk %d | first batch, busiest build: turn 1 %s, turn 2 %s, turn 3 %s | late batch: turn 3 %s, turn 4 %s, turn 5 %s, turn 6 %s\n",
			weights, n, 8*n, busiest(first, 0), busiest(first, 1), busiest(first, 2), busiest(late, 2), busiest(late, 3), busiest(late, 4), busiest(late, 5))
	}
}

// How many objects of one round does each writable block take?
func TestOptionRoundShares(t *testing.T) {
	cases := []struct {
		name          string
		policy        local.BlockListGrowthPolicy
		newConfigured int
		objects       int
	}{
		{"patch,    new_blocks=3", local.NewSequentialBlockListGrowthPolicy(65, 3), 3, 7},
		{"patch,    new_blocks=10", local.NewSequentialBlockListGrowthPolicy(58, 10), 10, 1023},
		{"upstream, new_blocks=3, first fill", local.NewImmutableBlockListGrowthPolicy(65, 3), 3, 65*8 + 7},
		{"upstream, new_blocks=10, first fill", local.NewImmutableBlockListGrowthPolicy(58, 10), 10, 58*1024 + 1023},
	}
	if os.Getenv("Z8_WEIGHTS") != "" {
		t.Skip("Round shares are reported for upstream weights only.")
	}
	for _, c := range cases {
		s := &simStore{blocks: &bigBlockList{}}
		s.lbm = local.NewOldCurrentNewLocationBlobMap(s.blocks, c.policy, s, c.name, 1<<40, oldBlocks, c.newConfigured, 0)
		counts := map[int]int{}
		for i := 0; i < c.objects; i++ {
			counts[s.put(t)]++
		}
		var perBlock []int
		for b := range s.blocks.used {
			perBlock = append(perBlock, counts[b])
		}
		if len(perBlock) > 14 {
			fmt.Printf("%s: %d writable blocks, one round = %d objects: %v ... %v\n", c.name, len(perBlock), c.objects, perBlock[:3], perBlock[len(perBlock)-11:])
		} else {
			fmt.Printf("%s: %d writable blocks, one round = %d objects: %v\n", c.name, len(perBlock), c.objects, perBlock)
		}
	}
}
