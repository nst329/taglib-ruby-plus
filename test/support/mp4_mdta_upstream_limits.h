#ifndef TAGLIB_MP4MDTALIMITS_H
#define TAGLIB_MP4MDTALIMITS_H
#include <cstdint>
namespace TagLib::MP4::MdtaInternal {
// Validate a growth bound without evaluating a potentially overflowing addition.
constexpr bool fitsGrowth(uint64_t current, uint64_t growth, uint64_t maximum)
{
  return current <= maximum && growth <= maximum - current;
}

// Accumulate an atom length only when its 32-bit representation remains exact.
constexpr bool appendLength(uint64_t &length, uint64_t addition)
{
  if(!fitsGrowth(length, addition, 0xffffffffULL)) return false;
  length += addition;
  return true;
}

// Reject overflowing data/item lengths before an edit candidate is committed.
constexpr bool appendDataLength(uint64_t &itemLength, uint64_t payloadLength)
{
  constexpr uint64_t maximum = 0xffffffffULL;
  if(itemLength > maximum || payloadLength > maximum - 16 ||
     itemLength > maximum - 16 - payloadLength)
    return false;
  itemLength += 16 + payloadLength;
  return true;
}
}
#endif
