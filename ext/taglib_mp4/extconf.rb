# frozen-string-literal: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..'))
require 'extconf_common'

# Verify the selected layout and binding-only state transfer by linking their actual symbols.
def mdta_api_probe(grouped:)
  values_type = grouped ? 'MdtaValueList' : 'MdtaItemList'
  layout_call = grouped ? 'source.mdtaStatus();' :
    'source.setMdtaItem(TagLib::String("probe"), 1, 0, TagLib::ByteVector("value"));'
  <<~CPP
    #include <taglib/mp4tag.h>
    using Tag = TagLib::MP4::Tag;
    void probe(Tag &source, Tag &destination) {
      source.copyStateTo(destination);
      source.applyChanges(TagLib::MP4::ItemMap(), TagLib::StringList(), TagLib::StringList());
      source.mdtaItems();
      #{layout_call}
      source.replaceMdtaItems(TagLib::String("probe"), TagLib::MP4::#{values_type}());
      source.removeMdtaItem(TagLib::String("probe"));
    }
    int main() {
      Tag source;
      Tag destination;
      probe(source, destination);
      return 0;
    }
  CPP
end

original_cflags = $CFLAGS
begin
  # mkmf's normal probe is a .c source and therefore uses the C compiler.
  # TagLib's headers are C++, so force this one probe into C++ mode.
  $CFLAGS = "#{original_cflags} -x c++ -std=c++17"
  grouped_api_available = try_link(mdta_api_probe(grouped: true))
  mdta_api_available = grouped_api_available || try_link(mdta_api_probe(grouped: false))
  $defs << '-DTAGLIB_RUBY_GROUPED_MDTA' if grouped_api_available
  snapshot_probe = <<~CPP
    #include <taglib/mp4tag.h>
    int main() {
      TagLib::MP4::Tag tag;
      tag.metadataStatus(); tag.metadataKeys();
      tag.metadataItemSupported(TagLib::String("desc"), TagLib::MP4::Item());
      tag.restoreMetadata(TagLib::MP4::ItemMap(), TagLib::StringList(), TagLib::MP4::MdtaItemList());
      return 0;
    }
  CPP
  $defs << '-DTAGLIB_RUBY_METADATA_SNAPSHOT' if try_link(snapshot_probe)
ensure
  $CFLAGS = original_cflags
end

unless mdta_api_available
  error 'TagLib mdta support and Ruby state transfer are required. Use the legacy patch, or both proposal patches 0001 and 0002.'
end

create_makefile('taglib_mp4')
