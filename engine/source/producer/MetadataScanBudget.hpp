// Vista MIT. Container fragmentation must consume the unchanged block budget.
#pragma once
#include <cstddef>
#include <cstdint>
namespace vista_mkv {
struct MetadataScanBudget {
 static constexpr std::size_t maxBlocks=2048;
 // Preserve at most the old eight-cluster allowance for nonproductive input.
 // This is cumulative across a plan, never reset by an intervening block.
 static constexpr std::size_t maxEmptyClusters=8;
 static constexpr std::size_t maxClusters=maxBlocks+maxEmptyClusters;
 std::size_t clusters=0,blocks=0,emptyClusters=0,clusterStartBlocks=0;
 bool enterCluster(){clusterStartBlocks=blocks;return ++clusters<=maxClusters;}
 bool addBlock(){return ++blocks<=maxBlocks;}
 bool leaveCluster(){return blocks!=clusterStartBlocks||++emptyClusters<=maxEmptyClusters;}
 static bool advances(std::int64_t current,std::int64_t next){return current>=0&&next>current;}
};
}
