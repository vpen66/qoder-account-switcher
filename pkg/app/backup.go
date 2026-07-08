package app

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"qoder-switch/pkg/crypto"
	"qoder-switch/pkg/db"
)

// bufferWrapper is used to parse the serialized Electron Buffer in state.vscdb
type bufferWrapper struct {
	Type string `json:"type"`
	Data []byte `json:"data"`
}

// CopyFile copies a file from src to dst, creating any directories needed.
func CopyFile(src, dst string) error {
	srcStat, err := os.Stat(src)
	if err != nil {
		return err
	}
	if !srcStat.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", src)
	}

	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}

	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer source.Close()

	destination, err := os.OpenFile(dst, os.O_RDWR|os.O_CREATE|os.O_TRUNC, srcStat.Mode())
	if err != nil {
		return err
	}
	defer destination.Close()

	if _, err := io.Copy(destination, source); err != nil {
		return err
	}
	return nil
}

// HasLoginState checks if the application currently has a logged-in state.
func (c *AppConfig) HasLoginState() bool {
	// auth-v2.dat check
	authV2Path := filepath.Join(c.AppDataDir, "auth-v2.dat")
	if _, err := os.Stat(authV2Path); err == nil {
		return true
	}

	if c.Type == "qoderwork" {
		authDatPath := filepath.Join(c.AppDataDir, "auth.dat")
		if _, err := os.Stat(authDatPath); err == nil {
			return true
		}
	} else if c.Type == "qodercn" {
		// User/SharedClientCache/cache/user check
		userCache := filepath.Join(c.AppDataDir, "SharedClientCache", "cache", "user")
		if _, err := os.Stat(userCache); err == nil {
			return true
		}

		// DB secret check
		gsdbPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb")
		if _, err := os.Stat(gsdbPath); err == nil {
			if sqliteDB, err := db.OpenDB(gsdbPath); err == nil {
				defer sqliteDB.Close()
				secrets, err := db.ReadSecrets(sqliteDB)
				if err == nil && len(secrets) > 0 {
					return true
				}
			}
		}
	}

	return false
}

// ClearLoginState clears current logged in session from AppDataDir.
func (c *AppConfig) ClearLoginState() error {
	// Remove standard files
	for _, relPath := range c.Files {
		fullPath := filepath.Join(c.AppDataDir, relPath)
		if err := os.Remove(fullPath); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("failed to remove %s: %w", relPath, err)
		}
	}

	if c.Type == "qodercn" {
		// Clean SQLite state.vscdb
		gsdbPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb")
		if sqliteDB, err := db.OpenDB(gsdbPath); err == nil {
			defer sqliteDB.Close()
			_ = db.DeleteSecrets(sqliteDB)
		}
		gsdbBackupPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb.backup")
		if sqliteDB, err := db.OpenDB(gsdbBackupPath); err == nil {
			defer sqliteDB.Close()
			_ = db.DeleteSecrets(sqliteDB)
		}

		// Clean supabase token table in local.db
		localDBPath := filepath.Join(c.AppDataDir, "SharedClientCache", "cache", "db", "local.db")
		if sqliteDB, err := db.OpenDB(localDBPath); err == nil {
			defer sqliteDB.Close()
			_ = db.DeleteSupabaseTokens(sqliteDB)
		}
	}

	return nil
}

// SaveAccount backups current login state to backup folder and generates metadata.
func (c *AppConfig) SaveAccount(alias string) error {
	if !c.HasLoginState() {
		return errors.New("no login state detected to save")
	}

	accountDir := c.GetAccountDir(alias)
	if err := os.MkdirAll(accountDir, 0755); err != nil {
		return fmt.Errorf("failed to create backup dir: %w", err)
	}

	// 1. Copy main files
	for _, relPath := range c.Files {
		src := filepath.Join(c.AppDataDir, relPath)
		dst := filepath.Join(accountDir, relPath)
		if _, err := os.Stat(src); err == nil {
			if err := CopyFile(src, dst); err != nil {
				return fmt.Errorf("failed to backup file %s: %w", relPath, err)
			}
		}
	}

	// 2. Extra DB export for qodercn
	var meta AccountMeta
	if c.Type == "qodercn" {
		gsdbPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb")
		if err := c.exportSecrets(gsdbPath, filepath.Join(accountDir, "state.vscdb_secrets.txt")); err != nil {
			return fmt.Errorf("failed to export state.vscdb secrets: %w", err)
		}
		gsdbBackupPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb.backup")
		if _, err := os.Stat(gsdbBackupPath); err == nil {
			_ = c.exportSecrets(gsdbBackupPath, filepath.Join(accountDir, "state.vscdb.backup_secrets.txt"))
		}

		localDBPath := filepath.Join(c.AppDataDir, "SharedClientCache", "cache", "db", "local.db")
		if err := c.exportSupabaseToken(localDBPath, filepath.Join(accountDir, "supabase_token.txt")); err != nil {
			return fmt.Errorf("failed to export supabase token: %w", err)
		}

		// Decrypt metadata from state.vscdb and local.db
		c.decryptQoderCNMeta(&meta)
	} else if c.Type == "qoderwork" {
		// Decrypt metadata from auth-v2.dat
		c.decryptQoderWorkMeta(&meta)
	}

	// 3. Save meta info
	if err := c.WriteMetaJSON(alias, &meta); err != nil {
		return fmt.Errorf("failed to write meta.json: %w", err)
	}

	return nil
}

// SwitchTo restores saved account from backup.
func (c *AppConfig) SwitchTo(alias string) error {
	accountDir := c.GetAccountDir(alias)
	if _, err := os.Stat(accountDir); os.IsNotExist(err) {
		return fmt.Errorf("backup for account '%s' does not exist", alias)
	}

	// Ensure application is not running
	if c.IsRunning() {
		return fmt.Errorf("application %s is currently running, please close it first", c.Name)
	}

	// 1. Clear current state
	if err := c.ClearLoginState(); err != nil {
		return fmt.Errorf("failed to clear current login state: %w", err)
	}

	// 2. Restore main files
	for _, relPath := range c.Files {
		src := filepath.Join(accountDir, relPath)
		dst := filepath.Join(c.AppDataDir, relPath)
		if _, err := os.Stat(src); err == nil {
			if err := CopyFile(src, dst); err != nil {
				return fmt.Errorf("failed to restore file %s: %w", relPath, err)
			}
		}
	}

	// 3. Extra DB import for qodercn
	if c.Type == "qodercn" {
		gsdbPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb")
		if err := c.importSecrets(filepath.Join(accountDir, "state.vscdb_secrets.txt"), gsdbPath); err != nil {
			return fmt.Errorf("failed to restore state.vscdb secrets: %w", err)
		}
		gsdbBackupPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb.backup")
		if _, err := os.Stat(gsdbBackupPath); err == nil {
			_ = c.importSecrets(filepath.Join(accountDir, "state.vscdb.backup_secrets.txt"), gsdbBackupPath)
		}

		localDBPath := filepath.Join(c.AppDataDir, "SharedClientCache", "cache", "db", "local.db")
		if err := c.importSupabaseToken(filepath.Join(accountDir, "supabase_token.txt"), localDBPath); err != nil {
			return fmt.Errorf("failed to restore supabase token: %w", err)
		}
	}

	return nil
}

// GetCurrentAccountMeta decrypts and returns current logged in user details.
func (c *AppConfig) GetCurrentAccountMeta() (*AccountMeta, error) {
	if !c.HasLoginState() {
		return nil, errors.New("no active login session found")
	}

	var meta AccountMeta
	if c.Type == "qodercn" {
		c.decryptQoderCNMeta(&meta)
	} else if c.Type == "qoderwork" {
		c.decryptQoderWorkMeta(&meta)
	}
	return &meta, nil
}

// DeleteAccount deletes a saved account backup.
func (c *AppConfig) DeleteAccount(alias string) error {
	accountDir := c.GetAccountDir(alias)
	if _, err := os.Stat(accountDir); os.IsNotExist(err) {
		return fmt.Errorf("account backup '%s' does not exist", alias)
	}

	if err := os.RemoveAll(accountDir); err != nil {
		return err
	}

	return nil
}

// IsCurrentAccount checks if the saved account is currently active.
func (c *AppConfig) IsCurrentAccount(alias string) bool {
	// First fallback: Compare auth-v2.dat files directly using md5 or size
	authV2Backup := filepath.Join(c.GetAccountDir(alias), "auth-v2.dat")
	authV2Current := filepath.Join(c.AppDataDir, "auth-v2.dat")

	b1, err1 := os.ReadFile(authV2Backup)
	b2, err2 := os.ReadFile(authV2Current)
	if err1 == nil && err2 == nil {
		if bytes.Equal(b1, b2) {
			return true
		}
	}

	// Second fallback for qodercn: compare user_id
	if c.Type == "qodercn" {
		meta, err := c.ReadMetaJSON(alias)
		if err == nil && meta.UserID != "" {
			currentUID := c.getCurrentQoderCNUserID()
			if currentUID != "" && currentUID == meta.UserID {
				return true
			}
		}
	}

	return false
}

// --- Private Helpers ---

func (c *AppConfig) exportSecrets(dbPath, txtPath string) error {
	sqliteDB, err := db.OpenDB(dbPath)
	if err != nil {
		return err
	}
	defer sqliteDB.Close()

	secrets, err := db.ReadSecrets(sqliteDB)
	if err != nil {
		return err
	}

	f, err := os.Create(txtPath)
	if err != nil {
		return err
	}
	defer f.Close()

	writer := bufio.NewWriter(f)
	for _, s := range secrets {
		// Escape | and newline if they happen to exist, but in state.vscdb they won't
		_, _ = writer.WriteString(fmt.Sprintf("%s|%s\n", s.Key, s.Value))
	}
	return writer.Flush()
}

func (c *AppConfig) importSecrets(txtPath, dbPath string) error {
	f, err := os.Open(txtPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // Nothing to import
		}
		return err
	}
	defer f.Close()

	sqliteDB, err := db.OpenDB(dbPath)
	if err != nil {
		return err
	}
	defer sqliteDB.Close()

	var secrets []db.SecretRow
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, "|", 2)
		if len(parts) == 2 {
			secrets = append(secrets, db.SecretRow{
				Key:   parts[0],
				Value: parts[1],
			})
		}
	}

	if err := scanner.Err(); err != nil {
		return err
	}

	return db.WriteSecrets(sqliteDB, secrets)
}

func (c *AppConfig) exportSupabaseToken(dbPath, txtPath string) error {
	sqliteDB, err := db.OpenDB(dbPath)
	if err != nil {
		return err
	}
	defer sqliteDB.Close()

	tokens, err := db.ReadSupabaseTokens(sqliteDB)
	if err != nil {
		return err
	}

	f, err := os.Create(txtPath)
	if err != nil {
		return err
	}
	defer f.Close()

	writer := bufio.NewWriter(f)
	for _, t := range tokens {
		line := fmt.Sprintf("%s|%s|%s|%s|%d|%d|%d\n",
			t.UserID, t.OrgID, t.AccessToken, t.RefreshToken, t.ExpiresAt, t.GmtCreate, t.GmtModified)
		_, _ = writer.WriteString(line)
	}
	return writer.Flush()
}

func (c *AppConfig) importSupabaseToken(txtPath, dbPath string) error {
	f, err := os.Open(txtPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()

	sqliteDB, err := db.OpenDB(dbPath)
	if err != nil {
		return err
	}
	defer sqliteDB.Close()

	var tokens []db.SupabaseTokenRow
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.Split(line, "|")
		if len(parts) >= 7 {
			expiresAt, _ := strconv.ParseInt(parts[4], 10, 64)
			gmtCreate, _ := strconv.ParseInt(parts[5], 10, 64)
			gmtModified, _ := strconv.ParseInt(parts[6], 10, 64)

			tokens = append(tokens, db.SupabaseTokenRow{
				UserID:       parts[0],
				OrgID:        parts[1],
				AccessToken:  parts[2],
				RefreshToken: parts[3],
				ExpiresAt:    expiresAt,
				GmtCreate:    gmtCreate,
				GmtModified:  gmtModified,
			})
		}
	}

	if err := scanner.Err(); err != nil {
		return err
	}

	return db.WriteSupabaseTokens(sqliteDB, tokens)
}

func (c *AppConfig) decryptQoderCNMeta(meta *AccountMeta) {
	gsdbPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb")
	sqliteDB, err := db.OpenDB(gsdbPath)
	if err != nil {
		return
	}
	defer sqliteDB.Close()

	// 1. Get UUID from SharedClientCache/cache/id
	idPath := filepath.Join(c.AppDataDir, "SharedClientCache", "cache", "id")
	if bytes, err := os.ReadFile(idPath); err == nil {
		uuid := strings.TrimSpace(string(bytes))
		if len(uuid) >= 8 {
			meta.SupabaseUserID = uuid // Save UUID
			// Wait, the bash code says:
			// meta_updates['uuid'] = user_meta['uuid']
			// meta_updates['uuid_short'] = user_meta['uuid_short']
			// Let's check how we populate the Go struct fields.
		}
	}

	// 2. Query userInfo and userPlan secrets
	secrets, err := db.ReadSecrets(sqliteDB)
	if err != nil {
		return
	}

	for _, s := range secrets {
		var wrapper bufferWrapper
		if err := json.Unmarshal([]byte(s.Value), &wrapper); err != nil {
			continue
		}

		decrypted, err := crypto.Decrypt(wrapper.Data, c.Name)
		if err != nil {
			continue
		}

		if s.Key == "secret://aicoding.auth.userInfo" {
			var ui map[string]interface{}
			if err := json.Unmarshal(decrypted, &ui); err == nil {
				meta.Name = getStringField(ui, "name")
				meta.Username = getStringField(ui, "name")
				meta.UserID = getStringField(ui, "id")
				meta.AccountID = getStringField(ui, "accountId")
				meta.Email = getStringField(ui, "email")
				meta.AvatarURL = getStringField(ui, "avatarUrl")
				meta.OrgID = getStringField(ui, "orgId")
				meta.OrgName = getStringField(ui, "orgName")
				meta.UserType = getStringField(ui, "userType")
				meta.Quota = ui["quota"]
				meta.ExpireTime = getStringField(ui, "expireTime")
				if sub, ok := ui["isSubAccount"].(bool); ok {
					meta.IsSubAccount = sub
				}
			}
		} else if s.Key == "secret://aicoding.auth.userPlan" {
			var up map[string]interface{}
			if err := json.Unmarshal(decrypted, &up); err == nil {
				meta.PlanTier = getStringField(up, "plan_tier_name")
				meta.UserPlanType = getStringField(up, "user_type")
				meta.PlanStartDate = getStringField(up, "start_date")
				meta.PlanEndDate = getStringField(up, "end_date")
				if feat, ok := up["feature_allowed"].(map[string]interface{}); ok {
					meta.PlanFeatures = feat
				}
			}
		}
	}

	// 3. Query supabase token expires_at
	localDBPath := filepath.Join(c.AppDataDir, "SharedClientCache", "cache", "db", "local.db")
	if localDB, err := db.OpenDB(localDBPath); err == nil {
		defer localDB.Close()
		tokens, err := db.ReadSupabaseTokens(localDB)
		if err == nil && len(tokens) > 0 {
			meta.SupabaseUserID = tokens[0].UserID
			meta.SupabaseOrgID = tokens[0].OrgID
			meta.SupabaseExpiresAt = tokens[0].ExpiresAt
		}
	}
}

func (c *AppConfig) decryptQoderWorkMeta(meta *AccountMeta) {
	authV2Path := filepath.Join(c.AppDataDir, "auth-v2.dat")
	data, err := os.ReadFile(authV2Path)
	if err != nil {
		return
	}

	decrypted, err := crypto.Decrypt(data, c.Name)
	if err != nil {
		return
	}

	var obj map[string]interface{}
	if err := json.Unmarshal(decrypted, &obj); err != nil {
		return
	}

	// Extract fields
	meta.Name = getStringField(obj, "name")
	meta.Email = getStringField(obj, "email")
	meta.AvatarURL = getStringField(obj, "imageUrl")
	meta.PlanTier = getStringField(obj, "tier")
	meta.ExpireTime = getStringField(obj, "expiresAt")

	if userObj, ok := obj["user"].(map[string]interface{}); ok {
		meta.UserID = getStringField(userObj, "id")
		meta.Username = getStringField(userObj, "username")
		meta.OrgID = getStringField(userObj, "orgId")
		if meta.Name == "" {
			meta.Name = getStringField(userObj, "name")
		}
		if meta.Email == "" {
			meta.Email = getStringField(userObj, "email")
		}
		if meta.AvatarURL == "" {
			meta.AvatarURL = getStringField(userObj, "imageUrl")
		}
		if meta.PlanTier == "" {
			meta.PlanTier = getStringField(userObj, "tier")
		}
	}
}

func (c *AppConfig) getCurrentQoderCNUserID() string {
	gsdbPath := filepath.Join(c.AppDataDir, "User", "globalStorage", "state.vscdb")
	sqliteDB, err := db.OpenDB(gsdbPath)
	if err != nil {
		return ""
	}
	defer sqliteDB.Close()

	var value string
	err = sqliteDB.QueryRow("SELECT value FROM ItemTable WHERE key='secret://aicoding.auth.userInfo'").Scan(&value)
	if err != nil {
		return ""
	}

	var wrapper bufferWrapper
	if err := json.Unmarshal([]byte(value), &wrapper); err != nil {
		return ""
	}

	decrypted, err := crypto.Decrypt(wrapper.Data, c.Name)
	if err != nil {
		return ""
	}

	var ui map[string]interface{}
	if err := json.Unmarshal(decrypted, &ui); err == nil {
		return getStringField(ui, "id")
	}

	return ""
}

func getStringField(m map[string]interface{}, key string) string {
	if val, ok := m[key]; ok {
		if s, ok := val.(string); ok {
			return s
		}
	}
	return ""
}
