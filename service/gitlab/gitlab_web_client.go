package gitlab

import (
	"bytes"
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"regexp"
	"strings"
)

// WebClient provides access to GitLab web endpoints that require session-based authentication.
// This is used for batch operations (draft notes) on older GitLab versions where the API
// doesn't support position parameters for draft notes.
type WebClient struct {
	httpClient *http.Client
	baseURL    string
	csrfToken  string
	loggedIn   bool
}

// DraftNotePosition represents the position for a draft note comment.
type DraftNotePosition struct {
	BaseSHA      string `json:"base_sha"`
	StartSHA     string `json:"start_sha"`
	HeadSHA      string `json:"head_sha"`
	OldPath      string `json:"old_path"`
	NewPath      string `json:"new_path"`
	PositionType string `json:"position_type"`
	OldLine      *int   `json:"old_line"`
	NewLine      int    `json:"new_line"`
}

// DraftNoteRequest represents a request to create a draft note via web endpoint.
type DraftNoteRequest struct {
	MergeRequestDiffHeadSHA string         `json:"merge_request_diff_head_sha"`
	TargetType              string         `json:"target_type"`
	TargetID                int            `json:"target_id"`
	ReturnDiscussion        bool           `json:"return_discussion"`
	DraftNote               DraftNoteEntry `json:"draft_note"`
}

// DraftNoteEntry represents the draft_note field in the request.
type DraftNoteEntry struct {
	Note         string `json:"note"`
	Position     string `json:"position"` // JSON string of DraftNotePosition
	NoteableType string `json:"noteable_type"`
	NoteableID   int    `json:"noteable_id"`
	Type         string `json:"type"`
	LineCode     string `json:"line_code"`
}

// DraftNoteResponse represents the response from creating a draft note.
type DraftNoteResponse struct {
	ID       int    `json:"id"`
	Note     string `json:"note"`
	FilePath string `json:"file_path"`
	Position struct {
		NewLine int `json:"new_line"`
		OldLine int `json:"old_line"`
	} `json:"position"`
}

// PublishRequest represents a request to publish all draft notes.
type PublishRequest struct {
	NoteableType string `json:"noteable_type"`
	NoteableID   int    `json:"noteable_id"`
	Note         string `json:"note"`
	Approve      bool   `json:"approve"`
}

// NewWebClient creates a new GitLab web client for session-based operations.
func NewWebClient(baseURL string) (*WebClient, error) {
	// Parse base URL to get the host
	u, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid base URL: %w", err)
	}

	// Remove /api/v4 suffix to get the web base URL
	webBaseURL := fmt.Sprintf("%s://%s", u.Scheme, u.Host)

	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create cookie jar: %w", err)
	}

	return &WebClient{
		httpClient: &http.Client{
			Jar: jar,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		baseURL: webBaseURL,
	}, nil
}

// Login authenticates with GitLab using username and password.
func (c *WebClient) Login(username, password string) error {
	// Step 1: Get sign-in page and extract CSRF token
	signInURL := c.baseURL + "/users/sign_in"
	resp, err := c.httpClient.Get(signInURL)
	if err != nil {
		return fmt.Errorf("failed to get sign-in page: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read sign-in page: %w", err)
	}

	csrfToken := extractCSRFToken(string(body), "authenticity_token")
	if csrfToken == "" {
		return fmt.Errorf("failed to extract CSRF token from sign-in page")
	}

	// Step 2: Submit login form
	loginData := url.Values{
		"authenticity_token": {csrfToken},
		"user[login]":        {username},
		"user[password]":     {password},
	}

	req, err := http.NewRequest("POST", signInURL, strings.NewReader(loginData.Encode()))
	if err != nil {
		return fmt.Errorf("failed to create login request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err = c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to submit login: %w", err)
	}
	defer resp.Body.Close()

	// Check for successful login (should redirect)
	if resp.StatusCode != http.StatusFound && resp.StatusCode != http.StatusSeeOther {
		return fmt.Errorf("login failed with status: %d", resp.StatusCode)
	}

	c.loggedIn = true
	return nil
}

// RefreshCSRFToken fetches a fresh CSRF token from the MR diff page.
func (c *WebClient) RefreshCSRFToken(project string, mrIID int) error {
	if !c.loggedIn {
		return fmt.Errorf("not logged in")
	}

	diffURL := fmt.Sprintf("%s/%s/-/merge_requests/%d/diffs", c.baseURL, project, mrIID)
	resp, err := c.httpClient.Get(diffURL)
	if err != nil {
		return fmt.Errorf("failed to get MR diff page: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read MR diff page: %w", err)
	}

	c.csrfToken = extractCSRFToken(string(body), "csrf-token")
	if c.csrfToken == "" {
		return fmt.Errorf("failed to extract CSRF token from MR page")
	}

	return nil
}

// CreateDraftNote creates a draft note via the web endpoint.
func (c *WebClient) CreateDraftNote(project string, mrIID int, note string, position DraftNotePosition) (*DraftNoteResponse, error) {
	if !c.loggedIn {
		return nil, fmt.Errorf("not logged in")
	}
	if c.csrfToken == "" {
		return nil, fmt.Errorf("CSRF token not set, call RefreshCSRFToken first")
	}

	// Serialize position to JSON string
	positionJSON, err := json.Marshal(position)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal position: %w", err)
	}

	// Calculate line_code: sha1(file_path)_oldLine_newLine
	lineCode := calculateLineCode(position.NewPath, position.OldLine, position.NewLine)

	reqBody := DraftNoteRequest{
		MergeRequestDiffHeadSHA: position.HeadSHA,
		TargetType:              "merge_request",
		TargetID:                mrIID,
		ReturnDiscussion:        true,
		DraftNote: DraftNoteEntry{
			Note:         note,
			Position:     string(positionJSON),
			NoteableType: "MergeRequest",
			NoteableID:   mrIID,
			Type:         "DiffNote",
			LineCode:     lineCode,
		},
	}

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	draftsURL := fmt.Sprintf("%s/%s/-/merge_requests/%d/drafts", c.baseURL, project, mrIID)
	req, err := http.NewRequest("POST", draftsURL, bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-CSRF-Token", c.csrfToken)
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to create draft note: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("failed to create draft note: status %d, body: %s", resp.StatusCode, string(body))
	}

	var draftResp DraftNoteResponse
	if err := json.NewDecoder(resp.Body).Decode(&draftResp); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return &draftResp, nil
}

// PublishAllDraftNotes publishes all pending draft notes.
func (c *WebClient) PublishAllDraftNotes(project string, mrIID int) error {
	if !c.loggedIn {
		return fmt.Errorf("not logged in")
	}
	if c.csrfToken == "" {
		return fmt.Errorf("CSRF token not set")
	}

	reqBody := PublishRequest{
		NoteableType: "MergeRequest",
		NoteableID:   mrIID,
		Note:         "",
		Approve:      false,
	}

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return fmt.Errorf("failed to marshal publish request: %w", err)
	}

	publishURL := fmt.Sprintf("%s/%s/-/merge_requests/%d/drafts/publish", c.baseURL, project, mrIID)
	req, err := http.NewRequest("POST", publishURL, bytes.NewReader(bodyBytes))
	if err != nil {
		return fmt.Errorf("failed to create publish request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-CSRF-Token", c.csrfToken)
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to publish draft notes: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to publish draft notes: status %d, body: %s", resp.StatusCode, string(body))
	}

	return nil
}

// IsLoggedIn returns whether the client is currently logged in.
func (c *WebClient) IsLoggedIn() bool {
	return c.loggedIn
}

// extractCSRFToken extracts CSRF token from HTML content.
func extractCSRFToken(html, tokenType string) string {
	var pattern string
	switch tokenType {
	case "authenticity_token":
		pattern = `name="authenticity_token" value="([^"]+)"`
	case "csrf-token":
		pattern = `name="csrf-token" content="([^"]+)"`
	default:
		return ""
	}

	re := regexp.MustCompile(pattern)
	matches := re.FindStringSubmatch(html)
	if len(matches) > 1 {
		return matches[1]
	}
	return ""
}

// calculateLineCode generates line_code for GitLab: sha1(filepath)_oldLine_newLine
func calculateLineCode(filePath string, oldLine *int, newLine int) string {
	// GitLab uses SHA1 of the file path
	h := sha1Hash(filePath)
	old := 0
	if oldLine != nil {
		old = *oldLine
	}
	return fmt.Sprintf("%s_%d_%d", h, old, newLine)
}

// sha1Hash returns SHA1 hash of a string.
func sha1Hash(s string) string {
	h := sha1.Sum([]byte(s))
	return fmt.Sprintf("%x", h)
}
