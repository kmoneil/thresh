/*
 * thresh: a delimited file's dialect (sniff), the schema its values fit
 * (infer), its rows checked against a schema (validate), and its rows and
 * rejected rows handed out as Arrow C streams (read).
 *
 * Reports are JSON in the versioned formats of docs/REPORT.md; a file's
 * own problem (it is missing, its dialect is not settled, a value does not
 * fit) is in its report, not a status. A status other than THRESH_OK is
 * for a call made wrongly, a schema refused, an error reading partway, no
 * memory, or the caller's cancel; thresh_error says which.
 *
 * Ownership. Every string a call returns is the caller's, freed with
 * thresh_string_free. A reader is freed with thresh_reader_free; the
 * Arrow streams it hands out are released with their release callbacks,
 * before or after the reader, and every array they give is the caller's,
 * released with its own. Nothing returned points into the handle.
 *
 * Threads. A handle is used by one thread at a time: give each thread
 * its own. So is a reader and its streams. A call that reads several
 * files (thresh_infer) reads them on threads of its own, joined before it
 * returns. Anything returned may be freed or released on any thread.
 *
 * docs/C.md has more.
 */
#ifndef THRESH_H
#define THRESH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Arrow's C Data and C Stream Interfaces, as
 * https://arrow.apache.org/docs/format/CDataInterface.html gives them. */
#ifndef ARROW_C_DATA_INTERFACE
#define ARROW_C_DATA_INTERFACE

#define ARROW_FLAG_DICTIONARY_ORDERED 1
#define ARROW_FLAG_NULLABLE 2
#define ARROW_FLAG_MAP_KEYS_SORTED 4

struct ArrowSchema {
    const char *format;
    const char *name;
    const char *metadata;
    int64_t flags;
    int64_t n_children;
    struct ArrowSchema **children;
    struct ArrowSchema *dictionary;
    void (*release)(struct ArrowSchema *);
    void *private_data;
};

struct ArrowArray {
    int64_t length;
    int64_t null_count;
    int64_t offset;
    int64_t n_buffers;
    int64_t n_children;
    const void **buffers;
    struct ArrowArray **children;
    struct ArrowArray *dictionary;
    void (*release)(struct ArrowArray *);
    void *private_data;
};

#endif /* ARROW_C_DATA_INTERFACE */

#ifndef ARROW_C_STREAM_INTERFACE
#define ARROW_C_STREAM_INTERFACE

struct ArrowArrayStream {
    int (*get_schema)(struct ArrowArrayStream *, struct ArrowSchema *out);
    int (*get_next)(struct ArrowArrayStream *, struct ArrowArray *out);
    const char *(*get_last_error)(struct ArrowArrayStream *);
    void (*release)(struct ArrowArrayStream *);
    void *private_data;
};

#endif /* ARROW_C_STREAM_INTERFACE */

typedef enum thresh_status {
    THRESH_OK = 0,
    /* A call made wrongly: a null where a value is needed, an option out
     * of range, options from a newer thresh that set what this one does
     * not know, a stream taken twice. */
    THRESH_ERROR_ARGUMENT = 1,
    /* The schema was refused; the message says why. */
    THRESH_ERROR_SCHEMA = 2,
    /* Reading failed partway through, or a file could not be read for a
     * reason that is not the file's own. */
    THRESH_ERROR_IO = 3,
    THRESH_ERROR_MEMORY = 4,
    /* thresh_options.cancel was set. */
    THRESH_ERROR_INTERRUPTED = 5
} thresh_status;

/* thresh_options.quote: no quote character. */
#define THRESH_QUOTE_NONE (-1)
/* thresh_options.escape */
#define THRESH_ESCAPE_DOUBLED 1
#define THRESH_ESCAPE_BACKSLASH 2
/* thresh_options.newline */
#define THRESH_NEWLINE_LF 1
#define THRESH_NEWLINE_CRLF 2
#define THRESH_NEWLINE_CR 3
/* thresh_options.header */
#define THRESH_HEADER_YES 1
#define THRESH_HEADER_NO 2
/* thresh_options.ragged: what a short or long row becomes. Rejected (0)
 * by default. */
#define THRESH_RAGGED_PAD 1
#define THRESH_RAGGED_TRUNCATE 2
/* thresh_options.flags */
#define THRESH_KEEP_EMPTY 1u    /* an empty line is a one-field record */
#define THRESH_DAY_FIRST 2u     /* ambiguous dates read day first */
#define THRESH_STRICT 4u        /* extra columns, ragged rows, ambiguous dates fail the file */
#define THRESH_NO_MMAP 8u       /* read through a buffer, not a mapping */
#define THRESH_THRESHOLD 16u    /* use thresh_options.threshold */
#define THRESH_SHAPES_ONLY 32u  /* reports and JSON give values as shapes (digits 9, letters a) */
#define THRESH_SHAPE_NAMES 64u  /* that, and the column names too */

/* How files are read. Every field zero is every default: the sniffer
 * settles the dialect, and a call reads as the CLI does with no flags.
 * Set size to sizeof(thresh_options) and leave the rest zero but what you
 * mean: `thresh_options o; memset(&o, 0, sizeof o); o.size = sizeof o;`. A
 * thresh newer than the header reads the fields it has; an older one
 * refuses a struct that sets a field it does not know. */
typedef struct thresh_options {
    size_t size;
    /* THRESH_KEEP_EMPTY and the rest, or'd together. */
    uint32_t flags;
    /* The quote character, or THRESH_QUOTE_NONE; 0 lets the sniffer
     * settle it, as for every pin below. */
    int32_t quote;
    uint8_t delimiter;
    uint8_t escape;
    uint8_t newline;
    uint8_t header;
    /* The byte that starts a comment line; 0, none. */
    uint8_t comment;
    uint8_t ragged;
    /* "utf8" (NULL), "latin1" or "cp1252". A UTF-16 file is told by its
     * byte order mark, with no encoding. */
    const char *encoding;
    /* Strings read as null in every column, besides the schema's. */
    const char *const *nulls;
    size_t nulls_len;
    /* The sniffer's first window; 0, 64 KiB. */
    uint64_t sample_bytes;
    /* thresh_infer: only the first rows of each file; 0, every row. */
    uint64_t sample_rows;
    /* With THRESH_THRESHOLD: the fraction of a column's values that must
     * fit, and of rows read whole, for a file to pass; infer keeps a type
     * that many fit. Without: the schema's, or 1. */
    double threshold;
    /* thresh_infer: files read at once; 0, one a CPU core. */
    uint32_t jobs;
    /* Set to 1, from any thread, to stop the call at its next batch with
     * THRESH_ERROR_INTERRUPTED. NULL: never. A reader's streams keep
     * reading it, so it must live as long as they do. */
    const volatile uint8_t *cancel;
} thresh_options;

/* thresh_read's want */
#define THRESH_WANT_ROWS 1u
#define THRESH_WANT_REJECTS 2u

typedef struct thresh thresh;
typedef struct thresh_reader thresh_reader;

/* The version, "1.2.3". */
const char *thresh_version(void);

/* A handle, or NULL when out of memory. */
thresh *thresh_new(void);
void thresh_free(thresh *t);
/* What went wrong in the handle's last call; "" when it succeeded. Valid
 * until the next call on the handle. */
const char *thresh_error(const thresh *t);
/* A string a call returned. NULL is nothing. */
void thresh_string_free(char *s);

/* The file's dialect: *json is its sniff line (docs/REPORT.md, "A sniff
 * line"), for a file that cannot be read too. o may be NULL. */
thresh_status thresh_sniff(thresh *t, const char *path, const thresh_options *o, char **json);

/* The schema the files fit: *json is an infer result (docs/REPORT.md,
 * "An infer result"), each file's outcome and notes and the schema. */
thresh_status thresh_infer(thresh *t, const char *const *paths, size_t paths_len, const thresh_options *o, char **json);

/* The inline form, "lug_id:int64,lug_kg:decimal(6,2)", as schema JSON
 * (docs/REPORT.md, "The schema"): every column nullable, the nulls "". */
thresh_status thresh_columns(thresh *t, const char *columns, char **schema_json);

/* The file read against the schema: *json is its report (docs/REPORT.md,
 * "The file report"). */
thresh_status thresh_validate(thresh *t, const char *path, const char *schema_json, const thresh_options *o, char **json);

/* The file opened to read against the schema, its rows (and with
 * THRESH_WANT_REJECTS its rejected rows) handed out as Arrow C streams.
 * When the file stops before it is read, *reader is NULL and *json its
 * report; otherwise *json is NULL. The reader keeps its own copies of
 * the path, the schema and o; o's cancel must outlive it. */
thresh_status thresh_read(thresh *t, const char *path, const char *schema_json, const thresh_options *o, uint32_t want,
                          thresh_reader **reader, char **json);

/* The accepted rows: a stream of struct arrays, one field a schema column
 * (docs/C.md has the Arrow types). Once, and only when wanted. */
thresh_status thresh_reader_rows(thresh_reader *r, struct ArrowArrayStream *out);
/* The rejected rows, as docs/REPORT.md's "Reject files" has them in
 * Arrow. Once, and only when wanted. */
thresh_status thresh_reader_rejects(thresh_reader *r, struct ArrowArrayStream *out);
/* The file's report, what is left of it read first: batches a stream
 * still open has not taken are kept for it. */
thresh_status thresh_reader_report(thresh_reader *r, char **json);
/* What went wrong in the reader's last call; "" when it succeeded. */
const char *thresh_reader_error(const thresh_reader *r);
/* Drops the reader; streams it handed out stay valid until released. */
void thresh_reader_free(thresh_reader *r);

#ifdef __cplusplus
}
#endif

#endif /* THRESH_H */
