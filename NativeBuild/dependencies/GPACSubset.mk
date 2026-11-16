# Probe-only object target; no upstream all/apps/filters/test targets.
include ../config.mak
vpath %.c $(SRC_PATH)/src
CFLAGS=-I"$(SRC_PATH)/include" $(LIBGPAC_CFLAGS) $(OPTFLAGS)
OBJS=utils/os_divers.o utils/os_file.o utils/list.o utils/bitstream.o utils/constants.o utils/error.o utils/alloc.o utils/url.o utils/configfile.o utils/gltools.o utils/gzio.o utils/xml_parser.o utils/xml_bin_custom.o utils/sha1.o utils/sha256.o utils/md5.o utils/base_encoding.o utils/math.o utils/os_net.o utils/os_thread.o utils/os_config_init.o utils/utf.o utils/token.o utils/color.o utils/rmt_ws.o utils/uni_bidi.o utils/unicode.o utils/os_module.o utils/module.o utils/path2d.o utils/path2d_stroker.o isomedia/avc_ext.o isomedia/box_code_3gpp.o isomedia/box_code_apple.o isomedia/box_code_base.o isomedia/box_code_drm.o isomedia/box_code_meta.o isomedia/box_dump.o isomedia/box_funcs.o isomedia/data_map.o isomedia/drm_sample.o isomedia/isom_intern.o isomedia/isom_read.o isomedia/isom_store.o isomedia/isom_write.o isomedia/media.o isomedia/media_odf.o isomedia/meta.o isomedia/movie_fragments.o isomedia/sample_descs.o isomedia/stbl_read.o isomedia/stbl_write.o isomedia/track.o isomedia/tx3g.o isomedia/iff.o odf/desc_private.o odf/descriptors.o odf/odf_code.o odf/odf_codec.o odf/odf_command.o odf/slc.o media_tools/av_parsers.o media_tools/isom_tools.o
.PHONY: probe
probe: ../bin/gcc/libgpac_static.a
../bin/gcc/libgpac_static.a: $(OBJS)
	$(AR) cr $@ $(OBJS)
	$(RANLIB) $@
