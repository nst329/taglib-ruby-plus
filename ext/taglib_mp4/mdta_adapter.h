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
// Report the real keys table rather than reconstructing it from visible values.
static VALUE taglib_mp4_metadata_keys(TagLib::MP4::Tag *tag) {
#ifdef TAGLIB_RUBY_METADATA_SNAPSHOT
  return taglib_string_list_to_ruby_array(tag->metadataKeys());
#else
  return Qnil;
#endif
}

static VALUE taglib_mp4_metadata_status(TagLib::MP4::Tag *tag) {
#ifdef TAGLIB_RUBY_METADATA_SNAPSHOT
  const char *states[] = {"absent", "editable", "unsupported"};
  const int status = tag->metadataStatus();
  return ID2SYM(rb_intern(status >= 0 && status <= 2 ? states[status] : "unknown"));
#else
  return ID2SYM(rb_intern("unknown"));
#endif
}

static bool taglib_mp4_metadata_item_supported(TagLib::MP4::Tag *tag,
                                               const TagLib::String &key,
                                               const TagLib::MP4::Item &item) {
#ifdef TAGLIB_RUBY_METADATA_SNAPSHOT
  return tag->metadataItemSupported(key, item);
#else
  return false;
#endif
}

// Ruby has already validated the full snapshot; convert groups without touching the live Tag.
static bool taglib_mp4_restore_metadata(TagLib::MP4::Tag *tag,
                                       const TagLib::MP4::ItemMap &items, VALUE groups) {
#ifdef TAGLIB_RUBY_METADATA_SNAPSHOT
  Check_Type(groups, T_ARRAY);
  // Complete shape/type validation before allocating native lists.
  for(long i = 0; i < RARRAY_LEN(groups); ++i) {
    VALUE group = rb_ary_entry(groups, i);
    Check_Type(group, T_ARRAY);
    if(RARRAY_LEN(group) != 3) rb_raise(rb_eArgError, "invalid mdta group");
    Check_Type(rb_ary_entry(group, 0), T_STRING);
    Check_Type(rb_ary_entry(group, 2), T_ARRAY);
    VALUE rows = rb_ary_entry(group, 2);
    for(long j = 0; j < RARRAY_LEN(rows); ++j) {
      VALUE row = rb_ary_entry(rows, j);
      Check_Type(row, T_ARRAY);
      if(RARRAY_LEN(row) != 3) rb_raise(rb_eArgError, "invalid mdta value");
      NUM2UINT(rb_ary_entry(row, 0)); NUM2UINT(rb_ary_entry(row, 1));
      Check_Type(rb_ary_entry(row, 2), T_STRING);
    }
  }
  TagLib::StringList keys;
  TagLib::MP4::MdtaItemList values;
  for(long i = 0; i < RARRAY_LEN(groups); ++i) {
    VALUE group = rb_ary_entry(groups, i);
    const auto key = ruby_string_to_taglib_string(rb_ary_entry(group, 0));
    keys.append(key);
    VALUE rows = rb_ary_entry(group, 2);
#ifdef TAGLIB_RUBY_GROUPED_MDTA
    TagLib::MP4::MdtaValueList sequence;
#endif
    for(long j = 0; j < RARRAY_LEN(rows); ++j) {
      VALUE row = rb_ary_entry(rows, j);
      const auto data = ruby_string_to_taglib_bytevector(rb_ary_entry(row, 2));
#ifdef TAGLIB_RUBY_GROUPED_MDTA
      sequence.append(TagLib::MP4::MdtaValue(NUM2UINT(rb_ary_entry(row, 0)), NUM2UINT(rb_ary_entry(row, 1)), data));
#else
      values.append({key, 0, NUM2UINT(rb_ary_entry(row, 0)), NUM2UINT(rb_ary_entry(row, 1)), data});
#endif
    }
#ifdef TAGLIB_RUBY_GROUPED_MDTA
    values.append(TagLib::MP4::MdtaItem(key, 0, sequence));
#endif
  }
  // Hold old nodes alive until successful commit, then invalidate only borrowed item wrappers.
  const auto oldItems = tag->itemMap();
  if(!tag->restoreMetadata(items, keys, values)) return false;
  for(auto it = oldItems.begin(); it != oldItems.end(); ++it)
    unlink_taglib_mp4_item_map_iterator(it);
  return true;
#else
  return false;
#endif
}

// Length-aware strings preserve embedded NUL without changing legacy string-list getters.
static VALUE taglib_mp4_snapshot_strings(const TagLib::MP4::Item &item) {
  VALUE rows = rb_ary_new();
  for(const auto &text : item.toStringList()) {
    const auto bytes = text.data(TagLib::String::UTF8);
    VALUE value = rb_str_new(bytes.data(), bytes.size());
    ASSOCIATE_UTF8_ENCODING(value);
    rb_ary_push(rows, value);
  }
  return rows;
}

static void taglib_mp4_set_snapshot_strings(TagLib::MP4::Item *item, VALUE rows) {
  Check_Type(rows, T_ARRAY);
  for(long i = 0; i < RARRAY_LEN(rows); ++i) Check_Type(rb_ary_entry(rows, i), T_STRING);
  TagLib::StringList strings;
  for(long i = 0; i < RARRAY_LEN(rows); ++i)
    {
      VALUE value = rb_ary_entry(rows, i);
      strings.append(TagLib::String(std::string(RSTRING_PTR(value), RSTRING_LEN(value)), TagLib::String::UTF8));
    }
  *item = TagLib::MP4::Item(strings);
}
#endif
