pub const EXTENSION = "wm2k";
pub const PORT = 1177;

// Technically Sqlite supports BLOBs of up to 2G, but our undo history contains
// hex(<blob_value>) in its queries, so we'll hit SQLITE_MAX_SQL_LENGTH way
// before that point, so let's use a more conservative limit for now:
pub const MAX_ATTACHMENT_SIZE = 512 * 1024 * 1024;
