#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/mp4chapter.h>
#include <taglib/mp4coverart.h>
#include <taglib/tfilestream.h>
#include "support/mp4_mdta_upstream_limits.h"
#include <iostream>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

using namespace TagLib;
static unsigned int assertions = 0;
static_assert(sizeof(MP4::MdtaValue) == sizeof(std::shared_ptr<void>));
static_assert(sizeof(MP4::MdtaItem) == sizeof(std::shared_ptr<void>));

void require(bool condition, const std::string &message)
{
  ++assertions;
  if(!condition) throw std::runtime_error(message);
}

// Return a deliberately heterogeneous ordered sequence, including duplicate and empty values.
MP4::MdtaValueList values(unsigned int pass)
{
  const std::string first(100 + pass * 2000, 'a');
  return {
    MP4::MdtaValue(1, 0, ByteVector(first.data(), first.size())),
    MP4::MdtaValue(1, 1041, ByteVector("second", 6)),
    MP4::MdtaValue(1, 0, ByteVector(first.data(), first.size())),
    MP4::MdtaValue(33, 7, ByteVector("\0\xff\0", 3)),
    MP4::MdtaValue(0xffffffffU, 0xffffffffU, ByteVector())
  };
}

const MP4::MdtaItem &find(const MP4::MdtaItemList &items, const String &key)
{
  for(const auto &item : items) {
    if(item.key() == key) return item;
  }
  throw std::runtime_error("missing key " + key.to8Bit(true));
}

ByteVector readBytes(const char *path)
{
  std::ifstream input(path, std::ios::binary);
  const std::string data((std::istreambuf_iterator<char>(input)), {});
  return ByteVector(data.data(), data.size());
}

// Check copy/assignment/swap and ownership of exported proposal value classes.
void valueTypes()
{
  MP4::MdtaValue first(33, 1041, ByteVector("\0\xff", 2));
  const auto copy = first;
  MP4::MdtaValue empty(1, 0, ByteVector());
  const auto originalEmpty = empty;
  first.swap(empty);
  require(first == originalEmpty && empty == copy, "value swap changed copies");
  first = copy;
  require(first == copy, "value assignment failed");
  auto data = copy.data();
  data.clear();
  require(copy.data() == ByteVector("\0\xff", 2), "value payload is not detached");
  MP4::MdtaItem item("key", 7, {copy, copy});
  const auto snapshot = item;
  MP4::MdtaItem other("other", 8, {});
  item.swap(other);
  require(other == snapshot && item.key() == "other", "item swap changed snapshot");
  item = snapshot;
  require(item == snapshot && item.values().size() == 2, "item assignment lost duplicates");
  auto list = item.values();
  list.clear();
  require(snapshot.values().size() == 2, "snapshot list aliases returned list");
}

// Hold both the File and its Tag pointer across writes, checking independent on-disk reads.
void restore(const char *path, const char *artwork)
{
  MP4::File file(path, false);
  require(file.isValid(), "invalid fixture");
  auto *tag = file.tag();
  require(tag->mdtaStatus() == MP4::MdtaStatus::Editable, "expected Editable");
  const MP4::MdtaItemList detached = tag->mdtaItems();
  const MP4::MdtaItemList original = detached;
  const ByteVector picture = readBytes(artwork);
  require(!picture.isEmpty(), "artwork missing");
  tag->setTitle("iTunes title");
  tag->setItem("----:com.apple.iTunes:note", MP4::Item(StringList("Freeform note")));
  tag->setItem("covr", MP4::Item(MP4::CoverArtList{MP4::CoverArt(MP4::CoverArt::JPEG, picture)}));
  MP4::ChapterList chapters {MP4::Chapter("Opening", 0), MP4::Chapter("End", 500)};
  file.setNeroChapters(chapters);
  file.setQtChapters(chapters);
  require(file.save(), "seed artwork/chapters save failed");
  require(file.tag() == tag, "Tag pointer changed after seed save");
  require(detached == original, "snapshot changed after mutation");
  const auto *mapAddress = &tag->itemMap();
  const unsigned int existingIndex = find(tag->mdtaItems(), "audio_normalization").keyIndex();
  for(unsigned int pass = 0; pass < 3; ++pass) {
    const auto expected = values(pass);
    const auto before = tag->mdtaItems();
    require(tag->replaceMdtaItems("audio_normalization", expected), "existing key replacement failed");
    if(pass > 0) {
      const String newKey = "com.example.lifetime." + String::number(pass);
      require(tag->replaceMdtaItems(newKey, expected), "new key replacement failed");
      require(find(tag->mdtaItems(), newKey).keyIndex() == before.size() + 1, "new index not appended");
      require(tag->replaceMdtaItems(newKey, expected), "repeat replacement failed");
    }
    const auto expectedItems = tag->mdtaItems();
    require(file.save(), "save failed at pass " + std::to_string(pass));
    require(file.tag() == tag && &tag->itemMap() == mapAddress, "public Tag/Map object identity changed");
    MP4::File reopened(path, false);
    require(reopened.isValid(), "reopen failed at pass " + std::to_string(pass));
    require(reopened.tag()->mdtaItems() == expectedItems, "exact snapshot mismatch");
    const auto item = find(reopened.tag()->mdtaItems(), "audio_normalization");
    require(item.keyIndex() == existingIndex && item.values() == expected, "index/type/locale/bytes/order mismatch");
    require(reopened.tag()->title() == "iTunes title", "title damaged");
    require(reopened.tag()->item("----:com.apple.iTunes:note").toStringList() == StringList("Freeform note"), "freeform damaged");
    const auto covers = reopened.tag()->item("covr").toCoverArtList();
    require(covers.size() == 1 && covers.front().data() == picture, "artwork damaged");
    require(reopened.neroChapters() == chapters && reopened.qtChapters() == chapters, "chapters damaged");
    auto copiedValues = item.values();
    copiedValues.clear();
    require(find(tag->mdtaItems(), "audio_normalization").values() == expected, "returned List aliases Tag");
    auto copiedData = item.values().front().data();
    copiedData.clear();
    require(find(tag->mdtaItems(), "audio_normalization").values() == expected, "returned ByteVector aliases Tag");
  }
  chapters = {MP4::Chapter("Updated", 0)};
  file.setNeroChapters(chapters);
  file.setQtChapters(chapters);
  require(file.save(), "chapter change after metadata save failed");
  require(tag->replaceMdtaItems("audio_normalization", values(0)), "metadata change after chapter save failed");
  require(file.save(), "metadata save after chapter change failed");
  MP4::File reopened(path, false);
  require(reopened.isValid() && reopened.neroChapters() == chapters && reopened.qtChapters() == chapters,
          "chapter/metadata save sequence damaged file");
  require(find(reopened.tag()->mdtaItems(), "audio_normalization").values() == values(0), "last values lost");
}

// Verify rejection leaves both pending ordinary metadata and all mdta snapshots unchanged.
void invalid(const char *path)
{
  MP4::File file(path, false);
  require(file.isValid(), "invalid fixture");
  auto *tag = file.tag();
  tag->setTitle("pending ordinary edit");
  const auto before = tag->mdtaItems();
  require(!tag->replaceMdtaItems("audio_normalization", {}), "empty values accepted");
  require(!tag->replaceMdtaItems(String(), values(0)), "empty key accepted");
  require(!tag->replaceMdtaItems(String(std::string("bad\0key", 7), String::UTF8), values(0)), "NUL key accepted");
  require(before == tag->mdtaItems() && tag->title() == "pending ordinary edit", "partial update after rejection");
  uint64_t length = 8;
  require(!MP4::MdtaInternal::appendDataLength(length, 0xffffffffffffffffULL) && length == 8, "overflow changed plan");
  require(MP4::MdtaInternal::appendDataLength(length, 10) && length == 34, "valid length rejected");
  require(MP4::MdtaInternal::fitsGrowth(0xfffffffeULL, 1, 0xffffffffULL), "boundary growth rejected");
  require(!MP4::MdtaInternal::fitsGrowth(0xfffffffeULL, 2, 0xffffffffULL), "stco overflow accepted");
  require(!MP4::MdtaInternal::fitsGrowth(8, 0xffffffffffffffffULL, 0xffffffffULL), "growth wrap accepted");
  const auto saved = length;
  require(!MP4::MdtaInternal::appendDataLength(length, 0xffffffffULL) && length == saved, "later overflow changed plan");
}

// Distinguish absent mdta from unsupported mdta, and prevent unsafe metadata saves.
void status(const char *path, bool unsupported)
{
  MP4::File file(path, false);
  require(file.isValid(), "fixture must be structurally readable by TagLib");
  auto *tag = file.tag();
  require(tag->mdtaStatus() == (unsupported ? MP4::MdtaStatus::Unsupported : MP4::MdtaStatus::Absent), "wrong status");
  require(tag->mdtaItems().isEmpty(), "partial snapshot exposed");
  require(!tag->replaceMdtaItems("new", values(0)), "unsupported/absent replacement accepted");
  require(!tag->removeMdtaItem("new"), "unsupported/absent removal accepted");
  if(unsupported) {
    require(!tag->isEmpty(), "unsupported tag reported empty");
    require(!tag->strip(), "unsupported strip accepted");
    tag->setTitle("must not be written");
    require(!file.save(), "unsupported save accepted");
  }
  else {
    tag->setTitle("ordinary title");
    require(file.save(), "normal mdir save failed");
    MP4::File reopened(path, false);
    require(reopened.isValid() && reopened.tag()->title() == "ordinary title", "ordinary title lost");
  }
}

// Preserve key-only entries and assign their existing index rather than appending duplicates.
void emptyKeys(const char *path, bool zeroKeys)
{
  MP4::File file(path, false);
  require(file.isValid() && file.tag()->mdtaStatus() == MP4::MdtaStatus::Editable, "empty keys not editable");
  auto *tag = file.tag();
  const auto before = tag->mdtaItems();
  require(zeroKeys ? before.isEmpty() : !before.isEmpty(), "unexpected keys table");
  if(!zeroKeys) {
    for(const auto &item : before) require(item.values().isEmpty(), "expected keys without values");
  }
  const String key = zeroKeys ? String("new") : before.front().key();
  require(tag->replaceMdtaItems(key, {MP4::MdtaValue(1, 0, ByteVector())}), "empty payload rejected");
  require(file.save(), "empty keys save failed");
  MP4::File reopened(path, false);
  const auto item = find(reopened.tag()->mdtaItems(), key);
  require(item.keyIndex() == 1 && item.values().size() == 1 && item.values().front().data().isEmpty(),
          "empty payload or index lost");
}

// Remove a middle key with reference reindexing, then strip values without resurrection.
void removeAndStrip(const char *path)
{
  MP4::File file(path, false);
  auto *tag = file.tag();
  const auto before = tag->mdtaItems();
  const auto removedIndex = find(before, "artist").keyIndex();
  require(tag->removeMdtaItem("missing"), "absent removal should be a no-op");
  require(tag->mdtaItems() == before, "no-op changed snapshot");
  require(tag->removeMdtaItem("artist") && file.save(), "key removal/save failed");
  MP4::File reopened(path, false);
  const auto after = reopened.tag()->mdtaItems();
  require(after.size() + 1 == before.size(), "key count mismatch");
  for(const auto &item : before) {
    if(item.key() == "artist") continue;
    const auto remaining = find(after, item.key());
    require(remaining.keyIndex() == item.keyIndex() - (item.keyIndex() > removedIndex ? 1 : 0), "index mismatch after removal");
    require(remaining.values() == item.values(), "other key values changed");
  }
  require(tag->strip() && tag->isEmpty(), "strip did not clear values");
  require(file.save(), "save after strip failed");
  MP4::File stripped(path, false);
  require(stripped.isValid() && stripped.tag()->isEmpty(), "stripped values resurrected");
  for(const auto &item : stripped.tag()->mdtaItems()) require(item.values().isEmpty(), "mdta survived strip");
}

// Read repeated parent items, then save a normal title while retaining their raw data children.
void readMultiple(const char *path)
{
  MP4::File file(path, false);
  require(file.isValid() && file.tag()->mdtaStatus() == MP4::MdtaStatus::Editable, "multiple data fixture unreadable");
  const auto before = file.tag()->mdtaItems();
  require(find(before, "audio_normalization").values() == values(0), "multiple parent/data order lost");
  file.tag()->setTitle("ordinary edit");
  require(file.save(), "ordinary metadata save failed");
  MP4::File reopened(path, false);
  require(reopened.isValid() && reopened.tag()->mdtaItems() == before, "ordinary save lost mdta");
}

// Reject saves on read-only streams while retaining the requested in-memory values.
class ReadOnlyStream : public FileStream {
public:
  explicit ReadOnlyStream(const char *path) : FileStream(path) {}
  bool readOnly() const override { return true; }
};

void readOnlySave(const char *path)
{
  ReadOnlyStream stream(path);
  MP4::File file(&stream, false);
  require(file.isValid(), "read-only fixture invalid");
  require(file.tag()->replaceMdtaItems("audio_normalization", values(0)), "read-only memory edit rejected");
  const auto pending = file.tag()->mdtaItems();
  require(!file.save(), "read-only save accepted");
  require(file.tag()->mdtaItems() == pending, "pending values lost on save rejection");
}

void invalidFileSave(const char *path)
{
  MP4::File file(path, false);
  require(!file.isValid() && !file.save(), "invalid file save accepted");
}

// Inject unreported I/O failures; read-back detects missing metadata but cannot prove durability.
class DiscardWrites : public FileStream {
public:
  explicit DiscardWrites(const char *path) : FileStream(path) {}
  unsigned int discarded = 0;
  void writeBlock(const ByteVector &) override { ++discarded; }
  void insert(const ByteVector &, offset_t, size_t) override { ++discarded; }
  void removeBlock(offset_t, size_t) override { ++discarded; }
  void truncate(offset_t) override { ++discarded; }
};

void ioLimitation(const char *path)
{
  DiscardWrites stream(path);
  MP4::File file(&stream, false);
  const auto before = file.tag()->mdtaItems();
  require(file.tag()->replaceMdtaItems("audio_normalization", values(0)), "setup replacement failed");
  const bool result = file.save();
  require(!result && stream.discarded > 0, "discarded metadata write was accepted");
  require(!file.isValid(), "write mismatch did not invalidate File");
  require(find(file.tag()->mdtaItems(), "audio_normalization").values() == values(0), "pending edit lost on write failure");
  MP4::File reopened(path, false);
  require(reopened.tag()->mdtaItems() == before, "discard stream changed disk");
  std::cout << "DETECTED_FAILURE save=0 discarded=" << stream.discarded << " requested values not written\n";
}

// Fail after metadata has been written, proving that a later stage cannot commit it.
class DropChapter : public FileStream {
public:
  explicit DropChapter(const char *path) : FileStream(path) {}
  unsigned int dropped = 0;
  void insert(const ByteVector &data, offset_t start, size_t replace) override {
    if(data.size() >= 8 && data.mid(4, 4) == "chpl") { ++dropped; return; }
    FileStream::insert(data, start, replace);
  }
};

void chapterFailure(const char *path)
{
  DropChapter stream(path);
  MP4::File file(&stream, false);
  require(file.isValid(), "chapter failure fixture invalid");
  auto *tag = file.tag();
  tag->setTitle("pending title");
  require(tag->replaceMdtaItems("new.pending", values(1)), "pending new key rejected");
  const auto pending = tag->mdtaItems();
  const MP4::ChapterList chapters {MP4::Chapter("pending chapter", 0)};
  file.setNeroChapters(chapters);
  require(!file.save() && stream.dropped == 1, "late chapter failure accepted");
  require(!file.isValid(), "late failure did not invalidate File");
  require(tag->mdtaItems() == pending && tag->title() == "pending title", "pending metadata lost");
  require(file.neroChapters() == chapters, "pending chapters lost");
  require(!file.save(), "invalid File permitted retry");
}

// A representational chapter error must be rejected before the first metadata write.
void chapterPreflight(const char *path)
{
  MP4::File file(path, false);
  const auto before = readBytes(path);
  require(file.tag()->replaceMdtaItems("new.pending", values(0)), "setup edit failed");
  const auto pending = file.tag()->mdtaItems();
  file.setNeroChapters({MP4::Chapter(String(std::string(256, 'x'), String::UTF8), 0)});
  require(!file.save() && file.isValid(), "chapter preflight did not reject safely");
  require(readBytes(path) == before && file.tag()->mdtaItems() == pending, "preflight changed state/disk");
  file.setNeroChapters({MP4::Chapter("valid", 0)});
  require(file.save(), "File unusable after preflight rejection");
}

// Direct ItemMap mutations must preserve the independently maintained mdta model.
void directMap(const char *path)
{
  MP4::File file(path, false);
  auto *tag = file.tag();
  const auto before = tag->mdtaItems();
  auto &map = const_cast<MP4::ItemMap &>(tag->itemMap());
  map.insert("\251nam", MP4::Item(StringList("direct title")));
  require(file.save(), "direct map insertion failed");
  MP4::File first(path, false);
  require(first.tag()->title() == "direct title" && first.tag()->mdtaItems() == before, "direct insert changed mdta");
  map.erase("\251nam");
  require(file.save(), "direct map erasure failed");
  map.clear();
  require(file.save(), "direct map clear failed");
  MP4::File last(path, false);
  require(last.tag()->itemMap().isEmpty() && last.tag()->mdtaItems() == before, "direct clear lost mdta");
  require(tag->replaceMdtaItems("audio_normalization", values(0)) && tag->save(), "direct Tag save failed");
  require(file.save(), "File save after direct Tag save failed");
}

// Sparse padding exercises real >4 GiB file offsets without allocating a huge fixture.
void largeFile(const char *path)
{
  MP4::File file(path, false);
  require(file.isValid() && file.length() > 0xffffffffLL, "large fixture invalid");
  require(file.tag()->replaceMdtaItems("new.large", values(1)), "large file edit rejected");
  const auto expected = file.tag()->mdtaItems();
  require(file.save(), "large file save failed");
  MP4::File reopened(path, false);
  require(reopened.isValid() && reopened.tag()->mdtaItems() == expected, "large file values lost");
  reopened.setQtChapters({MP4::Chapter("unrepresentable stco at EOF", 0)});
  require(!reopened.save() && reopened.isValid(), "QT stco overflow was not rejected before writing");
}

// Run one native contract per copied fixture, returning a nonzero status on any mismatch.
int main(int argc, char **argv)
{
  if(argc < 3) return 2;
  try {
    const std::string mode(argv[1]);
    if(mode == "restore") { require(argc == 4, "artwork argument missing"); restore(argv[2], argv[3]); }
    else if(mode == "invalid") invalid(argv[2]);
    else if(mode == "unsupported") status(argv[2], true);
    else if(mode == "absent") status(argv[2], false);
    else if(mode == "empty") emptyKeys(argv[2], true);
    else if(mode == "keys-only") emptyKeys(argv[2], false);
    else if(mode == "remove-strip") removeAndStrip(argv[2]);
    else if(mode == "value-types") valueTypes();
    else if(mode == "read-values") readMultiple(argv[2]);
    else if(mode == "read-only") readOnlySave(argv[2]);
    else if(mode == "invalid-file") invalidFileSave(argv[2]);
    else if(mode == "large-file") largeFile(argv[2]);
    else if(mode == "chapter-failure") chapterFailure(argv[2]);
    else if(mode == "chapter-preflight") chapterPreflight(argv[2]);
    else if(mode == "direct-map") directMap(argv[2]);
    else if(mode == "io-limitation") ioLimitation(argv[2]);
    else throw std::runtime_error("unknown mode");
    std::cout << "PASS " << mode << " assertions=" << assertions << '\n';
  }
  catch(const std::exception &error) {
    std::cerr << "FAIL " << argv[1] << ": " << error.what() << '\n';
    return 1;
  }
  return 0;
}
