package db

import (
	"database/sql"
	"fmt"
	"os"
	"strings"

	_ "modernc.org/sqlite"
)

// SecretRow represents a row in ItemTable
type SecretRow struct {
	Key   string
	Value string
}

// SupabaseTokenRow represents a row in supabase_token table
type SupabaseTokenRow struct {
	UserID       string
	OrgID        string
	AccessToken  string
	RefreshToken string
	ExpiresAt    int64
	GmtCreate    int64
	GmtModified  int64
}

// OpenDB opens a connection to an SQLite database file.
func OpenDB(dbPath string) (*sql.DB, error) {
	// Check if file exists
	if _, err := os.Stat(dbPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("database file does not exist: %s", dbPath)
	}

	// Use pure Go sqlite driver
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open sqlite database: %w", err)
	}

	return db, nil
}

// GetTableColumns queries PRAGMA table_info to check which columns exist.
func GetTableColumns(db *sql.DB, tableName string) (map[string]bool, error) {
	rows, err := db.Query(fmt.Sprintf("PRAGMA table_info(%s)", tableName))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	cols := make(map[string]bool)
	for rows.Next() {
		var cid int
		var name, typeStr string
		var notnull, pk int
		var dfltVal interface{}
		if err := rows.Scan(&cid, &name, &typeStr, &notnull, &dfltVal, &pk); err != nil {
			return nil, err
		}
		cols[name] = true
	}
	return cols, nil
}

// ReadSecrets reads all keys starting with 'secret://aicoding.auth%' from ItemTable.
func ReadSecrets(db *sql.DB) ([]SecretRow, error) {
	query := "SELECT key, value FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%'"
	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []SecretRow
	for rows.Next() {
		var r SecretRow
		if err := rows.Scan(&r.Key, &r.Value); err != nil {
			return nil, err
		}
		results = append(results, r)
	}
	return results, nil
}

// WriteSecrets inserts or replaces secret rows in ItemTable.
func WriteSecrets(db *sql.DB, secrets []SecretRow) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)")
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, s := range secrets {
		if _, err := stmt.Exec(s.Key, s.Value); err != nil {
			return err
		}
	}

	return tx.Commit()
}

// DeleteSecrets deletes all secret keys starting with 'secret://aicoding.auth%'.
func DeleteSecrets(db *sql.DB) error {
	_, err := db.Exec("DELETE FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%'")
	return err
}

// ReadSupabaseTokens reads supabase tokens.
func ReadSupabaseTokens(db *sql.DB) ([]SupabaseTokenRow, error) {
	// Check if table exists
	var name string
	err := db.QueryRow("SELECT name FROM sqlite_master WHERE type='table' AND name='supabase_token'").Scan(&name)
	if err == sql.ErrNoRows {
		return nil, nil // Table doesn't exist
	} else if err != nil {
		return nil, err
	}

	cols, err := GetTableColumns(db, "supabase_token")
	if err != nil {
		return nil, err
	}

	// Dynamically build selection to handle schema differences (e.g. absent refresh_token column)
	var selectCols []string
	if cols["user_id"] { selectCols = append(selectCols, "user_id") } else { selectCols = append(selectCols, "'' AS user_id") }
	if cols["org_id"] { selectCols = append(selectCols, "org_id") } else { selectCols = append(selectCols, "'' AS org_id") }
	if cols["access_token"] { selectCols = append(selectCols, "access_token") } else { selectCols = append(selectCols, "'' AS access_token") }
	if cols["refresh_token"] { selectCols = append(selectCols, "refresh_token") } else { selectCols = append(selectCols, "'' AS refresh_token") }
	if cols["expires_at"] { selectCols = append(selectCols, "expires_at") } else { selectCols = append(selectCols, "0 AS expires_at") }
	if cols["gmt_create"] { selectCols = append(selectCols, "gmt_create") } else { selectCols = append(selectCols, "0 AS gmt_create") }
	if cols["gmt_modified"] { selectCols = append(selectCols, "gmt_modified") } else { selectCols = append(selectCols, "0 AS gmt_modified") }

	query := fmt.Sprintf("SELECT %s FROM supabase_token", strings.Join(selectCols, ", "))
	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []SupabaseTokenRow
	for rows.Next() {
		var r SupabaseTokenRow
		if err := rows.Scan(&r.UserID, &r.OrgID, &r.AccessToken, &r.RefreshToken, &r.ExpiresAt, &r.GmtCreate, &r.GmtModified); err != nil {
			return nil, err
		}
		results = append(results, r)
	}
	return results, nil
}

// WriteSupabaseTokens inserts or replaces supabase tokens.
func WriteSupabaseTokens(db *sql.DB, tokens []SupabaseTokenRow) error {
	// First ensure table exists (it should, but just in case)
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS supabase_token (
		user_id TEXT,
		org_id TEXT,
		access_token TEXT,
		refresh_token TEXT,
		expires_at INTEGER,
		gmt_create INTEGER,
		gmt_modified INTEGER,
		PRIMARY KEY (user_id, org_id)
	)`)
	if err != nil {
		return err
	}

	cols, err := GetTableColumns(db, "supabase_token")
	if err != nil {
		return err
	}

	var insertCols []string
	var placeholders []string

	if cols["user_id"] { insertCols = append(insertCols, "user_id"); placeholders = append(placeholders, "?") }
	if cols["org_id"] { insertCols = append(insertCols, "org_id"); placeholders = append(placeholders, "?") }
	if cols["access_token"] { insertCols = append(insertCols, "access_token"); placeholders = append(placeholders, "?") }
	if cols["refresh_token"] { insertCols = append(insertCols, "refresh_token"); placeholders = append(placeholders, "?") }
	if cols["expires_at"] { insertCols = append(insertCols, "expires_at"); placeholders = append(placeholders, "?") }
	if cols["gmt_create"] { insertCols = append(insertCols, "gmt_create"); placeholders = append(placeholders, "?") }
	if cols["gmt_modified"] { insertCols = append(insertCols, "gmt_modified"); placeholders = append(placeholders, "?") }

	query := fmt.Sprintf("INSERT OR REPLACE INTO supabase_token (%s) VALUES (%s)",
		strings.Join(insertCols, ", "), strings.Join(placeholders, ", "))

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(query)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, t := range tokens {
		var vals []interface{}
		if cols["user_id"] { vals = append(vals, t.UserID) }
		if cols["org_id"] { vals = append(vals, t.OrgID) }
		if cols["access_token"] { vals = append(vals, t.AccessToken) }
		if cols["refresh_token"] { vals = append(vals, t.RefreshToken) }
		if cols["expires_at"] { vals = append(vals, t.ExpiresAt) }
		if cols["gmt_create"] { vals = append(vals, t.GmtCreate) }
		if cols["gmt_modified"] { vals = append(vals, t.GmtModified) }

		if _, err := stmt.Exec(vals...); err != nil {
			return err
		}
	}

	return tx.Commit()
}

// DeleteSupabaseTokens deletes all rows in supabase_token.
func DeleteSupabaseTokens(db *sql.DB) error {
	// Check if table exists
	var name string
	err := db.QueryRow("SELECT name FROM sqlite_master WHERE type='table' AND name='supabase_token'").Scan(&name)
	if err == sql.ErrNoRows {
		return nil
	} else if err != nil {
		return err
	}

	_, err = db.Exec("DELETE FROM supabase_token")
	return err
}
