#include <sqlite3.h>

/// sqlite3_db_config is variadic, which Swift can't call. Stops close from
/// checkpointing, and so from truncating or deleting the -wal.
static inline int headroom_sqlite3_no_checkpoint_on_close(sqlite3 *db) {
    return sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, (int *)0);
}
