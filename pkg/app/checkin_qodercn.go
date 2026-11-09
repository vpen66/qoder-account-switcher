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

const (
	// Qoder CN 的活动接口都挂在 openapi.qoder.com.cn 上。
	qoderCNCampaignsAPI = "https://openapi.qoder.com.cn/sash/api/v1/me/campaigns"
	qoderCNClaimAPIFmt  = "https://openapi.qoder.com.cn/sash/api/v1/me/campaigns/%s/claim"

	// 每日签到轮次的动作类型；同一账号还会有 VIEW_DETAILS 类型的常驻推广活动。
	qoderCNClaimBenefitAction = "CLAIM_BENEFIT"
	qoderCNClaimedStatus      = "CLAIMED"
)

// qoderCNCampaign 是 GET /sash/api/v1/me/campaigns 返回的一条活动记录。
type qoderCNCampaign struct {
	CampaignID  string `json:"campaignId"`
	CampaignKey string `json:"campaignKey"`
	ActionType  string `json:"actionType"`
	StartAt     int64  `json:"startAt"`
	EndAt       int64  `json:"endAt"`
	ClaimStatus string `json:"claimStatus"`
	Benefit     struct {
		Kind   string `json:"kind"`
		Amount int    `json:"amount"`
	} `json:"benefit"`
}

type qoderCNCampaignsResponse struct {
	ShowCampaign bool              `json:"showCampaign"`
	Claimable    bool              `json:"claimable"`
	Campaigns    []qoderCNCampaign `json:"campaigns"`
}

// qoderCNClaimResponse 是 POST /sash/api/v1/me/campaigns/{campaignId}/claim 的返回。
type qoderCNClaimResponse struct {
	GrantID     string `json:"grantId"`
	Status      string `json:"status"`
	Replayed    bool   `json:"replayed"`
	CampaignID  string `json:"campaignId"`
	CampaignKey string `json:"campaignKey"`
	ExpiresAt   string `json:"expiresAt"`
	Benefit     struct {
		Kind   string `json:"kind"`
		Amount int    `json:"amount"`
	} `json:"benefit"`
}

// BatchCheckinQoderCN performs a batch daily check-in for all saved Qoder CN accounts.
//
// Qoder 每天 10:00 (UTC+8) 给每个账号下发一轮 CLAIM_BENEFIT 活动，
// 领取接口是 POST /sash/api/v1/me/campaigns/{campaignId}/claim（重复领取返回 replayed）。
func BatchCheckinQoderCN(c *AppConfig) {
	fmt.Println("\n============================================")
	fmt.Printf("开始批量签到 %s 账号...\n", c.Name)
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

	client := &http.Client{Timeout: 15 * time.Second}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		alias := entry.Name()

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

		authPath := findQoderCNAuthFile(c.GetAccountDir(alias))
		if authPath == "" {
			fmt.Printf("  \033[31m[失败]\033[0m 账号目录下没有 auth.v1.dat / auth-v2.dat\n")
			failedCount++
			continue
		}

		raw, err := os.ReadFile(authPath)
		if err != nil {
			fmt.Printf("  \033[31m[失败]\033[0m 读取文件失败: %v\n", err)
			failedCount++
			continue
		}

		decrypted, err := crypto.Decrypt(raw, c.CryptoService)
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
			fmt.Printf("  \033[31m[失败]\033[0m 无法从认证文件中获取 Token\n")
			failedCount++
			continue
		}

		token := authData.Token
		campaigns, statusCode, err := fetchQoderCNCampaigns(client, token)
		if err != nil && statusCode == http.StatusUnauthorized {
			if refreshedToken, refreshErr := refreshToken(client, authData.RefreshToken); refreshErr == nil && refreshedToken != "" {
				token = refreshedToken
				campaigns, statusCode, err = fetchQoderCNCampaigns(client, token)
			}
		}

		if err != nil {
			fmt.Printf("  \033[31m[失败]\033[0m 查询签到活动失败: %v\n", err)
			failedCount++
			continue
		}

		campaign := pickQoderCNClaimableCampaign(campaigns, time.Now())
		if campaign == nil {
			if hasQoderCNClaimedCampaign(campaigns) {
				fmt.Printf("  \033[32m[跳过]\033[0m 今日已签到\n")
				alreadyCount++
			} else {
				fmt.Printf("  \033[33m[跳过]\033[0m 当前没有可领取的签到活动\n")
				alreadyCount++
			}
			continue
		}

		result, err := claimQoderCNCampaign(client, token, campaign.CampaignID)
		if err != nil {
			fmt.Printf("  \033[31m[失败]\033[0m 领取失败: %v\n", err)
			failedCount++
			continue
		}

		if result.Replayed {
			fmt.Printf("  \033[32m[跳过]\033[0m 今日已签到（重复领取被幂等忽略）\n")
			alreadyCount++
			continue
		}

		amount := result.Benefit.Amount
		if amount == 0 {
			amount = campaign.Benefit.Amount
		}
		expireHint := ""
		if t, err := time.Parse(time.RFC3339, result.ExpiresAt); err == nil {
			expireHint = fmt.Sprintf("，有效期至 %s", t.Local().Format("2006-01-02 15:04:05"))
		}
		fmt.Printf("  \033[32m[成功]\033[0m 签到完成，+%d Credits%s\n", amount, expireHint)
		successCount++
	}

	fmt.Println("\n============================================")
	fmt.Printf("批量签到完成！成功: %d, 已签到: %d, 失败: %d\n", successCount, alreadyCount, failedCount)
	fmt.Println("============================================")
}

// findQoderCNAuthFile 返回账号目录下的认证文件路径（新版 auth.v1.dat 优先，兼容旧版 auth-v2.dat）。
func findQoderCNAuthFile(accountDir string) string {
	for _, name := range []string{"auth.v1.dat", "auth-v2.dat"} {
		p := filepath.Join(accountDir, name)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// setQoderCNHeaders 模仿 Qoder CN 桌面客户端请求活动接口时的请求头。
// 缺少 Cosy-ClientType 时，服务端只会返回常驻的 VIEW_DETAILS 横幅，不下发每日签到轮次。
func setQoderCNHeaders(req *http.Request, token string) {
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "Qoder")
	req.Header.Set("Cosy-ClientType", "10")
}

// fetchQoderCNCampaigns 查询账号当前的活动列表。statusCode 用于判断是否需要刷新 Token。
func fetchQoderCNCampaigns(client *http.Client, token string) (*qoderCNCampaignsResponse, int, error) {
	req, err := http.NewRequest("GET", qoderCNCampaignsAPI, nil)
	if err != nil {
		return nil, 0, err
	}
	setQoderCNHeaders(req, token)

	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, resp.StatusCode, fmt.Errorf("HTTP %d: %s", resp.StatusCode, stringsShorten(body))
	}

	var data qoderCNCampaignsResponse
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, resp.StatusCode, err
	}
	return &data, resp.StatusCode, nil
}

// claimQoderCNCampaign 领取指定活动。
func claimQoderCNCampaign(client *http.Client, token, campaignID string) (*qoderCNClaimResponse, error) {
	url := fmt.Sprintf(qoderCNClaimAPIFmt, campaignID)
	req, err := http.NewRequest("POST", url, bytes.NewBuffer([]byte{}))
	if err != nil {
		return nil, err
	}
	setQoderCNHeaders(req, token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Content-Length", "0")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, stringsShorten(body))
	}

	var data qoderCNClaimResponse
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, err
	}
	if data.Status != qoderCNClaimedStatus {
		return nil, fmt.Errorf("unexpected claim status: %s", data.Status)
	}
	return &data, nil
}

// pickQoderCNClaimableCampaign 选出当前可领取的那一轮签到活动。
// 只认 CLAIM_BENEFIT（VIEW_DETAILS 是订阅推广，领不出 Credits），
// 跳过已领取（CLAIMED）以及不在时间窗内的轮次。
func pickQoderCNClaimableCampaign(resp *qoderCNCampaignsResponse, now time.Time) *qoderCNCampaign {
	if resp == nil {
		return nil
	}
	for i := range resp.Campaigns {
		c := &resp.Campaigns[i]
		if c.ActionType != qoderCNClaimBenefitAction || c.CampaignID == "" {
			continue
		}
		if c.ClaimStatus == qoderCNClaimedStatus {
			continue
		}
		if c.StartAt > 0 && now.Unix() < c.StartAt {
			continue
		}
		if c.EndAt > 0 && now.Unix() > c.EndAt {
			continue
		}
		return c
	}
	return nil
}

// hasQoderCNClaimedCampaign 判断活动列表里是否已有领取过的签到轮次。
func hasQoderCNClaimedCampaign(resp *qoderCNCampaignsResponse) bool {
	if resp == nil {
		return false
	}
	for _, c := range resp.Campaigns {
		if c.ActionType == qoderCNClaimBenefitAction && c.ClaimStatus == qoderCNClaimedStatus {
			return true
		}
	}
	return false
}

// stringsShorten 截断错误响应体，避免把整页 HTML 打到终端。
func stringsShorten(body []byte) string {
	const limit = 200
	s := string(body)
	if len(s) > limit {
		return s[:limit] + "..."
	}
	return s
}
