"""Rows into pyarrow, polars and DuckDB, with no copy and no file between,
typed by the schema; and the rows that did not fit, the same way.

    pip install pyarrow polars duckdb
    cd examples && python python/dataframes.py
"""

import duckdb
import polars as pl
import pyarrow as pa

import threshio

schema = threshio.infer("data/harvest.csv").schema

# pyarrow: the schema's types, decimals, dates and bools included.
table = pa.table(threshio.read("data/harvest.csv", schema))
print(table.schema)

# polars: the same rows.
lugs = pl.DataFrame(threshio.read("data/harvest.csv", schema))
heaviest = lugs.sort("lug_kg", descending=True).head(2)
print(heaviest.select("lug_id", "cultivar", "lug_kg").rows())

# DuckDB: a Reader is a table in a query.
harvest = threshio.read("data/harvest.csv", schema)
print(duckdb.sql("select cultivar, count(*) from harvest group by 1 order by 2 desc, 1 limit 3").fetchall())

# One read of a bad delivery: the rows that fit, the rows that did not
# (with why), and the report.
reader = threshio.read("data/harvest_dirty.csv", schema, rejects=True)
good = pa.table(reader)
bad = pa.table(reader.rejects)
print(good.num_rows, "rows read,", bad.num_rows, "set aside")
for row in bad.select(["_row", "_errors"]).to_pylist():
    print(" ", row)
print(reader.report())
