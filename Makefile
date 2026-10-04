EXTENSION = jev
MODULE_big = jev
OBJS = src/jev_planner.o
DATA = sql/jev--0.1.0.sql sql/jev--0.2.0.sql sql/jev--0.1.0--0.2.0.sql sql/jev--0.3.0.sql sql/jev--0.2.0--0.3.0.sql sql/jev--0.4.0.sql sql/jev--0.3.0--0.4.0.sql
PGFILEDESC = "jev - explicit semantic batches and batched custom scans"

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

.PHONY: check-local
# Install first; this target starts and stops its own disposable database.
check-local: all
	PG_CONFIG="$(PG_CONFIG)" sh test/run.sh
