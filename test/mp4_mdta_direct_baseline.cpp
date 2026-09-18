// Baseline diagnostic for the TagLib C++ API. It intentionally demonstrates
// the current 2.3.2 behavior; it is not the mdta implementation.

#include <taglib/mp4file.h>

#include <iostream>
#include <string>

int main(int argc, char **argv)
{
  if(argc != 2) {
    std::cerr << "usage: mp4_mdta_direct_baseline INPUT.mp4\n";
    return 2;
  }

  TagLib::MP4::File file(argv[1], false);
  if(!file.isOpen() || !file.tag()) {
    std::cerr << "failed to open MP4\n";
    return 1;
  }

  const auto beforeTitle = file.tag()->title().to8Bit();
  const auto beforeItems = file.tag()->itemMap().size();
  file.tag()->setTitle(TagLib::String("Changed via direct C++", TagLib::String::UTF8));
  const bool saved = file.save();

  std::cout << "before_title=" << beforeTitle << "\n"
            << "before_item_count=" << beforeItems << "\n"
            << "save=" << (saved ? "true" : "false") << "\n";
  return saved ? 0 : 1;
}
