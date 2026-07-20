package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"qoder-switch/pkg/crypto"
)

type authV2Data struct {
	Token        string `json:"token"`
	RefreshToken string `json:"refreshToken"`
	ExpiresAt    string `json:"expiresAt"`
}

type checkInStatusResponse struct {
	Status string `json:"status"`
}

type refreshResponse struct {
	DeviceToken string `json:"deviceToken"`
	Token       string `json:"token"`
}

const (
	refreshAPI = "https://openapi.qoder.com.cn/api/v1/deviceToken/refresh"
	statusAPI  = "https://openapi.qoder.com.cn/sash/api/v1/me/daily-check-in/status"
	claimAPI   = "https://openapi.qoder.com.cn/sash/api/v1/me/daily-check-in/claim"
)

// BatchCheckinQoderWork performs a batch check-in for all saved QoderWork CN accounts.
func BatchCheckinQoderWork(c *AppConfig) {
	fmt.Println("\n============================================")
	fmt.Printf("开始批量签到 QoderWork CN 账号...\n")
	fmt.Println("============================================")

	backupDir := filepath.Join(GetBackupRoot(), c.Type)
	entries, err := os.ReadDir(backupDir)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Println("[INFO] 没有找到任何已保存的账号。")
		} else {
			fmt.Printf("[ERROR] 读取账号目录失败: %v\n", err)
		}
		return
	}

	successCount := 0
	alreadyCount := 0
	failedCount := 0

	client := &http.Client{Timeout: 10 * time.Second}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		alias := entry.Name()

		// Retrieve display name from meta.json
		displayName := alias
		meta, err := c.ReadMetaJSON(alias)
		if err == nil && meta != nil {
			if meta.Name != "" {
				displayName = meta.Name
			} else if meta.Username != "" {
				displayName = meta.Username
			} else if meta.DisplayName != "" {
				displayName = meta.DisplayName
			}
		}

		fmt.Printf("\n正在处理账号: %s (%s)...\n", alias, displayName)

		authPath := filepath.Join(backupDir, alias, "auth-v2.dat")
		if _, err := os.Stat(authPath); os.IsNotExist(err) {
			fmt.Printf("  \033[31m[失败]\033[0m auth-v2.dat 文件不存在\n")
			failedCount++
			continue
		}

		raw, err := os.ReadFile(authPath)
		if err != nil {
			fmt.Printf("  \033[31m[失败]\033[0m 读取文件失败: %v\n", err)
			failedCount++
			continue
		}

		decrypted, err := crypto.Decrypt(raw, c.Name)
		if err != nil {
			fmt.Printf("  \033[31m[失败]\033[0m 解密失败: %v\n", err)
			failedCount++
			continue
		}

		var authData authV2Data
		if err := json.Unmarshal(decrypted, &authData); err != nil {
			fmt.Printf("  \033[31m[失败]\033[0m JSON 解析失败: %v\n", err)
			failedCount++
			continue
		}

		if authData.Token == "" {
			fmt.Printf("  \033[31m[失败]\033[0m 无法从 auth-v2.dat 中获取 Token\n")
			failedCount++
			continue
		}

		token := authData.Token

		// Check status
		status, err := checkinStatus(client, token)
		if err != nil {
			// Try to refresh token if the error might be auth related
			refreshedToken, refreshErr := refreshToken(client, authData.RefreshToken)
			if refreshErr == nil && refreshedToken != "" {
				token = refreshedToken
				status, err = checkinStatus(client, token)
			}
		}

		if err != nil {
			fmt.Printf("  \033[31m[失败]\033[0m 查询签到状态失败: %v\n", err)
			failedCount++
			continue
		}

		if status == "CLAIMED_TODAY" {
			fmt.Printf("  \033[32m[跳过]\033[0m 今日已签到\n")
			alreadyCount++
			continue
		}

		// Proceed to claim
		if err := claimCheckin(client, token); err != nil {
			fmt.Printf("  \033[31m[失败]\033[0m 签到请求失败: %v\n", err)
			failedCount++
		} else {
			fmt.Printf("  \033[32m[成功]\033[0m 签到完成！\n")
			successCount++
		}
	}

	fmt.Println("\n============================================")
	fmt.Printf("批量签到完成！成功: %d, 已签到: %d, 失败: %d\n", successCount, alreadyCount, failedCount)
	fmt.Println("============================================")
}

func setRealHeaders(req *http.Request, token string) {
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Accept", "application/json, text/plain, */*")
	// 模仿真实的 Electron 客户端 User-Agent 以防止风控
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) QoderWork/0.9.12 Chrome/114.0.5735.289 Electron/25.9.8 Safari/537.36")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8,en-US;q=0.7")
	req.Header.Set("Sec-Fetch-Dest", "empty")
	req.Header.Set("Sec-Fetch-Mode", "cors")
	req.Header.Set("Sec-Fetch-Site", "same-site")
}

func checkinStatus(client *http.Client, token string) (string, error) {
	req, err := http.NewRequest("GET", statusAPI, nil)
	if err != nil {
		return "", err
	}
	setRealHeaders(req, token)

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	var data checkInStatusResponse
	if err := json.Unmarshal(body, &data); err != nil {
		return "", err
	}

	return data.Status, nil
}

func claimCheckin(client *http.Client, token string) error {
	req, err := http.NewRequest("POST", claimAPI, bytes.NewBuffer([]byte{}))
	if err != nil {
		return err
	}
	setRealHeaders(req, token)
	req.Header.Set("Content-Length", "0")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	return nil
}

func refreshToken(client *http.Client, rToken string) (string, error) {
	if rToken == "" {
		return "", fmt.Errorf("empty refresh token")
	}

	payload := map[string]string{"refresh_token": rToken}
	jsonData, _ := json.Marshal(payload)

	req, err := http.NewRequest("POST", refreshAPI, bytes.NewBuffer(jsonData))
	if err != nil {
		return "", err
	}
	setRealHeaders(req, "")
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	var data refreshResponse
	if err := json.Unmarshal(body, &data); err != nil {
		return "", err
	}

	if data.DeviceToken != "" {
		return data.DeviceToken, nil
	}
	return data.Token, nil
}
