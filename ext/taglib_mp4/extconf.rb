# frozen-string-literal: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..'))
require 'extconf_common'

mdta_api_check = <<~CPP
  #include <taglib/mp4tag.h>
  using Tag = TagLib::MP4::Tag;
  void probe(Tag &source, Tag &destination) {
    source.copyStateTo(destination);
    source.mdtaItems();
    source.setMdtaItem(TagLib::String("probe"), 1, 0, TagLib::ByteVector("value"));
    source.removeMdtaItem(TagLib::String("probe"));
  }
  int main() {
    Tag source;
    Tag destination;
    probe(source, destination);
    return 0;
  }
CPP

original_cflags = $CFLAGS
begin
  # mkmf's normal probe is a .c source and therefore uses the C compiler.
  # TagLib's headers are C++, so force this one probe into C++ mode.
  $CFLAGS = "#{original_cflags} -x c++"
  mdta_api_available = try_link(mdta_api_check)
ensure
  $CFLAGS = original_cflags
end

unless mdta_api_available
  error 'TagLib mdta support is required. Build and select the patched TagLib from patches/taglib.'
end

create_makefile('taglib_mp4')
