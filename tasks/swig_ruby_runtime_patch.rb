# frozen-string-literal: true

SWIG_RUBY_TRACKING_START = '/* Global hash table to store Trackings'
SWIG_RUBY_SAFE_TRACKING_START = '/* Keep a movable weak reference instead of rooting the wrapper itself. */'
SWIG_RUBY_REGISTERED_TRACKING_START = '/* Register borrowed wrappers directly so Ruby updates VALUEs during compaction. */'
SWIG_RUBY_RUNTIME_END = "/* -----------------------------------------------------------------------------\n * Ruby API portion"
SWIG_RUBY_OWNED_ITEM_FACTORIES = %w[
  from_bool
  from_byte
  from_uint
  from_int
  from_long_long
  from_string_list
  from_cover_art_list
  from_byte_vector_list
].freeze

SAFE_SWIG_RUBY_TRACKING_RUNTIME = <<~'CPP'
  /* Register borrowed wrappers directly so Ruby updates VALUEs during compaction. */
  typedef struct {
    VALUE object;
  } swig_ruby_tracking_entry;

  static st_table* swig_ruby_trackings = NULL;

  static VALUE swig_ruby_trackings_count(ID id, VALUE *var) {
    return SWIG2NUM(swig_ruby_trackings->num_entries);
  }

  SWIGRUNTIME void SWIG_RubyRemoveTracking(void* ptr);
  SWIGRUNTIME VALUE SWIG_RubyInstanceFor(void* ptr);

  /* Setup a hash table shared by all SWIG bundles in this process. */
  SWIGRUNTIME void SWIG_RubyInitializeTrackings(void) {
    VALUE trackings_value = Qnil;
    ID trackings_id = rb_intern("@__safetrackings__");
    VALUE verbose = rb_gv_get("VERBOSE");
    rb_gv_set("VERBOSE", Qfalse);
    trackings_value = rb_ivar_get(_mSWIG, trackings_id);
    rb_gv_set("VERBOSE", verbose);

    if (trackings_value == Qnil) {
      swig_ruby_trackings = st_init_numtable();
      rb_ivar_set(_mSWIG, trackings_id, SWIG2NUM(swig_ruby_trackings));
    } else {
      swig_ruby_trackings = (st_table *)NUM2SWIG(trackings_value);
    }

    rb_define_virtual_variable("SWIG_TRACKINGS_COUNT",
                               VALUEFUNC(swig_ruby_trackings_count),
                               SWIG_RUBY_VOID_ANYARGS_FUNC((rb_gvar_setter_t *)NULL));
  }

  /* Track only borrowed wrappers. Ruby-owned wrappers keep their native
     destructor and must remain collectable. */
  SWIGRUNTIME void SWIG_RubyAddTracking(void* ptr, VALUE object) {
    st_data_t old_value;
    swig_ruby_tracking_entry *entry;
    if (!ptr || TYPE(object) != T_DATA || RTYPEDDATA_P(object) ||
        RDATA(object)->dfree != SWIG_RubyRemoveTracking) {
      return;
    }

    if (st_lookup(swig_ruby_trackings, (st_data_t)ptr, &old_value)) {
      if (SWIG_RubyInstanceFor(ptr) == object) {
        return;
      }
      /* SWIG may expose one native pointer through compatible wrapper types. */
      SWIG_RubyRemoveTracking(ptr);
    }

    entry = (swig_ruby_tracking_entry *)malloc(sizeof(*entry));
    if (!entry) {
      rb_raise(rb_eNoMemError, "failed to allocate SWIG tracking entry");
    }
    entry->object = Qnil;
    rb_gc_register_address(&entry->object);
    entry->object = object;
    st_insert(swig_ruby_trackings, (st_data_t)ptr, (st_data_t)entry);
  }

  SWIGRUNTIME VALUE SWIG_RubyInstanceFor(void* ptr) {
    st_data_t value;
    swig_ruby_tracking_entry *entry;

    if (st_lookup(swig_ruby_trackings, (st_data_t)ptr, &value)) {
      entry = (swig_ruby_tracking_entry *)value;
      return entry->object;
    }
    return Qnil;
  }

  /* Remove a tracking entry before the native pointer can be reused. */
  SWIGRUNTIME void SWIG_RubyRemoveTracking(void* ptr) {
    st_data_t key = (st_data_t)ptr;
    st_data_t value;
    swig_ruby_tracking_entry *entry;

    if (!ptr || !st_delete(swig_ruby_trackings, &key, &value)) {
      return;
    }
    entry = (swig_ruby_tracking_entry *)value;
    rb_gc_unregister_address(&entry->object);
    free(entry);
  }

  /* Invalidate a wrapper whose native object was destroyed elsewhere. */
  SWIGRUNTIME void SWIG_RubyUnlinkObjects(void* ptr) {
    VALUE object = SWIG_RubyInstanceFor(ptr);

    if (object != Qnil) {
      DATA_PTR(object) = 0;
    }
    SWIG_RubyRemoveTracking(ptr);
  }

  static int swig_ruby_internal_iterate_callback(st_data_t ptr, st_data_t obj, st_data_t meth) {
    swig_ruby_tracking_entry *entry = (swig_ruby_tracking_entry *)obj;
    ((void (*) (void *, VALUE))meth)((void *)ptr, entry->object);
    return ST_CONTINUE;
  }

  SWIGRUNTIME void SWIG_RubyIterateTrackings(void(*meth)(void* ptr, VALUE obj)) {
    st_foreach(swig_ruby_trackings,
               SWIG_RUBY_INT_ANYARGS_FUNC(swig_ruby_internal_iterate_callback),
               (st_data_t)meth);
  }

  #ifdef __cplusplus
  }
  #endif

CPP

# Regenerate-safe postprocessing for the SWIG runtime and ownership markers.
def patch_swig_ruby_runtime(path)
  source = File.read(path)
  start = source.index(SWIG_RUBY_TRACKING_START) || source.index(SWIG_RUBY_SAFE_TRACKING_START) ||
          source.index(SWIG_RUBY_REGISTERED_TRACKING_START)
  if start
    finish = source.index(SWIG_RUBY_RUNTIME_END, start)
    raise "SWIG tracking runtime markers not found in #{path}" unless finish

    source = source[0...start] + SAFE_SWIG_RUBY_TRACKING_RUNTIME + source[finish..]
  end

  # The generated runtime opens extern "C" before the tracking section.
  # Keep the following Ruby API and C++ declarations outside that linkage block.
  unless source.include?("#endif\n\n/* -----------------------------------------------------------------------------\n * Ruby API portion")
    source.sub!(SWIG_RUBY_RUNTIME_END, "#ifdef __cplusplus\n}\n#endif\n\n#{SWIG_RUBY_RUNTIME_END}")
    raise "SWIG extern C closing marker not found in #{path}" unless source.include?("#ifdef __cplusplus\n}\n#endif\n\n#{SWIG_RUBY_RUNTIME_END}")
  end

  unless source.include?('track = sklass->trackObjects && !own;')
    changed = source.sub!("    track = sklass->trackObjects;\n", "    track = sklass->trackObjects && !own;\n")
    raise "SWIG ownership marker not found in #{path}" unless changed
  end

  # `%newobject` makes factory results own their newly allocated C++ Item.
  # Keep checked-in wrappers correct even when regeneration is skipped locally.
  SWIG_RUBY_OWNED_ITEM_FACTORIES.each do |method|
    pattern = /(SWIGINTERN VALUE\n_wrap_Item_#{method}.*?\n}\n)/m
    match = source.match(pattern)
    next unless match
    next if match[1].include?('SWIG_POINTER_OWN')

    replacement = match[1].sub(
      /(vresult = SWIG_NewPointerObj\([^;]+?), 0 \|  0 \);/,
      '\\1, SWIG_POINTER_OWN );'
    )
    raise "SWIG Item factory ownership marker not found for #{method} in #{path}" if replacement == match[1]

    source.sub!(match[1], replacement)
  end

  unless source.include?('DATA_PTR(self) = 0;')
    close_pattern = /^([ \t]+)(TagLib_[A-Za-z0-9_]*File(?:Ref)?_close\(arg1\);)$/
    close_count = source.scan(close_pattern).length
    raise "multiple SWIG close wrapper markers found in #{path}" if close_count > 1

    if close_count == 1
      source.sub!(close_pattern) do
        "#{$1}DATA_PTR(self) = 0;\n#{$1}#{$2}"
      end
    end
  end

  File.write(path, source)
end
