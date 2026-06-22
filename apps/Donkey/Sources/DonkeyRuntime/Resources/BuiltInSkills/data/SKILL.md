# Data

id: data
description: Expert data manipulation — query, reshape, and convert CSV/JSON/TSV with python3 and sqlite3, which ship with macOS, plus jq and mlr when installed.
tags: data, csv, json, tsv, sql, transform
keywords: csv, json, tsv, data, convert, filter, group, aggregate, join, query, sql, spreadsheet, column
tools: shell_exec

`python3` and `sqlite3` ship with macOS — lead with them so a task never depends
on an uninstalled tool. `jq` and `mlr` are nicer for one-liners but are not
guaranteed; reach for them directly and fall back to `python3` if the command
isn't found. Writing an output file is reversible (consent gate).

## python3 — the always-available workhorse (stdlib csv + json)
- CSV to JSON: `python3 -c "import csv,json,sys; json.dump(list(csv.DictReader(open('in.csv'))), sys.stdout, indent=2)" > out.json`.
- JSON to CSV: `python3 -c "import csv,json,sys; r=json.load(open('in.json')); w=csv.DictWriter(sys.stdout, r[0].keys()); w.writeheader(); w.writerows(r)" > out.csv`.
- For multi-step reshaping (group, join, pivot), write the logic as a short python script and run it, rather than chaining fragile one-liners.
- XLSX needs pandas + openpyxl, which are usually NOT installed. If the user has them, `python3 -c "import pandas as pd; pd.read_excel('in.xlsx').to_csv('out.csv', index=False)"`; otherwise say plainly that Excel support isn't available and offer CSV.

## sqlite3 — SQL over a CSV without a database
- `sqlite3 :memory: -cmd '.mode csv' -cmd '.import in.csv t' 'select category, count(*) from t group by category'`.

## jq / mlr — try them, fall back to python3 if not installed
- Filter/reshape JSON: `jq '.items[] | {name, id}' in.json`.
- CSV↔JSON: `mlr --c2j cat in.csv`, `mlr --j2c cat in.json`.

## Verify
- Re-read the output and sanity-check shape: `head out.csv`, `wc -l out.csv`, or `python3 -c "import json; print(len(json.load(open('out.json'))))"`. A row/record count that matches the input is the success check.