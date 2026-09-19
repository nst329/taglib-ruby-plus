// Design experiment: deliberately discard writes on a temporary fixture only.
#include <taglib/mp4file.h>
#include <taglib/tfilestream.h>
#include <iostream>

class DiscardWrites : public TagLib::FileStream {
public:
  explicit DiscardWrites(const char *path) : FileStream(path) {}
  unsigned discarded = 0;
  void writeBlock(const TagLib::ByteVector &) override { ++discarded; }
  void insert(const TagLib::ByteVector &, TagLib::offset_t, size_t) override { ++discarded; }
  void removeBlock(TagLib::offset_t, size_t) override { ++discarded; }
  void truncate(TagLib::offset_t) override { ++discarded; }
  bool hasError() const override { return discarded > 0; }
};

int main(int argc, char **argv) {
  if(argc != 2) return 2;
  DiscardWrites stream(argv[1]);
  TagLib::MP4::File file(&stream, false);
  if(!file.isValid()) return 1;
  file.tag()->setTitle("Discarded title");
  const bool result = file.save();
  std::cout << "save=" << result << " discarded=" << stream.discarded << '\n';
  return !result && stream.discarded > 0 ? 0 : 1;
}
