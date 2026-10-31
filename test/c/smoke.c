/* libthresh from C, through include/thresh.h alone: each call on
 * test/c/lugs.csv (10 rows, 2 of them rejected by its columns), the Arrow
 * streams drained as a consumer would, and a few calls made wrongly. Run
 * from the repository's root by zig build test, linked once to the static
 * library and once to the shared one. */
#include "thresh.h"

#include <stdio.h>
#include <string.h>

static int checks = 0;
static int failures = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        checks++;                                                         \
        if (!(cond)) {                                                    \
            fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond);    \
            failures++;                                                   \
        }                                                                 \
    } while (0)

static const char *lugs = "test/c/lugs.csv";
static const char *columns = "lug_id:int64,cultivar:string,lug_kg:decimal(5,2),picked_on:date";

static thresh_options defaults(void) {
    thresh_options o;
    memset(&o, 0, sizeof o);
    o.size = sizeof o;
    return o;
}

/* A stream's rows, each batch released as it is read; -1 when it fails. */
static long drain(struct ArrowArrayStream *s) {
    struct ArrowSchema schema;
    long rows = 0;
    if (s->get_schema(s, &schema) != 0) return -1;
    schema.release(&schema);
    for (;;) {
        struct ArrowArray batch;
        if (s->get_next(s, &batch) != 0) return -1;
        if (batch.release == NULL) return rows;
        rows += (long)batch.length;
        batch.release(&batch);
    }
}

int main(void) {
    thresh *t = thresh_new();
    thresh_options o = defaults();
    char *json = NULL;
    char *schema = NULL;
    thresh_reader *reader = NULL;
    struct ArrowArrayStream rows, rejects, again;
    const char *paths[2];

    CHECK(t != NULL);
    CHECK(strlen(thresh_version()) > 0);

    CHECK(thresh_sniff(t, lugs, &o, &json) == THRESH_OK);
    CHECK(json != NULL && strstr(json, "\"delimiter\":\",\"") != NULL);
    thresh_string_free(json);
    CHECK(strcmp(thresh_error(t), "") == 0);

    paths[0] = lugs;
    paths[1] = lugs;
    o.jobs = 2;
    CHECK(thresh_infer(t, paths, 2, &o, &json) == THRESH_OK);
    CHECK(json != NULL && strstr(json, "\"schema\":{") != NULL);
    thresh_string_free(json);
    o.jobs = 0;

    CHECK(thresh_describe(t, lugs, NULL, &o, &json) == THRESH_OK);
    CHECK(json != NULL && strstr(json, "\"inferred\": true") != NULL);
    thresh_string_free(json);

    CHECK(thresh_columns(t, columns, &schema) == THRESH_OK);
    CHECK(thresh_validate(t, lugs, schema, &o, &json) == THRESH_OK);
    /* The report is indented, as the CLI writes it. */
    CHECK(json != NULL && strstr(json, "\"rows_rejected\": 2") != NULL);
    CHECK(json != NULL && strstr(json, "\"result\": \"fail\"") != NULL);
    thresh_string_free(json);

    /* The streams, read after the reader and the handle are gone. */
    CHECK(thresh_read(t, lugs, schema, &o, THRESH_WANT_ROWS | THRESH_WANT_REJECTS, &reader, &json) == THRESH_OK);
    CHECK(reader != NULL && json == NULL);
    if (reader != NULL) {
        CHECK(thresh_reader_rows(reader, &rows) == THRESH_OK);
        CHECK(thresh_reader_rejects(reader, &rejects) == THRESH_OK);
        CHECK(thresh_reader_rows(reader, &again) == THRESH_ERROR_ARGUMENT);
        CHECK(strstr(thresh_reader_error(reader), "taken already") != NULL);
        thresh_reader_free(reader);
        CHECK(drain(&rows) == 8);
        CHECK(drain(&rejects) == 2);
        rows.release(&rows);
        rejects.release(&rejects);
    }

    /* A file that cannot be read: its report, not a status. */
    CHECK(thresh_read(t, "test/c/none.csv", schema, NULL, THRESH_WANT_ROWS, &reader, &json) == THRESH_OK);
    CHECK(reader == NULL && json != NULL && strstr(json, "\"no_such_file\"") != NULL);
    thresh_string_free(json);

    /* Calls made wrongly. */
    o.size = 0;
    CHECK(thresh_sniff(t, lugs, &o, &json) == THRESH_ERROR_ARGUMENT);
    CHECK(strstr(thresh_error(t), "thresh_options.size") != NULL);
    o = defaults();
    o.quote = 300;
    CHECK(thresh_sniff(t, lugs, &o, &json) == THRESH_ERROR_ARGUMENT);
    CHECK(thresh_validate(t, lugs, "{\"columns\":", NULL, &json) == THRESH_ERROR_SCHEMA);
    CHECK(strlen(thresh_error(t)) > 0);

    thresh_string_free(schema);
    thresh_free(t);
    printf("c smoke: %d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
