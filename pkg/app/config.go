package app

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// AppConfig holds configuration for a target application.
type AppConfig struct {
	Type        string
	Name        string
	AppDataDir  string
	Files       []string
	WinProcess  string
	WinExe      string
	MacBundle   string
}

// AccountMeta holds metadata about a saved account.
type AccountMeta struct {
	Name               string                 `json:"name,omitempty"`
	Username           string                 `json:"username,omitempty"`
	DisplayName        string                 `json:"display_name,omitempty"`
	UserID             string                 `json:"user_id,omitempty"`
	AccountID          string                 `json:"account_id,omitempty"`
	Email              string                 `json:"email,omitempty"`
	AvatarURL          string                 `json:"avatar_url,omitempty"`
	OrgID              string                 `json:"org_id,omitempty"`
	OrgName            string                 `json:"org_name,omitempty"`
	UserType           string                 `json:"user_type,omitempty"`
	Quota              interface{}            `json:"quota,omitempty"`
	ExpireTime         interface{}            `json:"expire_time,omitempty"`
	IsSubAccount       bool                   `json:"is_sub_account,omitempty"`
	PlanTier           string                 `json:"plan_tier,omitempty"`
	UserPlanType       string                 `json:"user_plan_type,omitempty"`
	PlanStartDate      interface{}            `json:"plan_start_date,omitempty"`
	PlanEndDate        interface{}            `json:"plan_end_date,omitempty"`
	PlanFeatures       map[string]interface{} `json:"plan_features,omitempty"`
	SupabaseUserID     string                 `json:"supabase_user_id,omitempty"`
	SupabaseOrgID      string                 `json:"supabase_org_id,omitempty"`
	SupabaseExpiresAt  interface{}            `json:"supabase_expires_at,omitempty"`
	SavedAt            string                 `json:"saved_at,omitempty"`
}

// GetBackupRoot returns the root path where backups are stored.
func GetBackupRoot() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".qoder-account-switcher", "accounts")
}

// NewAppConfig creates app configurations for Qoder CN and QoderWork CN.
func NewAppConfig(appType string) (*AppConfig, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("failed to get home directory: %w", err)
	}

	var appDataDir string
	if runtime.GOOS == "windows" {
		appDataDir = filepath.Join(os.Getenv("APPDATA"), appType)
		// Special folder names
		if appType == "qodercn" {
			appDataDir = filepath.Join(os.Getenv("APPDATA"), "QoderCN")
		} else if appType == "qoderwork" {
			appDataDir = filepath.Join(os.Getenv("APPDATA"), "QoderWork CN")
		}
	} else if runtime.GOOS == "darwin" {
		if appType == "qodercn" {
			appDataDir = filepath.Join(home, "Library", "Application Support", "QoderCN")
		} else if appType == "qoderwork" {
			appDataDir = filepath.Join(home, "Library", "Application Support", "QoderWork CN")
		}
	} else {
		// Linux fallback
		if appType == "qodercn" {
			appDataDir = filepath.Join(home, ".config", "QoderCN")
		} else if appType == "qoderwork" {
			appDataDir = filepath.Join(home, ".config", "QoderWork CN")
		}
	}

	if appType == "qodercn" {
		return &AppConfig{
			Type:       "qodercn",
			Name:       "Qoder CN",
			AppDataDir: appDataDir,
			Files: []string{
				"auth-v2.dat",
				filepath.Join("SharedClientCache", "cache", "user"),
				filepath.Join("SharedClientCache", "cache", "quota"),
				filepath.Join("SharedClientCache", "cache", "id"),
				filepath.Join("SharedClientCache", "cache", "cache.json"),
				filepath.Join("SharedClientCache", "cache", "app-config.json"),
			},
			WinProcess: "QoderCN.exe",
			WinExe:     "QoderCN.exe",
			MacBundle:  "Qoder CN",
		}, nil
	} else if appType == "qoderwork" {
		return &AppConfig{
			Type:       "qoderwork",
			Name:       "QoderWork CN",
			AppDataDir: appDataDir,
			Files: []string{
				"auth-v2.dat",
				"auth.dat",
			},
			WinProcess: "QoderWork CN.exe",
			WinExe:     "QoderWork CN.exe",
			MacBundle:  "QoderWork CN",
		}, nil
	}

	return nil, fmt.Errorf("unknown app type: %s", appType)
}

// IsInstalled checks if the application is installed.
func (c *AppConfig) IsInstalled() bool {
	if runtime.GOOS == "darwin" {
		path := fmt.Sprintf("/Applications/%s.app", c.MacBundle)
		if _, err := os.Stat(path); err == nil {
			return true
		}
		// Also check user's Applications folder
		home, _ := os.UserHomeDir()
		userPath := filepath.Join(home, "Applications", c.MacBundle+".app")
		if _, err := os.Stat(userPath); err == nil {
			return true
		}
		// Fallback: if AppDataDir exists and has files, it might be installed
		if _, err := os.Stat(c.AppDataDir); err == nil {
			return true
		}
		return false
	} else if runtime.GOOS == "windows" {
		// 1. Check common installation directories
		pf := os.Getenv("ProgramFiles")
		pf86 := os.Getenv("ProgramFiles(x86)")
		local := os.Getenv("LocalAppData")

		paths := []string{
			filepath.Join(pf, c.MacBundle),
			filepath.Join(pf86, c.MacBundle),
			filepath.Join(local, c.MacBundle),
			filepath.Join(local, "Programs", c.MacBundle),
		}

		for _, p := range paths {
			if _, err := os.Stat(p); err == nil {
				return true
			}
		}

		// 2. Check registry uninstall entries (HKLM / HKCU) via reg query
		// This is fallback, we execute a command.
		cmd := exec.Command("reg", "query", "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "/s", "/f", c.MacBundle)
		if err := cmd.Run(); err == nil {
			return true
		}
		cmd = exec.Command("reg", "query", "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "/s", "/f", c.MacBundle)
		if err := cmd.Run(); err == nil {
			return true
		}

		// 3. Fallback: if AppDataDir exists
		if _, err := os.Stat(c.AppDataDir); err == nil {
			return true
		}
		return false
	}
	return false
}

// IsRunning checks if the application is currently running.
func (c *AppConfig) IsRunning() bool {
	if runtime.GOOS == "darwin" {
		// pgrep -f "/<bundle>.app/Contents/MacOS/"
		match := fmt.Sprintf("/%s.app/Contents/MacOS/", c.MacBundle)
		cmd := exec.Command("pgrep", "-f", match)
		if err := cmd.Run(); err == nil {
			return true
		}
		return false
	} else if runtime.GOOS == "windows" {
		if c.WinProcess == "" {
			return false
		}
		cmd := exec.Command("tasklist", "/FI", fmt.Sprintf("IMAGENAME eq %s", c.WinProcess))
		out, err := cmd.Output()
		if err == nil && strings.Contains(strings.ToLower(string(out)), strings.ToLower(c.WinProcess)) {
			return true
		}
		return false
	}
	return false
}

// Kill terminates the running application processes.
func (c *AppConfig) Kill() error {
	if runtime.GOOS == "darwin" {
		match := fmt.Sprintf("/%s.app/Contents/MacOS/", c.MacBundle)
		cmd := exec.Command("pkill", "-9", "-f", match)
		return cmd.Run()
	} else if runtime.GOOS == "windows" {
		if c.WinProcess == "" {
			return nil
		}
		cmd := exec.Command("taskkill", "/F", "/IM", c.WinProcess)
		return cmd.Run()
	}
	return fmt.Errorf("unsupported platform for kill")
}

// Launch starts the application.
func (c *AppConfig) Launch() error {
	if runtime.GOOS == "darwin" {
		cmd := exec.Command("open", "-a", c.MacBundle)
		return cmd.Run()
	} else if runtime.GOOS == "windows" {
		// Search for the exe file
		pf := os.Getenv("ProgramFiles")
		pf86 := os.Getenv("ProgramFiles(x86)")
		local := os.Getenv("LocalAppData")

		bases := []string{pf, pf86, local, filepath.Join(local, "Programs")}
		var exePath string

		for _, base := range bases {
			testDir := filepath.Join(base, c.MacBundle)
			testExe := filepath.Join(testDir, c.WinExe)
			if _, err := os.Stat(testExe); err == nil {
				exePath = testExe
				break
			}
		}

		if exePath == "" {
			// Fallback: try cmd /c start "win_process"
			cmd := exec.Command("cmd", "/c", "start", "", c.WinExe)
			return cmd.Run()
		}

		cmd := exec.Command("cmd", "/c", "start", "", exePath)
		return cmd.Run()
	}
	return fmt.Errorf("unsupported platform for launch")
}

// GetAccountDir returns the path to a specific saved account's directory.
func (c *AppConfig) GetAccountDir(alias string) string {
	return filepath.Join(GetBackupRoot(), c.Type, alias)
}

// WriteMetaJSON saves the metadata to the account's directory.
func (c *AppConfig) WriteMetaJSON(alias string, meta *AccountMeta) error {
	accountDir := c.GetAccountDir(alias)
	if err := os.MkdirAll(accountDir, 0755); err != nil {
		return err
	}

	meta.SavedAt = time.Now().Format("2006-01-02 15:04:05")
	metaPath := filepath.Join(accountDir, ".meta.json")
	
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(metaPath, data, 0644)
}

// ReadMetaJSON reads the metadata for a saved account.
func (c *AppConfig) ReadMetaJSON(alias string) (*AccountMeta, error) {
	accountDir := c.GetAccountDir(alias)
	metaPath := filepath.Join(accountDir, ".meta.json")
	data, err := os.ReadFile(metaPath)
	if err != nil {
		return nil, err
	}

	var meta AccountMeta
	if err := json.Unmarshal(data, &meta); err != nil {
		return nil, err
	}
	return &meta, nil
}
