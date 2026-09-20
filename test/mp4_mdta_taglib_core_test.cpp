#include <cstdlib>
#include <iostream>
#include <string>

#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>

namespace {

void require(bool condition, const char *message)
{
  if(!condition) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}

const TagLib::MP4::MdtaItem *find(const TagLib::MP4::MdtaItemList &items,
                                  const char *key)
{
  for(const auto &item : items) {
    if(item.key == key)
      return &item;
  }
  return nullptr;
}

} // namespace

int main(int argc, char **argv)
{
  require(argc == 3, "usage: mp4_mdta_taglib_core_test INPUT OUTPUT");
  {
    TagLib::MP4::File input(argv[1], false);
    require(input.isValid(), "input is invalid");
    const auto &before = input.tag()->mdtaItems();
    require(before.size() >= 6, "expected FFmpeg mdta entries");
    require(!input.tag()->isEmpty(), "mdta-only tag reported empty");
    require(find(before, "audio_normalization") != nullptr, "normalization key missing");
    require(find(before, "audio_normalization_target") != nullptr, "normalization target missing");
    require(input.tag()->title() == "MDTA Title", "mdta title fallback missing");
    require(input.tag()->artist() == "MDTA Artist", "mdta artist fallback missing");
  }

  std::string command = "cp \"" + std::string(argv[1]) + "\" \"" + argv[2] + "\"";
  require(std::system(command.c_str()) == 0, "copy failed");
  {
    TagLib::MP4::File output(argv[2], false);
    require(output.isValid(), "output is invalid");
    output.tag()->setTitle("Changed by patched TagLib");
    require(output.save(), "normal title save failed");
  }

  {
    TagLib::MP4::File reopened(argv[2], false);
    require(reopened.isValid(), "reopened output is invalid");
    require(reopened.tag()->title() == "Changed by patched TagLib", "normal title was not saved");
    const auto &afterTitle = reopened.tag()->mdtaItems();
    require(find(afterTitle, "audio_normalization") != nullptr, "normalization lost after title save");
    require(find(afterTitle, "audio_normalization_target") != nullptr, "normalization target lost after title save");
    require(find(afterTitle, "show") != nullptr, "show lost after title save");
    require(find(afterTitle, "artist") != nullptr, "artist lost after title save");
    require(find(afterTitle, "description") != nullptr, "description lost after title save");

    require(reopened.tag()->setMdtaItem("audio_normalization", 1, 0,
                                        TagLib::ByteVector("ebu-r128", 8)),
            "mdta update failed");
    require(reopened.tag()->setMdtaItem("audio_normalization_target", 1, 0,
                                        TagLib::ByteVector("-14-LUFS", 8)),
            "mdta target update failed");
    require(reopened.tag()->setMdtaItem("com.example.taglib.new-key", 1, 0,
                                        TagLib::ByteVector("new-value", 9)),
            "new mdta key add failed");
    require(reopened.save(), "mdta save failed");
  }

  {
    TagLib::MP4::File saved(argv[2], false);
    require(saved.isValid(), "saved output is invalid");
    const auto &afterMdta = saved.tag()->mdtaItems();
    const auto *normalization = find(afterMdta, "audio_normalization");
    const auto *target = find(afterMdta, "audio_normalization_target");
    const auto *newKey = find(afterMdta, "com.example.taglib.new-key");
    require(newKey && newKey->data == TagLib::ByteVector("new-value", 9),
            "new mdta key did not roundtrip");
    require(normalization != nullptr, "normalization missing after mdta update");
    require(target != nullptr, "target missing after mdta update");
    require(normalization->data == TagLib::ByteVector("ebu-r128", 8),
            "normalization changed unexpectedly");
    require(target->data == TagLib::ByteVector("-14-LUFS", 8),
            "target changed unexpectedly");
    require(saved.tag()->removeMdtaItem("com.example.taglib.new-key"),
            "new mdta key removal failed");
    require(saved.save(), "mdta key removal save failed");
  }

  TagLib::MP4::File finalFile(argv[2], false);
  require(finalFile.isValid(), "final output is invalid");
  const auto &afterMdta = finalFile.tag()->mdtaItems();
  const auto *normalization = find(afterMdta, "audio_normalization");
  const auto *target = find(afterMdta, "audio_normalization_target");
  if(!normalization || normalization->data != TagLib::ByteVector("ebu-r128", 8)) {
    std::cerr << "normalization=" << (normalization ? normalization->data.toHex().data() : "missing") << '\n';
    return 1;
  }
  if(!target || target->data != TagLib::ByteVector("-14-LUFS", 8)) {
    std::cerr << "target=" << (target ? target->data.toHex().data() : "missing") << '\n';
    return 1;
  }
  require(find(afterMdta, "com.example.taglib.new-key") == nullptr,
          "removed mdta key still exists");
  require(finalFile.tag()->title() == "Changed by patched TagLib", "normal title lost after mdta save");
  return 0;
}
