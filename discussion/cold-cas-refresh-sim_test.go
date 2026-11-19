// Simulation behind discussion/cold-cas-sequential-fill.md: how concentrated
// are the refreshes of a cohort of objects that was uploaded together and is
// touched by every build? It is not part of the kit or of the image build.
//
// To run it, apply z8-kit/buildbarn/storage-sequential-fill.patch to bb-storage
// ca3d8b49a5, copy this file and storage-sequential-fill_test.go into z8/, and
// run: go test ./z8/ -run TestSimulateRefresh -v
package z8_test

import (
	"fmt"
	"sort"
	"testing"

	"github.com/buildbarn/bb-storage/pkg/blobstore/local"
)

const simBlock = 2800

type bigBlockList struct{ blockList }

func (bl *bigBlockList) HasSpace(i int, n int64) bool { return bl.used[i]+n <= simBlock }

type simStore struct {
	blocks   *bigBlockList
	lbm      *local.OldCurrentNewLocationBlobMap
	old      int
	cohort   []int // absolute block number of every cohort object
	lost     int
	perBuild []int
}

func (s *simStore) Log(error) {}

func newSim(t *testing.T, policy local.BlockListGrowthPolicy, old int, name string) *simStore {
	s := &simStore{blocks: &bigBlockList{}, old: old}
	s.lbm = local.NewOldCurrentNewLocationBlobMap(s.blocks, policy, s, name, simBlock, old, newBlocks, 0)
	return s
}

func (s *simStore) put(t *testing.T) int {
	w, err := s.lbm.Put(1)
	if err != nil {
		t.Fatal(err)
	}
	l, _ := w(nil)()
	return s.blocks.popped + l.BlockIndex
}

// build touches every cohort object; objects in old blocks are copied to new blocks.
func (s *simStore) build(t *testing.T) {
	refreshed := 0
	for i, abs := range s.cohort {
		rel := abs - s.blocks.popped
		if rel < 0 {
			if abs >= 0 {
				s.lost++
				s.cohort[i] = -1 << 30
			}
			continue
		}
		if _, needsRefresh := s.lbm.Get(local.Location{BlockIndex: rel, SizeBytes: 1}); needsRefresh {
			s.cohort[i] = s.put(t)
			refreshed++
		}
	}
	s.perBuild = append(s.perBuild, refreshed)
}

func TestSimulateRefresh(t *testing.T) {
	const buildsPerBlock = 7 // seven builds while one block of other data arrives
	const turns = 5          // ring turns to simulate
	type variant struct {
		name   string
		policy func(current int) local.BlockListGrowthPolicy
		olds   []int // one simulated shard per entry
	}
	seq := func(current int) local.BlockListGrowthPolicy {
		p, _ := configurationPolicy(current)
		return p
	}
	up := func(current int) local.BlockListGrowthPolicy {
		return local.NewImmutableBlockListGrowthPolicy(current, newBlocks)
	}
	variants := []variant{
		{"upstream 22/65", up, []int{22}},
		{"patched 22/65", seq, []int{22}},
		{"patched, old staggered 14..28 over 8 shards", seq, []int{14, 16, 18, 20, 22, 24, 26, 28}},
	}
	for _, cohort := range []int{simBlock / 5, 2 * simBlock} {
		fmt.Printf("== cohort of %.1f blocks\n", float64(cohort)/simBlock)
		for _, v := range variants {
			var total []int
			lost, n := 0, 0
			for i, old := range v.olds {
				current := oldBlocks + currentBlocks - old
				s := newSim(t, v.policy(current), old, fmt.Sprintf("%s-%d", v.name, i))
				for j := 0; j < cohort; j++ {
					s.cohort = append(s.cohort, s.put(t))
				}
				for b := 0; b < turns*ringBlocks*buildsPerBlock; b++ {
					for j := 0; j < simBlock/buildsPerBlock; j++ {
						s.put(t)
					}
					s.build(t)
				}
				if total == nil {
					total = make([]int, len(s.perBuild))
				}
				for k, r := range s.perBuild {
					total[k] += r
				}
				lost += s.lost
				n += cohort
			}
			// Per ring turn: the busiest build and the busiest block-long window, as a share of the cohort.
			fmt.Printf("%-46s lost %d\n", v.name, lost)
			per := ringBlocks * buildsPerBlock
			for turn := 0; turn*per < len(total); turn++ {
				seg := total[turn*per : min((turn+1)*per, len(total))]
				maxBuild, maxWindow, sum, busy := 0, 0, 0, 0
				for k := range seg {
					if seg[k] > maxBuild {
						maxBuild = seg[k]
					}
					w := 0
					for m := k; m < min(k+buildsPerBlock, len(seg)); m++ {
						w += seg[m]
					}
					if w > maxWindow {
						maxWindow = w
					}
					sum += seg[k]
					if seg[k] > 0 {
						busy++
					}
				}
				sorted := append([]int(nil), seg...)
				sort.Ints(sorted)
				fmt.Printf("   turn %d: copied %5.1f%% of cohort; busiest build %5.1f%%; busiest block-long window %5.1f%%; builds that copied anything %3d of %d\n",
					turn+1, 100*float64(sum)/float64(n), 100*float64(maxBuild)/float64(n), 100*float64(maxWindow)/float64(n), busy, len(seg))
			}
		}
	}
}

func configurationPolicy(current int) (local.BlockListGrowthPolicy, error) {
	return local.NewSequentialBlockListGrowthPolicy(current, newBlocks), nil
}
