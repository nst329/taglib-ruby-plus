#include <taglib/mp4file.h>
#include <taglib/mp4tag.h>
#include <taglib/mp4item.h>
#include <iostream>
#include <stdexcept>

// Verify fields that the flat Ruby snapshot cannot currently observe.
int main(int argc, char **argv)
{
  try {
    if(argc != 2) throw std::runtime_error("expected synthetic MP4 path");
    TagLib::MP4::Item original(TagLib::ByteVectorList{TagLib::ByteVector("\0x", 2)});
    original.setAtomDataType(TagLib::MP4::TypeUUID);
    TagLib::MP4::Item reconstructed(original.toByteVectorList());
    if(original.type() != reconstructed.type() || original.toByteVectorList() != reconstructed.toByteVectorList())
      throw std::runtime_error("expected equal logical payload");
    if(original == reconstructed || original.atomDataType() == reconstructed.atomDataType())
      throw std::runtime_error("atomDataType counterexample missing");
    TagLib::MP4::File file(argv[1], false);
    auto *tag = file.tag();
    if(tag->mdtaStatus() != TagLib::MP4::MdtaStatus::Editable)
      throw std::runtime_error("expected editable fixture");
    auto snapshot = tag->mdtaItems();
    auto key = snapshot.front().key();
    if(!tag->removeMdtaItem(key)) throw std::runtime_error("remove failed");
    // Removal compacts the keys table: retaining index needs a distinct clear-values operation.
    if(tag->mdtaItems().size() != snapshot.size() - 1)
      throw std::runtime_error("expected keys compaction");
    TagLib::MP4::Tag detached;
    tag->copyStateTo(detached);
    if(detached.mdtaStatus() != TagLib::MP4::MdtaStatus::Unsupported)
      throw std::runtime_error("detached Tag must have no ilst reference");
    std::cout << "PASS: atomDataType omission, keys compaction, detached Tag refusal\n";
  } catch(const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
