#!/bin/bash

# Usage: ./import.sh <database_name> <csv_file>

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <database_name> <csv_file>"
    echo "Example: $0 data.db data.csv"
    exit 1
fi

DB_NAME="$1"
CSV_FILE="$2"

# Check if CSV file exists
if [ ! -f "$CSV_FILE" ]; then
    echo "Error: CSV file '$CSV_FILE' not found"
    exit 1
fi

echo "Importing '$CSV_FILE' into database '$DB_NAME'..."

# Import data using SQLite
sqlite3 "$DB_NAME" << EOF
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL,
    size INTEGER
);

CREATE TEMP TABLE temp_import (path TEXT, size INTEGER);

.mode csv
.import $CSV_FILE temp_import

INSERT INTO files (path, size)
SELECT path, size FROM temp_import;

DROP TABLE temp_import;

SELECT 'Import complete. Total records: ' || COUNT(*) FROM files;
VACUUM;
EOF

echo "Done!"