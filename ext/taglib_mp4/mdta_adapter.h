#ifndef TAGLIB_RUBY_MP4_MDTA_ADAPTER_H
#define TAGLIB_RUBY_MP4_MDTA_ADAPTER_H

// Construct the Ruby-owned fields once, independently of the native value layout.
static VALUE taglib_mp4_mdta_entry(const TagLib::String &key, unsigned int index,
                                   unsigned int type, unsigned int locale,
                                   const TagLib::ByteVector &data) {
  VALUE entry = rb_hash_new();
  rb_hash_aset(entry, ID2SYM(rb_intern("key")), taglib_string_to_ruby_string(key));
  rb_hash_aset(entry, ID2SYM(rb_intern("key_index")), UINT2NUM(index));
  rb_hash_aset(entry, ID2SYM(rb_intern("data_type")), UINT2NUM(type));
  rb_hash_aset(entry, ID2SYM(rb_intern("locale")), UINT2NUM(locale));
  rb_hash_aset(entry, ID2SYM(rb_intern("data")), taglib_bytevector_to_ruby_string(data));
  return entry;
}

// Flatten grouped values without changing the existing Ruby order or ownership contract.
static VALUE taglib_mp4_mdta_items(TagLib::MP4::Tag *tag) {
  VALUE result = rb_ary_new();
  for (const auto &item : tag->mdtaItems()) {
#ifdef TAGLIB_RUBY_GROUPED_MDTA
    for (const auto &value : item.values()) {
      rb_ary_push(result, taglib_mp4_mdta_entry(item.key(), item.keyIndex(),
                  value.dataType(), value.locale(), value.data()));
    }
#else
    rb_ary_push(result, taglib_mp4_mdta_entry(item.key, item.keyIndex,
                item.dataType, item.locale, item.data));
#endif
  }
  return result;
}

// Validate every Ruby row before constructing native values or changing the Tag.
static bool taglib_mp4_replace_mdta_items(TagLib::MP4::Tag *tag,
                                        const TagLib::String &key, VALUE values) {
  Check_Type(values, T_ARRAY);
  for (long i = 0; i < RARRAY_LEN(values); ++i) {
    VALUE row = rb_ary_entry(values, i);
    Check_Type(row, T_ARRAY);
    if (RARRAY_LEN(row) != 3)
      rb_raise(rb_eArgError, "mdta value requires type, locale and data");
    NUM2UINT(rb_ary_entry(row, 0));
    NUM2UINT(rb_ary_entry(row, 1));
    Check_Type(rb_ary_entry(row, 2), T_STRING);
  }
#ifdef TAGLIB_RUBY_GROUPED_MDTA
  TagLib::MP4::MdtaValueList items;
#else
  TagLib::MP4::MdtaItemList items;
#endif
  for (long i = 0; i < RARRAY_LEN(values); ++i) {
    VALUE row = rb_ary_entry(values, i);
    VALUE data = rb_ary_entry(row, 2);
    TagLib::ByteVector payload(RSTRING_PTR(data), RSTRING_LEN(data));
#ifdef TAGLIB_RUBY_GROUPED_MDTA
    items.append(TagLib::MP4::MdtaValue(NUM2UINT(rb_ary_entry(row, 0)),
                                     NUM2UINT(rb_ary_entry(row, 1)), payload));
#else
    items.append({TagLib::String(), 0, NUM2UINT(rb_ary_entry(row, 0)),
                  NUM2UINT(rb_ary_entry(row, 1)), payload});
#endif
  }
  return tag->replaceMdtaItems(key, items);
}

// Preserve the single-value setter's replacement contract on the grouped native API.
static bool taglib_mp4_set_mdta_item(TagLib::MP4::Tag *tag, const TagLib::String &key,
                                    unsigned int type, unsigned int locale,
                                    const TagLib::ByteVector &data) {
#ifdef TAGLIB_RUBY_GROUPED_MDTA
  return tag->replaceMdtaItems(key, {TagLib::MP4::MdtaValue(type, locale, data)});
#else
  return tag->setMdtaItem(key, type, locale, data);
#endif
}

// Keep the existing Ruby false-on-missing result although the proposal removal is a no-op.
static bool taglib_mp4_remove_mdta_item(TagLib::MP4::Tag *tag, const TagLib::String &key) {
#ifdef TAGLIB_RUBY_GROUPED_MDTA
  bool found = false;
  for(const auto &item : tag->mdtaItems()) found = found || item.key() == key;
  if(!found) return false;
#endif
  return tag->removeMdtaItem(key);
}

// Legacy native libraries cannot distinguish absence from unsupported structures reliably.
static VALUE taglib_mp4_mdta_status(TagLib::MP4::Tag *tag) {
#ifdef TAGLIB_RUBY_GROUPED_MDTA
  switch(tag->mdtaStatus()) {
    case TagLib::MP4::MdtaStatus::Absent: return ID2SYM(rb_intern("absent"));
    case TagLib::MP4::MdtaStatus::Editable: return ID2SYM(rb_intern("editable"));
    case TagLib::MP4::MdtaStatus::Unsupported: return ID2SYM(rb_intern("unsupported"));
  }
#endif
  return ID2SYM(rb_intern("unknown"));
}
#endif
