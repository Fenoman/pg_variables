# contrib/pg_variables/Makefile

MODULE_big = pg_variables
OBJS = pg_variables.o pg_variables_record.o $(WIN32RES)

EXTENSION = pg_variables
EXTVERSION = 1.4.0
DATA = pg_variables--1.0.sql \
	   pg_variables--1.0--1.1.sql \
	   pg_variables--1.1--1.2.sql \
	   pg_variables--1.0--1.4.0.sql \
	   pg_variables--1.1--1.4.0.sql \
	   pg_variables--1.2--1.4.0.sql \
	   pg_variables--1.3--1.4.0.sql \
	   pg_variables--1.4.0.sql

PGFILEDESC = "pg_variables - sessional variables"

REGRESS = pg_variables_upgrade pg_variables_advisory pg_variables pg_variables_any \
		pg_variables_lifetime pg_variables_toast pg_variables_record_trans \
		pg_variables_phantom pg_variables_2pc pg_variables_select_lifetime \
		pg_variables_trans pg_variables_atx pg_variables_atx_pkg

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_variables
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
