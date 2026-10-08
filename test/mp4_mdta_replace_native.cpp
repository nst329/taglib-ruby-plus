#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/tfilestream.h>
#include <iostream>

// Report writes as failed without modifying the synthesized fixture.
class MdtaDiscardWrites : public TagLib::FileStream {
public:
  explicit MdtaDiscardWrites(const char *path) : FileStream(path) {}
  unsigned int discarded = 0;
  void writeBlock(const TagLib::ByteVector &) override { ++discarded; }
  void insert(const TagLib::ByteVector &, TagLib::offset_t, size_t) override { ++discarded; }
  void removeBlock(TagLib::offset_t, size_t) override { ++discarded; }
  void truncate(TagLib::offset_t) override { ++discarded; }
  bool hasError() const override { return discarded > 0; }
};

// Exercise the native replacement contract without Ruby's save verification.
int main(int argc, char **argv)
{
  if(argc != 2) return 2;
  using namespace TagLib;
  const String key("com.example.multiple");
  const MP4::MdtaItemList values {
    {String(), 0, 1, 0, ByteVector("first")},
    {String(), 0, 1, 1041, ByteVector("second")},
    {String(), 0, 1, 0, ByteVector("first")},
    {String(), 0, 33, 7, ByteVector("\0\xff", 2)},
    {String(), 0, 0, 0xffffffffU, ByteVector()}
  };
  for(int pass = 0; pass < 3; ++pass) {
    MP4::File file(argv[1], false);
    if(!file.isValid() || !file.tag()->replaceMdtaItems(key, values) || !file.save())
      return 1;
  }
  MP4::File file(argv[1], false);
  unsigned int count = 0, index = 0;
  for(const auto &item : file.tag()->mdtaItems()) {
    if(item.key != key) continue;
    if(count >= values.size()) return 1;
    const auto &expected = values[count++];
    if(index == 0) index = item.keyIndex;
    if(item.keyIndex != index || item.dataType != expected.dataType ||
       item.locale != expected.locale || item.data != expected.data)
      return 1;
  }
  if(count != values.size() || file.tag()->replaceMdtaItems(key, {})) return 1;
  MdtaDiscardWrites stream(argv[1]);
  MP4::File failed(&stream, false);
  if(!failed.tag()->replaceMdtaItems(key, values) || failed.save() || stream.discarded == 0)
    return 1;
  std::cout << "native ordered replacement passed: " << count << " values\n";
  return 0;
}
