package ui

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"qoder-switch/pkg/app"

	"golang.org/x/term"
)

type Key string

const (
	KeyUp      Key = "UP"
	KeyDown    Key = "DOWN"
	KeyLeft    Key = "LEFT"
	KeyRight   Key = "RIGHT"
	KeyEnter   Key = "ENTER"
	KeyEscape  Key = "ESC"
	KeyQuit    Key = "Q"
	KeyUnknown Key = "UNKNOWN"
)

// ReadKey reads a single keypress from standard input in raw mode.
func ReadKey() (Key, error) {
	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return KeyUnknown, err
	}
	defer term.Restore(fd, oldState)

	var buf [3]byte
	n, err := os.Stdin.Read(buf[:])
	if err != nil {
		return KeyUnknown, err
	}

	if n == 1 {
		switch buf[0] {
		case '\r', '\n':
			return KeyEnter, nil
		case 27: // Escape
			return KeyEscape, nil
		case 'q', 'Q', 3: // 'q' or Ctrl+C
			return KeyQuit, nil
		default:
			return Key(string(buf[0:1])), nil
		}
	} else if n == 3 && buf[0] == 27 && buf[1] == '[' {
		switch buf[2] {
		case 'A':
			return KeyUp, nil
		case 'B':
			return KeyDown, nil
		case 'C':
			return KeyRight, nil
		case 'D':
			return KeyLeft, nil
		}
	}

	return KeyUnknown, nil
}

// ClearScreen clears the terminal window.
func ClearScreen() {
	fmt.Print("\033[3J\033[2J\033[H")
}

// DrawHeader prints a styled header.
func DrawHeader(title string) {
	fmt.Println("\033[1m============================================\033[0m")
	fmt.Printf("\033[1m  %s\033[0m\n", title)
	fmt.Println("\033[1m============================================\033[0m")
	fmt.Println()
}

// DrawFooter prints navigation hints.
func DrawFooter(menuType string) {
	fmt.Println()
	fmt.Println("\033[36m────────────────────────────────────────────\033[0m")
	switch menuType {
	case "app_select":
		fmt.Println("  \033[1m↑ ↓\033[0m 选择应用    \033[1mEnter\033[0m 进入下级    \033[1mQ\033[0m 退出")
	case "op_select":
		fmt.Println("  \033[1m↑ ↓\033[0m 选择操作    \033[1mEnter\033[0m 执行        \033[1m←\033[0m 返回")
	case "account_select":
		fmt.Println("  \033[1m↑ ↓\033[0m 选择账号    \033[1mEnter\033[0m 确认        \033[1m←\033[0m 返回")
	}
}

// SelectAppInteractive displays the app selection menu.
func SelectAppInteractive(apps []*app.AppConfig) (int, error) {
	idx := 0
	for {
		ClearScreen()
		DrawHeader("选择应用")

		for i, a := range apps {
			runningStr := "\033[31m○未运行\033[0m"
			if a.IsRunning() {
				runningStr = "\033[32m●运行中\033[0m"
			}

			if i == idx {
				fmt.Printf("  \033[7m ▶ %s (%s) \033[0m\n", a.Name, runningStr)
			} else {
				fmt.Printf("     %s (%s)\n", a.Name, runningStr)
			}
		}

		DrawFooter("app_select")

		key, err := ReadKey()
		if err != nil {
			return -1, err
		}

		switch key {
		case KeyUp:
			idx = (idx - 1 + len(apps)) % len(apps)
		case KeyDown:
			idx = (idx + 1) % len(apps)
		case KeyEnter, KeyRight:
			return idx, nil
		case KeyQuit:
			return -1, fmt.Errorf("user quit")
		}
	}
}

// SelectOperation displays operations available for an app.
func SelectOperation(appName string) (string, error) {
	ops := []string{"switch", "save", "list", "delete", "status", "checkin"}
	opLabels := []string{
		"切换账号   (切换到已保存的账号)",
		"保存账号   (保存当前登录态)",
		"列出账号   (查看该应用下的所有备份)",
		"删除账号   (删除某个账号备份)",
		"查看状态   (查看该应用当前的登录状态)",
	}
	if strings.Contains(appName, "QoderWork") {
		opLabels = append(opLabels, "批量签到   (QoderWork CN 所有账号签到)")
	} else {
		// Just to align indices if not QoderWork, although ops is static, 
		// we'll handle the selection based on actual length of opLabels.
		ops = []string{"switch", "save", "list", "delete", "status"}
	}

	opLabels = append(opLabels, "在线更新   (将本工具更新到最新版)")
	ops = append(ops, "update")

	idx := 0
	for {
		ClearScreen()
		DrawHeader("应用: " + appName)

		for i, label := range opLabels {
			if i == idx {
				fmt.Printf("  \033[7m ▶ %s \033[0m\n", label)
			} else {
				fmt.Printf("     %s\n", label)
			}
		}

		DrawFooter("op_select")

		key, err := ReadKey()
		if err != nil {
			return "", err
		}

		switch key {
		case KeyUp:
			idx = (idx - 1 + len(ops)) % len(ops)
		case KeyDown:
			idx = (idx + 1) % len(ops)
		case KeyEnter, KeyRight:
			return ops[idx], nil
		case KeyLeft, KeyQuit:
			return "back", nil
		}
	}
}

// SavedAccount struct represents a choice in the account menu
type SavedAccount struct {
	Alias       string
	DisplayName string
	SavedAt     string
	IsCurrent   bool
}

// SelectAccountInteractive displays account selection list.
func SelectAccountInteractive(appConfig *app.AppConfig) (string, error) {
	// Read saved accounts
	accounts, err := GetSavedAccounts(appConfig)
	if err != nil {
		return "", err
	}

	if len(accounts) == 0 {
		ClearScreen()
		DrawHeader("选择账号 — " + appConfig.Name)
		fmt.Println("  \033[36m[HINT]\033[0m 该应用下还没有保存任何账号。")
		fmt.Println()
		fmt.Println("  按任意键返回...")
		_, _ = ReadKey()
		return "back", nil
	}

	idx := 0
	for {
		ClearScreen()
		DrawHeader("选择账号 — " + appConfig.Name)

		for i, acc := range accounts {
			currentMarker := ""
			if acc.IsCurrent {
				currentMarker = " \033[32m[当前使用]\033[0m"
			}

			// Format display: alias (display_name) - saved_at
			displayStr := fmt.Sprintf("%s (%s) - %s%s", acc.Alias, acc.DisplayName, acc.SavedAt, currentMarker)

			if i == idx {
				fmt.Printf("  \033[7m ▶ %s \033[0m\n", displayStr)
			} else {
				fmt.Printf("     %s\n", displayStr)
			}
		}

		DrawFooter("account_select")

		key, err := ReadKey()
		if err != nil {
			return "", err
		}

		switch key {
		case KeyUp:
			idx = (idx - 1 + len(accounts)) % len(accounts)
		case KeyDown:
			idx = (idx + 1) % len(accounts)
		case KeyEnter, KeyRight:
			return accounts[idx].Alias, nil
		case KeyLeft, KeyQuit:
			return "back", nil
		}
	}
}

// GetSavedAccounts lists saved accounts for the app config.
func GetSavedAccounts(appConfig *app.AppConfig) ([]SavedAccount, error) {
	backupDir := filepath.Join(app.GetBackupRoot(), appConfig.Type)
	entries, err := os.ReadDir(backupDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var list []SavedAccount
	for _, entry := range entries {
		if entry.IsDir() {
			alias := entry.Name()
			meta, err := appConfig.ReadMetaJSON(alias)
			displayName := "?"
			savedAt := "?"
			if err == nil {
				if meta.Name != "" {
					displayName = meta.Name
				} else if meta.Username != "" {
					displayName = meta.Username
				} else if meta.DisplayName != "" {
					displayName = meta.DisplayName
				}
				if meta.SavedAt != "" {
					savedAt = meta.SavedAt
				}
			}

			isCurrent := appConfig.IsCurrentAccount(alias)

			list = append(list, SavedAccount{
				Alias:       alias,
				DisplayName: displayName,
				SavedAt:     savedAt,
				IsCurrent:   isCurrent,
			})
		}
	}

	return list, nil
}

var ErrCanceled = fmt.Errorf("operation canceled")

// DrawOutputFooter prints the cyan separator and wait for Left Arrow or Q.
func DrawOutputFooter() (Key, error) {
	fmt.Println()
	fmt.Println("\033[36m────────────────────────────────────────────\033[0m")
	fmt.Println("  \033[1m←\033[0m 返回操作菜单    \033[1mQ\033[0m 退出")
	
	for {
		key, err := ReadKey()
		if err != nil {
			return KeyUnknown, err
		}
		if key == KeyLeft || key == KeyQuit || key == KeyEnter {
			return key, nil
		}
	}
}

// ReadLineWithCancel reads a line from terminal in raw mode, supports Left Arrow to cancel.
func ReadLineWithCancel(prompt string) (string, error) {
	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return "", err
	}
	defer term.Restore(fd, oldState)

	// Clean output and print layout
	// Clear the current line first and print prompt
	fmt.Print("\r\033[K")
	fmt.Printf("%s\r\n", prompt)
	fmt.Print("\033[36m────────────────────────────────────────────\033[0m\r\n")
	fmt.Print("  \033[1mEnter\033[0m 确认    \033[1m←\033[0m 返回")
	// Move cursor up by 2 lines, and to the end of prompt
	fmt.Print("\033[2A\r")
	fmt.Print(prompt)

	var inputBuf []rune
	for {
		var buf [16]byte
		n, err := os.Stdin.Read(buf[:])
		if err != nil {
			return "", err
		}
		if n == 0 {
			continue
		}

		if n == 1 {
			b := buf[0]
			if b == '\r' || b == '\n' {
				// Enter
				fmt.Print("\033[2B\r\n")
				return strings.TrimSpace(string(inputBuf)), nil
			}
			if b == 127 || b == 8 {
				// Backspace
				if len(inputBuf) > 0 {
					inputBuf = inputBuf[:len(inputBuf)-1]
					// Handle backspacing correctly for multi-byte runes
					fmt.Print("\b \b")
				}
				continue
			}
			if b == 3 || b == 27 {
				// Ctrl+C or Escape
				fmt.Print("\033[2B\r\n")
				return "", ErrCanceled
			}
		}

		if n == 3 && buf[0] == 27 && buf[1] == '[' && buf[2] == 'D' {
			// Left Arrow
			fmt.Print("\033[2B\r\n")
			return "", ErrCanceled
		}

		str := string(buf[:n])
		if !strings.Contains(str, "\x1b") && buf[0] >= 32 {
			runes := []rune(str)
			inputBuf = append(inputBuf, runes...)
			fmt.Print(str)
		}
	}
}
