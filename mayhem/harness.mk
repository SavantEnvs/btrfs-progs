# Links the mayhem/fuzz_main.c wrapper against the sanitized project objects. btrfs.o must have been
# built with btrfs_cflags=-Dmain=btrfs_original_main, image/main.o with image_main_cflags=-Dmain=image_original_main
# and convert/main.o with convert_main_cflags=-Dmain=convert_original_main.
# Use as: make -f Makefile -f mayhem/harness.mk fuzz-bins
FUZZ_BINS = btrfs_check:1:btrfs btrfs_inspect:2:btrfs btrfs_restore:3:btrfs btrfs_receive:4:btrfs btrfs_image:5:image btrfs_convert:6:convert btrfs_rescue:7:btrfs
FUZZ_OUT ?= $(CURDIR)
FUZZ_DEPS_btrfs = btrfs.o $(objects) $(cmds_objects) libbtrfsutil.a
FUZZ_DEPS_image = $(image_objects) $(objects) libbtrfsutil.a
FUZZ_DEPS_convert = $(convert_objects) $(objects) libbtrfsutil.a
FUZZ_LIBS_convert = $(btrfs_convert_libs)
FUZZ_BASE_convert = base_ext.sparse

fuzz-bins: $(foreach b,$(FUZZ_BINS),fuzz-bin-$(firstword $(subst :, ,$(b))))

define fuzz_bin_rule
fuzz-bin-$(1): mayhem/fuzz_main.c mayhem/$$(or $$(FUZZ_BASE_$(3)),base.sparse) $$(FUZZ_DEPS_$(3))
	$$(CC) $$(CFLAGS) -DFUZZ_TARGET=$(2) -DBASE_SPARSE_PATH='"$$(CURDIR)/mayhem/$$(or $$(FUZZ_BASE_$(3)),base.sparse)"' \
	    -c mayhem/fuzz_main.c -o $$(FUZZ_OUT)/$(1).fuzz_main.o
	$$(CC) -o $$(FUZZ_OUT)/$(1) $$(FUZZ_OUT)/$(1).fuzz_main.o $$(FUZZ_LSAN_OFF) $$(FUZZ_DEPS_$(3)) \
	    $$(LDFLAGS) $$(FUZZ_LIBS_$(3)) $$(LIBS) $$(LIBS_COMP)
	rm -f $$(FUZZ_OUT)/$(1).fuzz_main.o
.PHONY: fuzz-bin-$(1)
endef
$(foreach b,$(FUZZ_BINS),$(eval $(call fuzz_bin_rule,$(word 1,$(subst :, ,$(b))),$(word 2,$(subst :, ,$(b))),$(word 3,$(subst :, ,$(b))))))

# btrfs_receive_decompress: libFuzzer target that #includes cmds/receive.c (for its static
# decompress_and_write), so it links everything receive.o needs except receive.o itself. Its run-once
# reproducer links the same objects against $(FUZZ_STANDALONE_MAIN).
FUZZ_DEPS_rd = $(objects) libbtrfsutil.a
fuzz-bins: fuzz-bin-btrfs_receive_decompress
fuzz-bin-btrfs_receive_decompress: mayhem/fuzz_receive_decompress.c cmds/receive.c $(FUZZ_DEPS_rd)
	$(CC) $(CFLAGS) -c mayhem/fuzz_receive_decompress.c -o $(FUZZ_OUT)/btrfs_receive_decompress.o
	$(CC) -o $(FUZZ_OUT)/btrfs_receive_decompress $(FUZZ_OUT)/btrfs_receive_decompress.o $(FUZZ_LSAN_OFF) \
	    $(FUZZ_DEPS_rd) $(LDFLAGS) $(LIBS) $(LIBS_COMP) $(FUZZ_ENGINE)
	$(CC) $(CFLAGS) -c $(FUZZ_STANDALONE_MAIN) -o $(FUZZ_OUT)/btrfs_receive_decompress.sa.o
	$(CC) -o $(FUZZ_OUT)/btrfs_receive_decompress-standalone $(FUZZ_OUT)/btrfs_receive_decompress.o \
	    $(FUZZ_OUT)/btrfs_receive_decompress.sa.o $(FUZZ_LSAN_OFF) $(FUZZ_DEPS_rd) $(LDFLAGS) $(LIBS) $(LIBS_COMP)
	rm -f $(FUZZ_OUT)/btrfs_receive_decompress.o $(FUZZ_OUT)/btrfs_receive_decompress.sa.o
.PHONY: fuzz-bin-btrfs_receive_decompress
