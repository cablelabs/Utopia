##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2015 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################
bin_PROGRAMS = syseventd

AM_CFLAGS = -D_ANSC_LINUX -D_ANSC_USER -D_ANSC_LITTLE_ENDIAN_ -DIPV6=1 -DSET_REPLY_REQUIRED -DUSE_SYSCFG -DSE_SERVER_CODE_DEBUG \
		-DREDIRECT_CODE_DEBUG
AM_CFLAGS += -I$(top_srcdir)/source -I$(top_srcdir)/source/include -I$(top_srcdir)/source/util -I$(top_srcdir)/source/sysevent/lib

ACLOCAL_AMFLAGS = -I m4


AM_LDFLAGS =  -lpthread -lz \
              -lccsp_common \
                $(top_builddir)/source/sysevent/lib/libsysevent.la \
                $(top_builddir)/source/syscfg/lib/libsyscfg.la \
                $(top_builddir)/source/ulog/libulog.la

syseventd_SOURCES = syseventd_main.c worker_threads.c triggerMgr.c clientsMgr.c dataMgr.c se_debug.c utils.c

