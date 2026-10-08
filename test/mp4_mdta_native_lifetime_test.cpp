#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/mp4chapter.h>
#include <iostream>
#include <stdexcept>
#include <string>

// Detect stale native atom state without reopening the File between saves.
int main(int argc, char **argv)
{
  if(argc != 2) return 2;
  try {
    TagLib::MP4::File file(argv[1], false);
    if(!file.isValid()) throw std::runtime_error("invalid fixture");
    auto *tag = file.tag();
    for(unsigned int pass = 0; pass < 3; ++pass) {
      TagLib::MP4::MdtaItemList values;
      values.append({TagLib::String(), 0, 1, pass, TagLib::ByteVector(std::string(100 + pass * 2000, 'x').c_str())});
      values.append({TagLib::String(), 0, 33, 1041, TagLib::ByteVector("\0\xff", 2)});
      if(!tag->replaceMdtaItems("audio_normalization", values))
        throw std::runtime_error("replacement failed at pass " + std::to_string(pass));
      if(pass > 0 && !tag->replaceMdtaItems("com.example.lifetime." + TagLib::String::number(pass), values))
        throw std::runtime_error("new key failed");
      if(!file.save()) throw std::runtime_error("save failed at pass " + std::to_string(pass));
      TagLib::MP4::File reopened(argv[1], false);
      if(!reopened.isValid()) throw std::runtime_error("reopen failed at pass " + std::to_string(pass));
      unsigned int count = 0;
      for(const auto &item : reopened.tag()->mdtaItems()) {
        if(item.key != "audio_normalization") continue;
        if(count >= values.size()) throw std::runtime_error("extra values");
        const auto &expected = values[count++];
        if(item.dataType != expected.dataType || item.locale != expected.locale || item.data != expected.data)
          throw std::runtime_error("value mismatch at pass " + std::to_string(pass));
      }
      if(count != values.size()) throw std::runtime_error("missing values at pass " + std::to_string(pass));
      std::cout << "pass=" << pass << " exact values verified\n";
    }
  }
  catch(const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
  return 0;
}
