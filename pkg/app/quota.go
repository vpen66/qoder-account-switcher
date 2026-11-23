package app

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"qoder-switch/pkg/crypto"
)

const qoderCNQuotaUsageAPI = "https://openapi.qoder.com.cn/api/v2/quota/usage"

// quotaBucket 是 /api/v2/quota/usage 里的一个额度桶。
// userQuota 为套餐内额度，addOnQuota 为资源包额度。
type quotaBucket struct {
	Total     float64 `json:"total"`
	Used      float64 `json:"used"`
	Remaining float64 `json:"remaining"`
}

type quotaUsageResponse struct {
	UserQuota  quotaBucket `json:"userQuota"`
	AddOnQuota quotaBucket `json:"addOnQuota"`
}

// AccountQuota 是套餐内 + 资源包合并后的用量。
type AccountQuota struct {
	Used      float64
	Total     float64
	Remaining float64
}

// String 输出形如 "Credits 100/600(余:500)" 的展示文本。
func (q *AccountQuota) String() string {
	return fmt.Sprintf("Credits %s/%s(余:%s)",
		formatQuotaNumber(q.Used),
		formatQuotaNumber(q.Total),
		formatQuotaNumber(q.Remaining))
}

// FetchAccountQuota 使用账号备份中的 token 查询实时用量。
// token 失效时会用 refreshToken 换取新 token 再试一次（refreshToken 不会因此失效）。
func (c *AppConfig) FetchAccountQuota(alias string) (*AccountQuota, error) {
	authData, err := c.readAccountAuth(alias)
	if err != nil {
		return nil, err
	}

	client := &http.Client{Timeout: 8 * time.Second}

	quota, statusCode, err := fetchQuotaUsage(client, authData.Token)
	if err != nil && statusCode == http.StatusUnauthorized {
		newToken, refreshErr := refreshToken(client, authData.RefreshToken)
		if refreshErr == nil && newToken != "" {
			quota, _, err = fetchQuotaUsage(client, newToken)
		}
	}
	if err != nil {
		return nil, err
	}
	return quota, nil
}

// readAccountAuth 从账号备份中解出 token/refreshToken。
func (c *AppConfig) readAccountAuth(alias string) (*authV2Data, error) {
	accountDir := c.GetAccountDir(alias)

	candidates := []string{c.AuthFile, "auth.v1.dat", "auth-v2.dat"}
	seen := map[string]bool{}
	for _, name := range candidates {
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true

		raw, err := os.ReadFile(filepath.Join(accountDir, name))
		if err != nil {
			continue
		}
		decrypted, err := crypto.Decrypt(raw, c.CryptoService)
		if err != nil {
			continue
		}

		var authData authV2Data
		if err := json.Unmarshal(decrypted, &authData); err != nil {
			continue
		}
		if authData.Token == "" || strings.HasPrefix(authData.Token, "placeholder-") {
			continue
		}
		return &authData, nil
	}

	return nil, fmt.Errorf("备份 %s 中没有可用的 token", alias)
}

func fetchQuotaUsage(client *http.Client, token string) (*AccountQuota, int, error) {
	req, err := http.NewRequest("GET", qoderCNQuotaUsageAPI, nil)
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

	var data quotaUsageResponse
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, resp.StatusCode, err
	}

	used := data.UserQuota.Used + data.AddOnQuota.Used
	total := data.UserQuota.Total + data.AddOnQuota.Total
	remaining := data.UserQuota.Remaining + data.AddOnQuota.Remaining
	if remaining < 0 {
		remaining = 0
	}
	if remaining > total {
		remaining = total
	}

	return &AccountQuota{Used: used, Total: total, Remaining: remaining}, resp.StatusCode, nil
}

func formatQuotaNumber(v float64) string {
	return strconv.FormatFloat(v, 'f', -1, 64)
}
