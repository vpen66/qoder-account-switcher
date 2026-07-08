package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"qoder-switch/pkg/app"
	"qoder-switch/pkg/ui"
)

func printHelp() {
	fmt.Println("Qoder CN / QoderWork CN 账号切换工具 (Go 零依赖版) v1.0")
	fmt.Println()
	fmt.Println("用法:")
	fmt.Println("  qoder-switch                      交互模式（推荐）")
	fmt.Println("  qoder-switch save <别名>          保存当前登录态")
	fmt.Println("  qoder-switch list                 列出所有已保存账号")
	fmt.Println("  qoder-switch switch <别名>        切换到指定账号")
	fmt.Println("  qoder-switch delete <别名>        删除某个账号备份")
	fmt.Println("  qoder-switch status               显示应用的登录状态")
	fmt.Println("  qoder-switch help                 显示此帮助信息")
}

func main() {
	qoderCN, err := app.NewAppConfig("qodercn")
	if err != nil {
		fmt.Printf("[ERROR] 初始化 Qoder CN 配置失败: %v\n", err)
		os.Exit(1)
	}
	qoderWork, err := app.NewAppConfig("qoderwork")
	if err != nil {
		fmt.Printf("[ERROR] 初始化 QoderWork CN 配置失败: %v\n", err)
		os.Exit(1)
	}

	apps := []*app.AppConfig{qoderCN, qoderWork}

	args := os.Args[1:]
	if len(args) == 0 {
		runInteractive(apps)
		return
	}

	cmd := strings.ToLower(args[0])
	switch cmd {
	case "help", "-h", "--help":
		printHelp()
	case "save":
		alias := ""
		if len(args) > 1 {
			alias = args[1]
		}
		appType := ""
		if len(args) > 2 {
			appType = args[2]
		}
		cmdSave(apps, alias, appType)
	case "switch", "use":
		alias := ""
		if len(args) > 1 {
			alias = args[1]
		}
		appType := ""
		if len(args) > 2 {
			appType = args[2]
		}
		cmdSwitch(apps, alias, appType)
	case "list", "ls":
		cmdList(apps)
	case "delete", "rm":
		alias := ""
		if len(args) > 1 {
			alias = args[1]
		}
		appType := ""
		if len(args) > 2 {
			appType = args[2]
		}
		cmdDelete(apps, alias, appType)
	case "status", "stat":
		cmdStatus(apps)
	default:
		fmt.Printf("[WARN] 未知命令: %s\n", args[0])
		printHelp()
	}
}

// cmdSave handles non-interactive or semi-interactive saving.
func cmdSave(apps []*app.AppConfig, alias, appType string) {
	var targetApp *app.AppConfig

	if appType == "" {
		idx, err := ui.SelectAppInteractive(apps)
		if err != nil {
			fmt.Println("[INFO] 已取消操作")
			return
		}
		targetApp = apps[idx]
	} else {
		for _, a := range apps {
			if a.Type == appType {
				targetApp = a
				break
			}
		}
		if targetApp == nil {
			fmt.Printf("[ERROR] 未知应用类型: %s\n", appType)
			return
		}
	}

	if alias == "" {
		defaultAlias := ""
		meta, err := targetApp.GetCurrentAccountMeta()
		if err == nil && meta.Name != "" {
			defaultAlias = meta.Name
		}
		
		prompt := "请输入账号别名: "
		if defaultAlias != "" {
			prompt = fmt.Sprintf("请输入账号别名（默认: %s）: ", defaultAlias)
		}

		input, err := ui.ReadLineWithCancel(prompt)
		if err != nil {
			fmt.Println("[INFO] 已取消操作")
			return
		}
		if input == "" {
			alias = defaultAlias
		} else {
			alias = input
		}

		if alias == "" {
			fmt.Println("[ERROR] 别名不能为空")
			return
		}
	}

	if !targetApp.HasLoginState() {
		fmt.Println("============================================")
		fmt.Println("[WARN] 未检测到有效的登录态！")
		fmt.Printf("当前 %s 似乎没有登录任何账号。\n", targetApp.Name)
		fmt.Println("============================================")
		fmt.Println("按 Enter 取消，输入 y 强制保存: ")
		fmt.Println("\033[36m────────────────────────────────────────────\033[0m")
		fmt.Println("  \033[1mEnter/←\033[0m 取消    \033[1mY\033[0m 强制保存")
		key, _ := ui.ReadKey()
		if key != "y" && key != "Y" {
			fmt.Println("[INFO] 已取消保存")
			return
		}
	}

	fmt.Printf("[INFO] 正在保存账号 '%s' 的登录态文件...\n", alias)
	fmt.Printf("  应用: %s\n", targetApp.Name)

	err := targetApp.SaveAccount(alias)
	if err != nil {
		fmt.Printf("[ERROR] 保存失败: %v\n", err)
		return
	}
	fmt.Printf("[INFO] 账号 '%s' 保存成功！\n", alias)
}

// cmdSwitch handles non-interactive or semi-interactive switching.
func cmdSwitch(apps []*app.AppConfig, alias, appType string) {
	var targetApp *app.AppConfig

	if appType == "" {
		idx, err := ui.SelectAppInteractive(apps)
		if err != nil {
			fmt.Println("[INFO] 已取消操作")
			return
		}
		targetApp = apps[idx]
	} else {
		for _, a := range apps {
			if a.Type == appType {
				targetApp = a
				break
			}
		}
		if targetApp == nil {
			fmt.Printf("[ERROR] 未知应用类型: %s\n", appType)
			return
		}
	}

	if alias == "" {
		var err error
		alias, err = ui.SelectAccountInteractive(targetApp)
		if err != nil || alias == "back" || alias == "" {
			fmt.Println("[INFO] 已取消操作")
			return
		}
	}

	// Check backup existence
	accountDir := targetApp.GetAccountDir(alias)
	if _, err := os.Stat(accountDir); os.IsNotExist(err) {
		fmt.Printf("[ERROR] 账号 '%s' 在 %s 下不存在，请先保存\n", alias, targetApp.Name)
		return
	}

	// If app is running, try to terminate
	if targetApp.IsRunning() {
		fmt.Printf("[INFO] %s 正在运行，正在强制退出进程...\n", targetApp.Name)
		for attempts := 0; attempts < 6 && targetApp.IsRunning(); attempts++ {
			_ = targetApp.Kill()
			time.Sleep(500 * time.Millisecond)
		}
		if targetApp.IsRunning() {
			fmt.Println("[ERROR] 应用未能退出，请手动关闭后重试")
			return
		}
		fmt.Println("[INFO] 应用已成功退出")
	}

	fmt.Println("============================================")
	fmt.Printf("正在切换到账号: %s\n", alias)
	fmt.Printf("目标应用: %s\n", targetApp.Name)
	fmt.Println("============================================")

	err := targetApp.SwitchTo(alias)
	if err != nil {
		fmt.Printf("[ERROR] 切换失败: %v\n", err)
		return
	}

	fmt.Println("[INFO] 账号切换完成！")
	fmt.Printf("正在重新启动 %s...\n", targetApp.Name)
	_ = targetApp.Launch()
	fmt.Printf("[INFO] %s 已启动\n", targetApp.Name)
}

// cmdList lists saved accounts for all apps.
func cmdList(apps []*app.AppConfig) {
	for _, targetApp := range apps {
		fmt.Println()
		fmt.Printf("\033[1m%s — 已保存的账号\033[0m\n", targetApp.Name)
		fmt.Println("--------------------------------------------")
		
		accounts, err := ui.GetSavedAccounts(targetApp)
		if err != nil {
			fmt.Printf("  读取失败: %v\n", err)
			continue
		}

		if len(accounts) == 0 {
			fmt.Println("  \033[33m还没有保存任何账号备份\033[0m")
			continue
		}

		for _, acc := range accounts {
			marker := ""
			if acc.IsCurrent {
				marker = " \033[32m★ 当前使用\033[0m"
			}
			fmt.Printf("  \033[32m%s\033[0m  →  %s  (%s)%s\n", acc.Alias, acc.DisplayName, acc.SavedAt, marker)
		}
	}
	fmt.Println()
}

// cmdDelete handles non-interactive or semi-interactive deletion.
func cmdDelete(apps []*app.AppConfig, alias, appType string) {
	var targetApp *app.AppConfig

	if appType == "" {
		idx, err := ui.SelectAppInteractive(apps)
		if err != nil {
			fmt.Println("[INFO] 已取消操作")
			return
		}
		targetApp = apps[idx]
	} else {
		for _, a := range apps {
			if a.Type == appType {
				targetApp = a
				break
			}
		}
		if targetApp == nil {
			fmt.Printf("[ERROR] 未知应用类型: %s\n", appType)
			return
		}
	}

	if alias == "" {
		var err error
		alias, err = ui.SelectAccountInteractive(targetApp)
		if err != nil || alias == "back" || alias == "" {
			fmt.Println("[INFO] 已取消操作")
			return
		}
	}

	fmt.Printf("确认删除 %s 下的账号 '%s'？\n", targetApp.Name, alias)
	fmt.Println("\033[36m────────────────────────────────────────────\033[0m")
	fmt.Println("  \033[1mEnter\033[0m 确认    \033[1m←\033[0m 取消")
	key, _ := ui.ReadKey()
	if key != ui.KeyEnter && key != ui.KeyRight && key != "y" && key != "Y" {
		fmt.Println("[INFO] 已取消删除")
		return
	}

	err := targetApp.DeleteAccount(alias)
	if err != nil {
		fmt.Printf("[ERROR] 删除失败: %v\n", err)
		return
	}

	fmt.Printf("[INFO] 账号 '%s' 已成功删除\n", alias)
}

// cmdStatus prints status of all apps.
func cmdStatus(apps []*app.AppConfig) {
	fmt.Println()
	fmt.Println("\033[1m============================================\033[0m")
	fmt.Println("\033[1m  Qoder 应用登录状态\033[0m")
	fmt.Println("\033[1m============================================\033[0m")

	for _, targetApp := range apps {
		fmt.Println()
		fmt.Printf("  \033[1;32m%s\033[0m\n", targetApp.Name)
		fmt.Println("  ------------------------------------")
		
		if targetApp.IsInstalled() {
			fmt.Println("  安装状态:       \033[32m是\033[0m")
		} else {
			fmt.Println("  安装状态:       \033[31m否\033[0m")
		}

		if targetApp.IsRunning() {
			fmt.Println("  运行状态:       \033[32m运行中\033[0m")
		} else {
			fmt.Println("  运行状态:       \033[31m未运行\033[0m")
		}

		if targetApp.HasLoginState() {
			meta, err := targetApp.GetCurrentAccountMeta()
			if err == nil && meta != nil {
				fmt.Printf("  登录状态:       \033[32m已登录\033[0m\n")
				fmt.Printf("  用户名称:       %s\n", meta.Name)
				if meta.Email != "" {
					fmt.Printf("  用户邮箱:       %s\n", meta.Email)
				}
				if meta.PlanTier != "" {
					fmt.Printf("  用户套餐:       %s\n", meta.PlanTier)
				}
				if meta.ExpireTime != "" {
					fmt.Printf("  过期时间:       %s\n", meta.ExpireTime)
				}
			} else {
				fmt.Println("  登录状态:       \033[32m已登录\033[0m")
			}
		} else {
			fmt.Println("  登录状态:       \033[31m未登录\033[0m")
		}
	}

	cmdList(apps)
}

// runInteractive handles the interactive UI loop.
func runInteractive(apps []*app.AppConfig) {
	// Hide cursor on startup, restore on exit
	fmt.Print("\033[?25l")
	defer fmt.Print("\033[?25h")

	for {
		appIdx, err := ui.SelectAppInteractive(apps)
		if err != nil {
			ui.ClearScreen()
			fmt.Println("\n[INFO] 再见！")
			return
		}

		targetApp := apps[appIdx]

		for {
			op, err := ui.SelectOperation(targetApp.Name)
			if err != nil || op == "back" || op == "" {
				break // Go back to app selection
			}

			switch op {
			case "switch":
				alias, err := ui.SelectAccountInteractive(targetApp)
				if err != nil || alias == "back" || alias == "" {
					continue // Go back to operation menu
				}

				ui.ClearScreen()
				fmt.Printf("按 Enter 重启 %s 并切换到 %s，按 ← 返回: \n", targetApp.Name, alias)
				fmt.Println("\033[36m────────────────────────────────────────────\033[0m")
				fmt.Println("  \033[1mEnter\033[0m 确认    \033[1m←\033[0m 返回")
				confirmKey, _ := ui.ReadKey()
				if confirmKey != ui.KeyEnter && confirmKey != ui.KeyRight && confirmKey != "y" && confirmKey != "Y" {
					continue
				}

				ui.ClearScreen()
				fmt.Print("\033[?25h") // Show cursor for command logs
				cmdSwitch(apps, alias, targetApp.Type)
				fmt.Print("\033[?25l") // Hide cursor again

				key, _ := ui.DrawOutputFooter()
				if key == ui.KeyQuit {
					ui.ClearScreen()
					fmt.Println("\n[INFO] 再见！")
					return
				}

			case "save":
				ui.ClearScreen()
				fmt.Print("\033[?25h")
				
				defaultAlias := ""
				meta, err := targetApp.GetCurrentAccountMeta()
				if err == nil && meta.Name != "" {
					defaultAlias = meta.Name
				}
				
				prompt := "请输入新账号别名: "
				if defaultAlias != "" {
					prompt = fmt.Sprintf("请输入新账号别名（默认: %s）: ", defaultAlias)
				}

				alias, err := ui.ReadLineWithCancel(prompt)
				if err != nil {
					fmt.Println("[INFO] 已取消操作")
				} else {
					if alias == "" {
						alias = defaultAlias
					}
					if alias != "" {
						cmdSave(apps, alias, targetApp.Type)
					} else {
						fmt.Println("[ERROR] 别名不能为空")
					}
				}
				fmt.Print("\033[?25l")

				key, _ := ui.DrawOutputFooter()
				if key == ui.KeyQuit {
					ui.ClearScreen()
					fmt.Println("\n[INFO] 再见！")
					return
				}

			case "list":
				ui.ClearScreen()
				cmdList([]*app.AppConfig{targetApp})
				key, _ := ui.DrawOutputFooter()
				if key == ui.KeyQuit {
					ui.ClearScreen()
					fmt.Println("\n[INFO] 再见！")
					return
				}

			case "delete":
				alias, err := ui.SelectAccountInteractive(targetApp)
				if err != nil || alias == "back" || alias == "" {
					continue
				}

				ui.ClearScreen()
				fmt.Print("\033[?25h")
				cmdDelete(apps, alias, targetApp.Type)
				fmt.Print("\033[?25l")

				key, _ := ui.DrawOutputFooter()
				if key == ui.KeyQuit {
					ui.ClearScreen()
					fmt.Println("\n[INFO] 再见！")
					return
				}

			case "status":
				ui.ClearScreen()
				cmdStatus([]*app.AppConfig{targetApp})
				key, _ := ui.DrawOutputFooter()
				if key == ui.KeyQuit {
					ui.ClearScreen()
					fmt.Println("\n[INFO] 再见！")
					return
				}
			}
		}
	}
}
