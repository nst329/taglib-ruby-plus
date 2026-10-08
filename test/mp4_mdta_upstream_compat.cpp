#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/tfilestream.h>
#include <iostream>

// Compiled against pristine headers to exercise the original API and IOStream vtable.
class ReadOnlyStream : public TagLib::FileStream {
public:
  explicit ReadOnlyStream(const char *path) : FileStream(path) {}
  bool readOnly() const override { return true; }
};

// Verify an existing native client's normal tags and custom stream on the proposed library.
int main(int argc, char **argv)
{
  if(argc != 2) return 2;
  {
    TagLib::MP4::File file(argv[1], false);
    if(!file.isValid()) return 3;
    file.tag()->setTitle("compatibility title");
    if(!file.save()) return 4;
  }
  {
    TagLib::MP4::File file(argv[1], false);
    if(!file.isValid() || file.tag()->title() != "compatibility title") return 5;
  }
  ReadOnlyStream stream(argv[1]);
  TagLib::MP4::File file(&stream, false);
  if(!file.isValid() || file.save()) return 6;
  std::cout << "PASS compatibility Tag=" << sizeof(TagLib::MP4::Tag)
            << " File=" << sizeof(TagLib::MP4::File)
            << " IOStream=" << sizeof(TagLib::IOStream)
            << " FileStream=" << sizeof(TagLib::FileStream) << '\n';
}
