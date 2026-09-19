// Baseline diagnostic for the TagLib C++ API. It intentionally demonstrates
// the current 2.3.2 behavior; it is not the mdta implementation and must be
// replaced by a positive regression test after the TagLib patch is applied.

#include <taglib/mp4file.h>

#include <filesystem>
#include <iostream>
#include <string>

int main(int argc, char **argv)
{
  if(argc == 3 && std::string(argv[1]) == "--verify") {
    TagLib::MP4::File file(argv[2], false);
    return file.isOpen() && file.isValid() && file.tag() &&
      file.tag()->title().to8Bit() == "Changed via direct C++" &&
      file.tag()->contains(TagLib::String("\251nam", TagLib::String::Latin1)) ? 0 : 1;
  }
  if(argc != 3) {
    std::cerr << "usage: mp4_mdta_direct_baseline INPUT.mp4 OUTPUT.mp4\n";
    return 2;
  }

  std::error_code copyError;
  std::filesystem::copy_file(argv[1], argv[2],
                             std::filesystem::copy_options::none,
                             copyError);
  if(copyError) {
    std::cerr << "failed to copy fixture: " << copyError.message() << "\n";
    return 1;
  }

  std::string beforeTitle;
  size_t beforeItems = 0;
  bool beforeHasNormalTitle = false;
  bool saved = false;
  {
    TagLib::MP4::File file(argv[2], false);
    if(!file.isOpen() || !file.isValid() || !file.tag()) {
      std::cerr << "failed to open MP4\n";
      return 1;
    }

    beforeTitle = file.tag()->title().to8Bit();
    beforeItems = file.tag()->itemMap().size();
    beforeHasNormalTitle = file.tag()->contains(TagLib::String("\251nam", TagLib::String::Latin1));
    file.tag()->setTitle(TagLib::String("Changed via direct C++", TagLib::String::UTF8));
    saved = file.save();
  }

  TagLib::MP4::File reopened(argv[2], false);
  if(!reopened.isOpen() || !reopened.isValid() || !reopened.tag()) {
    std::cerr << "failed to reopen saved MP4\n";
    return 1;
  }
  const auto afterTitle = reopened.tag()->title().to8Bit();
  const auto afterItems = reopened.tag()->itemMap().size();
  const bool afterHasNormalTitle = reopened.tag()->contains(TagLib::String("\251nam", TagLib::String::Latin1));

  std::cout << "before_title=" << beforeTitle << "\n"
            << "before_item_count=" << beforeItems << "\n"
            << "before_has_normal_title=" << (beforeHasNormalTitle ? "true" : "false") << "\n"
            << "save=" << (saved ? "true" : "false") << "\n"
            << "after_title=" << afterTitle << "\n"
            << "after_item_count=" << afterItems << "\n"
            << "after_has_normal_title=" << (afterHasNormalTitle ? "true" : "false") << "\n";
  return saved && afterTitle == "Changed via direct C++" && afterHasNormalTitle ? 0 : 1;
}
