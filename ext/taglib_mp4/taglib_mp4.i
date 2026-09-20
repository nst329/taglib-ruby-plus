%module "TagLib::MP4"
%{
#include <cstdlib>
#include <cstring>
#include <taglib/taglib.h>
#include <taglib/mp4file.h>
#include <taglib/mp4properties.h>
#include <taglib/mp4tag.h>
#include <taglib/mp4atom.h>
#include <taglib/mp4nerochapterlist.h>
#include <taglib/mp4qtchapterlist.h>
%}

%include "../taglib_base/includes.i"
%import(module="taglib_base") "../taglib_base/taglib_base.i"

%{
static void unlink_taglib_mp4_item_map_iterator(const TagLib::MP4::ItemMap::ConstIterator &it) {
  const TagLib::MP4::Item *item = &(it->second);
  TagLib::MP4::CoverArtList list = item->toCoverArtList();
  for (TagLib::MP4::CoverArtList::ConstIterator it = list.begin(); it != list.end(); it++) {
    void *cover_art = (void *) &(*it);
    SWIG_RubyUnlinkObjects(cover_art);
    SWIG_RubyRemoveTracking(cover_art);
  }
  SWIG_RubyUnlinkObjects((void *)item);
  SWIG_RubyRemoveTracking((void *)item);
}

VALUE taglib_mp4_item_int_pair_to_ruby_array(const TagLib::MP4::Item::IntPair &int_pair) {
  VALUE ary = rb_ary_new3(2, INT2NUM(int_pair.first), INT2NUM(int_pair.second));
  return ary;
}

VALUE taglib_cover_art_list_to_ruby_array(const TagLib::MP4::CoverArtList & list) {
  VALUE ary = rb_ary_new2(list.size());
  for (TagLib::MP4::CoverArtList::ConstIterator it = list.begin(); it != list.end(); it++) {
    VALUE c = SWIG_NewPointerObj((void *) &(*it), SWIGTYPE_p_TagLib__MP4__CoverArt, 0);
    rb_ary_push(ary, c);
  }
  return ary;
}

TagLib::MP4::CoverArtList ruby_array_to_taglib_cover_art_list(VALUE ary) {
  TagLib::MP4::CoverArtList result = TagLib::MP4::CoverArtList();
  if (NIL_P(ary)) {
    return result;
  }
  for (long i = 0; i < RARRAY_LEN(ary); i++) {
    VALUE e = rb_ary_entry(ary, i);
    TagLib::MP4::CoverArt *c;
    SWIG_ConvertPtr(e, (void **) &c, SWIGTYPE_p_TagLib__MP4__CoverArt, 1);
    result.append(*c);
  }
  return result;
}

enum TagLibRubyMP4ChapterStyle {
  TAGLIB_RUBY_MP4_STYLE_NONE = 0,
  TAGLIB_RUBY_MP4_STYLE_NERO = 1,
  TAGLIB_RUBY_MP4_STYLE_QUICKTIME = 2,
  TAGLIB_RUBY_MP4_STYLE_BOTH = 3,
  TAGLIB_RUBY_MP4_STYLE_ANY = 4
};

static VALUE taglib_mp4_chapter_class() {
  return rb_path2class("TagLib::MP4::Chapter");
}

static VALUE taglib_mp4_chapter_to_ruby(const TagLib::MP4::Chapter &chapter) {
  VALUE title = taglib_string_to_ruby_string(chapter.title());
  VALUE start_time = LL2NUM(chapter.startTime());
  return rb_funcall(taglib_mp4_chapter_class(), rb_intern("new"), 2, start_time, title);
}

// Convert TagLib's value-owned chapter list without exposing native chapter objects to Ruby.
static VALUE taglib_mp4_chapters_to_ruby(const TagLib::MP4::ChapterList &chapters) {
  VALUE result = rb_ary_new2(chapters.size());
  for (TagLib::MP4::ChapterList::ConstIterator it = chapters.begin(); it != chapters.end(); ++it) {
    rb_ary_push(result, taglib_mp4_chapter_to_ruby(*it));
  }
  return result;
}

static TagLib::MP4::ChapterList taglib_mp4_chapters_from_ruby(VALUE value, TagLib::MP4::File *file) {
  Check_Type(value, T_ARRAY);
  TagLib::MP4::ChapterList result;
  long long previous_start_time = -1;
  TagLib::AudioProperties *properties = file->audioProperties();
  const int length = properties ? properties->lengthInMilliseconds() : 0;

  for (long i = 0; i < RARRAY_LEN(value); ++i) {
    VALUE entry = rb_ary_entry(value, i);
    if (!rb_obj_is_kind_of(entry, taglib_mp4_chapter_class())) {
      rb_raise(rb_eArgError, "chapter must be a TagLib::MP4::Chapter");
    }
    if (!rb_respond_to(entry, rb_intern("start_time")) || !rb_respond_to(entry, rb_intern("title"))) {
      rb_raise(rb_eArgError, "chapter must respond to start_time and title");
    }

    VALUE start_value = rb_funcall(entry, rb_intern("start_time"), 0);
    if (!RB_INTEGER_TYPE_P(start_value)) {
      rb_raise(rb_eArgError, "chapter start_time must be an Integer");
    }
    long long start_time = NUM2LL(start_value);
    if (start_time < 0) {
      rb_raise(rb_eArgError, "chapter start_time must not be negative");
    }
    if (i > 0 && start_time <= previous_start_time) {
      rb_raise(rb_eArgError, "chapter start_time must be strictly increasing");
    }
    if (length > 0 && start_time > length) {
      rb_raise(rb_eArgError, "chapter start_time must not exceed the file duration");
    }

    VALUE title = rb_funcall(entry, rb_intern("title"), 0);
    Check_Type(title, T_STRING);
    if (rb_enc_get_index(title) != rb_utf8_encindex() ||
        !RTEST(rb_funcall(title, rb_intern("valid_encoding?"), 0))) {
      rb_raise(rb_eArgError, "chapter title must be valid UTF-8");
    }
    if (memchr(RSTRING_PTR(title), '\0', RSTRING_LEN(title)) != NULL) {
      rb_raise(rb_eArgError, "chapter title must not contain NUL bytes");
    }

    result.append(TagLib::MP4::Chapter(ruby_string_to_taglib_string(title), start_time));
    previous_start_time = start_time;
  }
  return result;
}

static bool taglib_mp4_chapter_lists_equal(const TagLib::MP4::ChapterList &left,
                                           const TagLib::MP4::ChapterList &right) {
  if (left.size() != right.size()) {
    return false;
  }
  TagLib::MP4::ChapterList::ConstIterator lit = left.begin();
  TagLib::MP4::ChapterList::ConstIterator rit = right.begin();
  for (; lit != left.end(); ++lit, ++rit) {
    if (lit->title() != rit->title() ||
        std::llabs(lit->startTime() - rit->startTime()) > 1) {
      return false;
    }
  }
  return true;
}

// Read Nero chapters through a short-lived holder and return an independent list copy.
static TagLib::MP4::ChapterList taglib_mp4_read_nero(TagLib::MP4::File *file, bool *present = NULL) {
  TagLib::MP4::NeroChapterList holder;
  bool exists = holder.read(file);
  if (present) {
    *present = exists;
  }
  return holder.chapters();
}

// Read QuickTime chapters through a short-lived holder and return an independent list copy.
static TagLib::MP4::ChapterList taglib_mp4_read_quicktime(TagLib::MP4::File *file, bool *present = NULL) {
  TagLib::MP4::QtChapterList holder;
  bool exists = holder.read(file);
  if (present) {
    *present = exists;
  }
  return holder.chapters();
}

// Report which on-disk chapter representations exist, without choosing a representation.
static VALUE taglib_mp4_chapter_style(TagLib::MP4::File *file) {
  bool nero_present = false;
  bool quicktime_present = false;
  taglib_mp4_read_nero(file, &nero_present);
  taglib_mp4_read_quicktime(file, &quicktime_present);
  if (nero_present && quicktime_present) {
    return ID2SYM(rb_intern("both"));
  }
  if (nero_present) {
    return ID2SYM(rb_intern("nero"));
  }
  if (quicktime_present) {
    return ID2SYM(rb_intern("quicktime"));
  }
  return ID2SYM(rb_intern("none"));
}

// Read the requested representation and enforce conflict detection only for the common API.
static VALUE taglib_mp4_chapters(TagLib::MP4::File *file, int style) {
  if (style == TAGLIB_RUBY_MP4_STYLE_NERO) {
    return taglib_mp4_chapters_to_ruby(taglib_mp4_read_nero(file));
  }
  if (style == TAGLIB_RUBY_MP4_STYLE_QUICKTIME) {
    return taglib_mp4_chapters_to_ruby(taglib_mp4_read_quicktime(file));
  }

  bool conflict = false;
  {
    bool nero_present = false;
    bool quicktime_present = false;
    TagLib::MP4::ChapterList nero = taglib_mp4_read_nero(file, &nero_present);
    TagLib::MP4::ChapterList quicktime = taglib_mp4_read_quicktime(file, &quicktime_present);
    conflict = nero_present && quicktime_present && !taglib_mp4_chapter_lists_equal(nero, quicktime);
  }
  if (conflict) {
    VALUE error = rb_path2class("TagLib::MP4::ChapterConflictError");
    rb_raise(error, "Nero and QuickTime chapters differ");
  }

  bool nero_present = false;
  TagLib::MP4::ChapterList chapters = taglib_mp4_read_nero(file, &nero_present);
  if (!nero_present) {
    chapters = taglib_mp4_read_quicktime(file);
  }
  return taglib_mp4_chapters_to_ruby(chapters);
}

static VALUE taglib_mp4_mdta_items(TagLib::MP4::Tag *tag) {
  VALUE result = rb_ary_new2(tag->mdtaItems().size());
  for (const auto &item : tag->mdtaItems()) {
    VALUE entry = rb_hash_new();
    rb_hash_aset(entry, ID2SYM(rb_intern("key")), taglib_string_to_ruby_string(item.key));
    rb_hash_aset(entry, ID2SYM(rb_intern("key_index")), UINT2NUM(item.keyIndex));
    rb_hash_aset(entry, ID2SYM(rb_intern("data_type")), UINT2NUM(item.dataType));
    rb_hash_aset(entry, ID2SYM(rb_intern("locale")), UINT2NUM(item.locale));
    rb_hash_aset(entry, ID2SYM(rb_intern("data")), taglib_bytevector_to_ruby_string(item.data));
    rb_ary_push(result, entry);
  }
  return result;
}

static void taglib_mp4_set_chapters(TagLib::MP4::File *file, VALUE value, int style) {
  TagLib::MP4::ChapterList chapters = taglib_mp4_chapters_from_ruby(value, file);
  if (style == TAGLIB_RUBY_MP4_STYLE_NERO || style == TAGLIB_RUBY_MP4_STYLE_BOTH) {
    file->setNeroChapters(chapters);
  }
  if (style == TAGLIB_RUBY_MP4_STYLE_QUICKTIME || style == TAGLIB_RUBY_MP4_STYLE_BOTH) {
    file->setQtChapters(chapters);
  }
}

static bool taglib_mp4_remove_chapters(TagLib::MP4::File *file, int style) {
  TagLib::MP4::ChapterList empty;
  if (style == TAGLIB_RUBY_MP4_STYLE_NERO || style == TAGLIB_RUBY_MP4_STYLE_BOTH) {
    file->setNeroChapters(empty);
  }
  if (style == TAGLIB_RUBY_MP4_STYLE_QUICKTIME || style == TAGLIB_RUBY_MP4_STYLE_BOTH) {
    file->setQtChapters(empty);
  }
  return true;
}

static bool taglib_mp4_save_chapter_list(TagLib::MP4::File *file,
                                         const TagLib::MP4::ChapterList &desired,
                                         bool nero) {
  bool present = false;
  TagLib::MP4::ChapterList current = nero
    ? taglib_mp4_read_nero(file, &present)
    : taglib_mp4_read_quicktime(file, &present);
  if (present && taglib_mp4_chapter_lists_equal(current, desired)) {
    return true;
  }
  if (desired.isEmpty()) {
    return nero ? TagLib::MP4::NeroChapterList().remove(file)
                : TagLib::MP4::QtChapterList().remove(file);
  }
  if (nero) {
    TagLib::MP4::NeroChapterList holder;
    holder.setChapters(desired);
    return holder.write(file);
  }
  TagLib::MP4::QtChapterList holder;
  holder.setChapters(desired);
  return holder.write(file);
}

static bool taglib_mp4_save_chapters(TagLib::MP4::File *file) {
  if (file->readOnly() || !file->isValid()) {
    VALUE error = rb_path2class("TagLib::MP4::ChapterSaveError");
    rb_raise(error, "MP4 file is not writable or valid");
  }

  bool nero_present = false;
  bool quicktime_present = false;
  TagLib::MP4::ChapterList nero = taglib_mp4_read_nero(file, &nero_present);
  TagLib::MP4::ChapterList quicktime = taglib_mp4_read_quicktime(file, &quicktime_present);
  TagLib::MP4::ChapterList desired_nero = file->neroChapters();
  TagLib::MP4::ChapterList desired_quicktime = file->qtChapters();
  bool nero_changed = !taglib_mp4_chapter_lists_equal(nero, desired_nero) || nero_present != !desired_nero.isEmpty();
  bool quicktime_changed = !taglib_mp4_chapter_lists_equal(quicktime, desired_quicktime) || quicktime_present != !desired_quicktime.isEmpty();

  if (nero_changed && !taglib_mp4_save_chapter_list(file, desired_nero, true)) {
    VALUE error = rb_path2class("TagLib::MP4::ChapterSaveError");
    rb_raise(error, "failed to save Nero chapters");
  }
  if (quicktime_changed && !taglib_mp4_save_chapter_list(file, desired_quicktime, false)) {
    VALUE error = rb_path2class("TagLib::MP4::ChapterSaveError");
    rb_raise(error, "failed to save QuickTime chapters");
  }
  return true;
}
%}

// Ignore useless types that SWIG picks up globally.
%ignore Iterator;
%ignore ConstIterator;

%ignore TagLib::Map::operator[];
%ignore TagLib::Map::operator=;
%alias TagLib::Map::contains "include?,has_key?";
%include <taglib/tmap.h>

namespace TagLib {
  class ByteVectorList;
  namespace MP4 {
    class Item;
    class CoverArtList;
    class Properties;
  }
}

%ignore TagLib::MP4::Properties::length; // Deprecated.
%include <taglib/mp4properties.h>

%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::begin;
%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::end;
%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::cbegin;
%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::cend;
%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::insert;
%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::find;
// We will create a safe version of these below in an %extend
%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::clear;
%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::erase(Iterator);
%ignore TagLib::Map<TagLib::String, TagLib::MP4::Item>::erase(const TagLib::String &);


%typemap(out) TagLib::MP4::CoverArtList {
  $result = taglib_cover_art_list_to_ruby_array($1);
}
%typemap(in) TagLib::MP4::CoverArtList (TagLib::MP4::CoverArtList tmp) {
  tmp = ruby_array_to_taglib_cover_art_list($input);
  $1 = &tmp;
}
%apply TagLib::MP4::CoverArtList { TagLib::MP4::CoverArtList &, const TagLib::MP4::CoverArtList & };
%ignore TagLib::MP4::CoverArt::operator=;
%ignore TagLib::MP4::CoverArt::swap;
%include <taglib/mp4coverart.h>

%typemap(out) TagLib::MP4::Item::IntPair {
  $result = taglib_mp4_item_int_pair_to_ruby_array($1);
}
%ignore TagLib::MP4::Item::operator=;
%ignore TagLib::MP4::Item::swap;

%ignore TagLib::MP4::Item::atomDataType;
%ignore TagLib::MP4::Item::setAtomDataType;

%warnfilter(SWIGWARN_PARSE_NAMED_NESTED_CLASS) IntPair;
%ignore ItemMap;
// TagLib 2.3 adds STEM values; expose them only after a dedicated safe API.
%ignore TagLib::MP4::Stem;
%ignore TagLib::MP4::Item::Item(const TagLib::MP4::Stem &);
%ignore TagLib::MP4::Item::Item(const Stem &);
%ignore TagLib::MP4::Item::Item(Stem const &);
%ignore TagLib::MP4::Item::toStem;
%include <taglib/mp4item.h>

%ignore TagLib::MP4::MdtaItem;
%ignore TagLib::MP4::MdtaItemList;

namespace TagLib {
  namespace MP4 {
    %template(ItemMap) ::TagLib::Map<String, Item>;
  }
}

%ignore TagLib::MP4::Tag::itemListMap; // Deprecated.
%ignore TagLib::MP4::Tag::copyStateTo;
%ignore TagLib::MP4::Tag::applyChanges;

%rename("__getitem__") TagLib::MP4::Tag::item;

// We will create a safe version of these below in an %extend
// TagLib::MP4::Tag::item does not need to be reimplemented as it return an Item by value.
%ignore TagLib::MP4::Tag::setItem;
%ignore TagLib::MP4::Tag::removeItem;

%include <taglib/mp4tag.h>

%freefunc TagLib::MP4::File "free_taglib_mp4_file";

// Ignore IOStream and all the constructors using it.
%ignore IOStream;
%ignore TagLib::MP4::File::File(IOStream *, bool, Properties::ReadStyle);
%ignore TagLib::MP4::File::File(IOStream *, bool, Properties::ReadStyle, ItemFactory *);
%ignore TagLib::MP4::File::File(IOStream *, bool);
%ignore TagLib::MP4::File::File(IOStream *);
%ignore TagLib::MP4::File::isSupported(IOStream *);

// Ignore the unified property interface.
%ignore TagLib::MP4::File::properties;
%ignore TagLib::MP4::File::setProperties;
%ignore TagLib::MP4::File::removeUnsupportedProperties;
// ChapterList is copied through the safe Ruby Chapter API below.
%ignore TagLib::MP4::ChapterList;
%ignore TagLib::MP4::File::neroChapters;
%ignore TagLib::MP4::File::setNeroChapters;
%ignore TagLib::MP4::File::qtChapters;
%ignore TagLib::MP4::File::setQtChapters;

%rename("mp4_tag?") TagLib::MP4::File::hasMP4Tag;
%include <taglib/mp4file.h>

// Unlink Ruby objects from the deleted C++ objects. Otherwise Ruby code
// that calls a method on a tag after the file is deleted segfaults.
%begin %{
  static void free_taglib_mp4_file(void *ptr);
%}
%header %{
  static void free_taglib_mp4_file(void *ptr) {
    TagLib::MP4::File *file = (TagLib::MP4::File *) ptr;

    TagLib::MP4::Tag *tag = file->tag();
    if (tag) {
      TagLib::MP4::ItemMap *item_list_map = const_cast<TagLib::MP4::ItemMap *>(&(tag->itemMap()));
      if (item_list_map) {
        for (TagLib::MP4::ItemMap::Iterator it = item_list_map->begin(); it != item_list_map->end(); it++) {
          unlink_taglib_mp4_item_map_iterator(it);
        }

        SWIG_RubyUnlinkObjects(item_list_map);
        SWIG_RubyRemoveTracking(item_list_map);
      }

      SWIG_RubyUnlinkObjects(tag);
      SWIG_RubyRemoveTracking(tag);
    }

    TagLib::MP4::Properties *properties = file->audioProperties();
    if (properties) {
      SWIG_RubyUnlinkObjects(properties);
      SWIG_RubyRemoveTracking(properties);
    }

    SWIG_RubyUnlinkObjects(ptr);
    SWIG_RubyRemoveTracking(ptr);

    delete file;
  }
%}

namespace TagLib {
  %extend Map<String, MP4::Item> {
    VALUE to_a() {
      VALUE ary = rb_ary_new2($self->size());
      for (TagLib::MP4::ItemMap::Iterator it = $self->begin(); it != $self->end(); it++) {
        TagLib::String string = it->first;
        TagLib::MP4::Item *item = &(it->second);
        VALUE pair = rb_ary_new2(2);
        rb_ary_push(pair, taglib_string_to_ruby_string(string));
        rb_ary_push(pair, SWIG_NewPointerObj(item, SWIGTYPE_p_TagLib__MP4__Item, 0));
        rb_ary_push(ary, pair);
      }
      return ary;
    }

    VALUE to_h() {
      VALUE hsh = rb_hash_new();
      for (TagLib::MP4::ItemMap::Iterator it = $self->begin(); it != $self->end(); it++) {
        rb_hash_aset(hsh,
                     taglib_string_to_ruby_string(it->first),
                     SWIG_NewPointerObj(&(it->second), SWIGTYPE_p_TagLib__MP4__Item, 0));
      }
      return hsh;
    }

    VALUE fetch(const String &string) {
      TagLib::MP4::ItemMap::Iterator it = $self->find(string);
      VALUE result = Qnil;
      if (it != $self->end()) {
        TagLib::MP4::Item *item = &(it->second);
        result = SWIG_NewPointerObj(item, SWIGTYPE_p_TagLib__MP4__Item, 0);
      }
      return result;
    }

    VALUE _clear() {
      for (TagLib::MP4::ItemMap::Iterator it = $self->begin(); it != $self->end(); it++) {
        unlink_taglib_mp4_item_map_iterator(it);
      }
      $self->clear();
      return Qnil;
    }

    VALUE erase(const String &string) {
      TagLib::MP4::ItemMap::Iterator it = $self->find(string);
      if (it != $self->end()) {
        unlink_taglib_mp4_item_map_iterator(it);
        $self->erase(it);
      }
      return Qnil;
    }

    VALUE _insert(const String &string, const MP4::Item &item) {
      TagLib::MP4::ItemMap::Iterator it = $self->find(string);
      if (it != $self->end()) {
        unlink_taglib_mp4_item_map_iterator(it);
      }
      $self->insert(string, item);
      return Qnil;
    }
  }
}

%extend TagLib::MP4::Tag {
  void _copy_state_to(TagLib::MP4::Tag *destination) {
    $self->copyStateTo(*destination);
  }

  bool _apply_changes(const TagLib::MP4::ItemMap &set_items,
                      const TagLib::StringList &remove_items,
                      const TagLib::StringList &remove_mdta_keys) {
    return $self->applyChanges(set_items, remove_items, remove_mdta_keys);
  }

  VALUE _mdta_items() {
    return taglib_mp4_mdta_items($self);
  }

  bool _set_mdta_item(const String &key, unsigned int data_type,
                      unsigned int locale, const ByteVector &data) {
    return $self->setMdtaItem(key, data_type, locale, data);
  }

  bool _remove_mdta_item(const String &key) {
    return $self->removeMdtaItem(key);
  }

  VALUE __setitem__(const String& string, const MP4::Item &item) {
    TagLib::MP4::ItemMap::ConstIterator it = $self->itemMap().find(string);
    if (it != $self->itemMap().end()) {
      unlink_taglib_mp4_item_map_iterator(it);
    }
    $self->setItem(string, item);
    return Qnil;
  }

  VALUE remove_item(const String& string) {
    TagLib::MP4::ItemMap::ConstIterator it = $self->itemMap().find(string);
    if (it != $self->itemMap().end()) {
      unlink_taglib_mp4_item_map_iterator(it);
      $self->removeItem(string);
    }
    return Qnil;
  }

}

%extend TagLib::MP4::Item {
  %newobject from_bool;
  static TagLib::MP4::Item * from_bool(bool q) {
    return new TagLib::MP4::Item(q);
  }

  %newobject from_byte;
  static TagLib::MP4::Item * from_byte(unsigned char n) {
    return new TagLib::MP4::Item(n);
  }

  %newobject from_uint;
  static TagLib::MP4::Item * from_uint(unsigned int n) {
    return new TagLib::MP4::Item(n);
  }

  %newobject from_int;
  static TagLib::MP4::Item * from_int(int n) {
    return new TagLib::MP4::Item(n);
  }

  %newobject from_long_long;
  static TagLib::MP4::Item * from_long_long(long long n) {
    return new TagLib::MP4::Item(n);
  }

  %newobject from_string_list;
  static TagLib::MP4::Item * from_string_list(const TagLib::StringList &string_list) {
   return new TagLib::MP4::Item(string_list);
  }

  %newobject from_cover_art_list;
  static TagLib::MP4::Item * from_cover_art_list(const TagLib::MP4::CoverArtList &cover_art_list) {
    return new TagLib::MP4::Item(cover_art_list);
  }

  %newobject from_byte_vector_list;
  static TagLib::MP4::Item * from_byte_vector_list(const TagLib::ByteVectorList &byte_vector_list) {
    return new TagLib::MP4::Item(byte_vector_list);
  }
}

%exception TagLib::MP4::File::close {
  DATA_PTR(self) = 0;
  $action
}
%extend TagLib::MP4::File {
  void close() {
    free_taglib_mp4_file($self);
  }

  VALUE _chapter_style() {
    return taglib_mp4_chapter_style($self);
  }

  VALUE _chapters(int style) {
    return taglib_mp4_chapters($self, style);
  }

  void _set_chapters(VALUE chapters, int style) {
    taglib_mp4_set_chapters($self, chapters, style);
  }

  void _validate_chapters(VALUE chapters) {
    taglib_mp4_chapters_from_ruby(chapters, $self);
  }

  VALUE _remove_chapters(int style) {
    if (!taglib_mp4_remove_chapters($self, style)) {
      VALUE error = rb_path2class("TagLib::MP4::ChapterSaveError");
      rb_raise(error, "failed to remove chapters");
    }
    return Qtrue;
  }

  VALUE _save_chapters() {
    return taglib_mp4_save_chapters($self) ? Qtrue : Qfalse;
  }
}

// vim: set filetype=cpp sw=2 ts=2 expandtab:
