package gitlab

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"

	gitlab "gitlab.com/gitlab-org/api/client-go"
	"golang.org/x/sync/errgroup"

	"github.com/reviewdog/reviewdog"
	"github.com/reviewdog/reviewdog/proto/rdf"
	"github.com/reviewdog/reviewdog/service/commentutil"
	"github.com/reviewdog/reviewdog/service/serviceutil"
)

const (
	invalidSuggestionPre  = "<details><summary>reviewdog suggestion error</summary>"
	invalidSuggestionPost = "</details>"
)

// MergeRequestDiscussionCommenter is a comment and diff service for GitLab MergeRequest.
//
// API:
//
//	https://docs.gitlab.com/ee/api/discussions.html#create-new-merge-request-discussion
//	POST /projects/:id/merge_requests/:merge_request_iid/discussions
type MergeRequestDiscussionCommenter struct {
	cli       *gitlab.Client
	webClient *WebClient
	pr        int
	sha       string
	projects  string
	toolName  string
	batchMode bool // Use batch mode via web endpoint (requires username/password)

	muComments          sync.Mutex
	postComments        []*reviewdog.Comment
	postedcs            commentutil.PostedComments
	outdatedDiscussions map[string]*gitlab.Discussion // fingerprint -> discussion
}

// NewGitLabMergeRequestDiscussionCommenter returns a new MergeRequestDiscussionCommenter service.
// MergeRequestDiscussionCommenter service needs git command in $PATH.
//
// Batch mode can be enabled by setting environment variables:
//   - REVIEWDOG_GITLAB_BATCH_MODE=true
//   - REVIEWDOG_GITLAB_USERNAME (GitLab username)
//   - REVIEWDOG_GITLAB_PASSWORD (GitLab password)
//
// Batch mode uses GitLab web endpoint to create draft notes and publish them
// all at once, reducing email notifications. This is useful for older GitLab
// versions (like 16.0.8) where the API doesn't support batch operations.
func NewGitLabMergeRequestDiscussionCommenter(cli *gitlab.Client, owner, repo string, pr int, sha, toolName string) *MergeRequestDiscussionCommenter {
	commenter := &MergeRequestDiscussionCommenter{
		cli:      cli,
		pr:       pr,
		sha:      sha,
		projects: owner + "/" + repo,
		toolName: toolName,
	}

	// Check if batch mode is enabled
	if os.Getenv("REVIEWDOG_GITLAB_BATCH_MODE") == "true" {
		username := os.Getenv("REVIEWDOG_GITLAB_USERNAME")
		password := os.Getenv("REVIEWDOG_GITLAB_PASSWORD")
		if username != "" && password != "" {
			commenter.batchMode = true
			log.Printf("reviewdog: GitLab batch mode enabled")
		} else {
			log.Printf("reviewdog: batch mode requested but REVIEWDOG_GITLAB_USERNAME/PASSWORD not set, using standard mode")
		}
	}

	return commenter
}

// Post accepts a comment and holds it. Flush method actually posts comments to
// GitLab in parallel.
func (g *MergeRequestDiscussionCommenter) Post(_ context.Context, c *reviewdog.Comment) error {
	g.muComments.Lock()
	defer g.muComments.Unlock()
	g.postComments = append(g.postComments, c)
	return nil
}

func (*MergeRequestDiscussionCommenter) ShouldPrependGitRelDir() bool { return true }

// Flush posts comments which has not been posted yet.
// If batch mode is enabled, uses web endpoint to create draft notes and publish them all at once.
// Otherwise, uses Discussions API for creating comments (compatible with all GitLab versions).
// Deletes outdated discussions in parallel (no email notifications).
func (g *MergeRequestDiscussionCommenter) Flush(ctx context.Context) error {
	g.muComments.Lock()
	defer g.muComments.Unlock()
	defer func() { g.postComments = nil }()

	if err := g.setPostedComments(); err != nil {
		return fmt.Errorf("failed to set posted comments: %w", err)
	}

	// Use batch mode if enabled
	if g.batchMode {
		if err := g.postCommentsViaBatch(ctx); err != nil {
			log.Printf("reviewdog: batch mode failed, falling back to standard mode: %v", err)
			// Fall back to standard mode
			if err := g.postCommentsViaDiscussions(ctx); err != nil {
				return err
			}
		}
	} else {
		// Create new comments via Discussions API (works on all GitLab versions)
		if err := g.postCommentsViaDiscussions(ctx); err != nil {
			return err
		}
	}

	// Delete outdated discussions (no email notifications)
	return g.deleteOutdatedDiscussions(ctx)
}

// postCommentsViaBatch creates new comments using draft notes via web endpoint.
// This allows posting all comments at once, minimizing email notifications.
func (g *MergeRequestDiscussionCommenter) postCommentsViaBatch(ctx context.Context) error {
	username := os.Getenv("REVIEWDOG_GITLAB_USERNAME")
	password := os.Getenv("REVIEWDOG_GITLAB_PASSWORD")

	// Get GitLab base URL from the client
	baseURL := g.cli.BaseURL().String()

	// Initialize web client
	webClient, err := NewWebClient(baseURL)
	if err != nil {
		return fmt.Errorf("failed to create web client: %w", err)
	}
	g.webClient = webClient

	// Login
	if err := webClient.Login(username, password); err != nil {
		return fmt.Errorf("failed to login: %w", err)
	}

	// Refresh CSRF token
	if err := webClient.RefreshCSRFToken(g.projects, g.pr); err != nil {
		return fmt.Errorf("failed to refresh CSRF token: %w", err)
	}

	// Get MR info for position data
	mr, _, err := g.cli.MergeRequests.GetMergeRequest(g.projects, int64(g.pr), nil, gitlab.WithContext(ctx))
	if err != nil {
		return fmt.Errorf("failed to get merge request: %w", err)
	}
	targetBranch, _, err := g.cli.Branches.GetBranch(mr.TargetProjectID, mr.TargetBranch, nil)
	if err != nil {
		return err
	}

	// Collect comments to post
	var commentsToPost []struct {
		body     string
		position DraftNotePosition
	}

	for _, c := range g.postComments {
		loc := c.Result.Diagnostic.GetLocation()
		lnum := int(loc.GetRange().GetStart().GetLine())

		if !c.Result.InDiffFile || lnum == 0 {
			continue
		}

		fprint, err := serviceutil.Fingerprint(c.Result.Diagnostic)
		if err != nil {
			log.Printf("reviewdog: failed to calculate fingerprint: %v", err)
			continue
		}

		if g.postedcs.IsPosted(c, lnum, fprint) {
			delete(g.outdatedDiscussions, fprint)
			continue
		}

		body := commentutil.MarkdownComment(c)
		if suggestion := buildSuggestions(c); suggestion != "" {
			body = body + "\n\n" + suggestion
		}
		body = body + "\n" + serviceutil.BuildMetaComment(fprint, g.toolName)

		// Build position
		oldPath := loc.GetPath()
		if c.Result.OldPath != "" {
			oldPath = c.Result.OldPath
		}

		position := DraftNotePosition{
			BaseSHA:      targetBranch.Commit.ID,
			StartSHA:     targetBranch.Commit.ID,
			HeadSHA:      g.sha,
			OldPath:      oldPath,
			NewPath:      loc.GetPath(),
			PositionType: "text",
			NewLine:      lnum,
		}
		if c.Result.OldLine != 0 {
			oldLine := int(c.Result.OldLine)
			position.OldLine = &oldLine
		}

		commentsToPost = append(commentsToPost, struct {
			body     string
			position DraftNotePosition
		}{body: body, position: position})
	}

	if len(commentsToPost) == 0 {
		return nil
	}

	// Create draft notes
	for _, c := range commentsToPost {
		_, err := webClient.CreateDraftNote(g.projects, g.pr, c.body, c.position)
		if err != nil {
			return fmt.Errorf("failed to create draft note: %w", err)
		}
	}

	// Publish all draft notes at once
	if err := webClient.PublishAllDraftNotes(g.projects, g.pr); err != nil {
		return fmt.Errorf("failed to publish draft notes: %w", err)
	}

	log.Printf("reviewdog: published %d comments in batch mode", len(commentsToPost))
	return nil
}

// postCommentsViaDiscussions creates new discussion comments using the Discussions API.
// This method is compatible with all GitLab versions including 16.0.8.
func (g *MergeRequestDiscussionCommenter) postCommentsViaDiscussions(ctx context.Context) error {
	mr, _, err := g.cli.MergeRequests.GetMergeRequest(g.projects, int64(g.pr), nil, gitlab.WithContext(ctx))
	if err != nil {
		return fmt.Errorf("failed to get merge request: %w", err)
	}
	targetBranch, _, err := g.cli.Branches.GetBranch(mr.TargetProjectID, mr.TargetBranch, nil)
	if err != nil {
		return err
	}

	var eg errgroup.Group
	for _, c := range g.postComments {
		c := c
		loc := c.Result.Diagnostic.GetLocation()
		lnum := int(loc.GetRange().GetStart().GetLine())

		if !c.Result.InDiffFile || lnum == 0 {
			continue
		}

		fprint, err := serviceutil.Fingerprint(c.Result.Diagnostic)
		if err != nil {
			log.Printf("reviewdog: failed to calculate fingerprint: %v", err)
			continue
		}

		if g.postedcs.IsPosted(c, lnum, fprint) {
			delete(g.outdatedDiscussions, fprint)
			continue
		}

		body := commentutil.MarkdownComment(c)
		if suggestion := buildSuggestions(c); suggestion != "" {
			body = body + "\n\n" + suggestion
		}
		body = body + "\n" + serviceutil.BuildMetaComment(fprint, g.toolName)

		eg.Go(func() error {
			// old_path is required for text position type
			oldPath := loc.GetPath()
			if c.Result.OldPath != "" {
				oldPath = c.Result.OldPath
			}

			pos := &gitlab.PositionOptions{
				StartSHA:     gitlab.Ptr(targetBranch.Commit.ID),
				HeadSHA:      gitlab.Ptr(g.sha),
				BaseSHA:      gitlab.Ptr(targetBranch.Commit.ID),
				PositionType: gitlab.Ptr("text"),
				OldPath:      gitlab.Ptr(oldPath),
				NewPath:      gitlab.Ptr(loc.GetPath()),
				NewLine:      gitlab.Ptr(int64(lnum)),
			}
			if c.Result.OldLine != 0 {
				pos.OldLine = gitlab.Ptr(int64(c.Result.OldLine))
			}

			discussion := &gitlab.CreateMergeRequestDiscussionOptions{
				Body:     gitlab.Ptr(body),
				Position: pos,
			}
			_, _, err := g.cli.Discussions.CreateMergeRequestDiscussion(g.projects, int64(g.pr), discussion)
			if err != nil {
				return fmt.Errorf("failed to create merge request discussion: %w", err)
			}
			return nil
		})
	}
	return eg.Wait()
}

// deleteOutdatedDiscussions deletes discussions that are no longer relevant.
// Unlike resolving, deleting does not send email notifications.
func (g *MergeRequestDiscussionCommenter) deleteOutdatedDiscussions(ctx context.Context) error {
	var eg errgroup.Group

	for _, d := range g.outdatedDiscussions {
		d := d
		// Skip if no notes or already resolved
		if len(d.Notes) == 0 {
			continue
		}
		eg.Go(func() error {
			// Delete the first note in the discussion (which is the main comment)
			_, err := g.cli.Discussions.DeleteMergeRequestDiscussionNote(
				g.projects,
				int64(g.pr),
				d.ID,
				d.Notes[0].ID,
				gitlab.WithContext(ctx),
			)
			if err != nil {
				return fmt.Errorf("failed to delete discussion note %s/%d: %w", d.ID, d.Notes[0].ID, err)
			}
			return nil
		})
	}

	return eg.Wait()
}

func (g *MergeRequestDiscussionCommenter) setPostedComments() error {
	g.postedcs = make(commentutil.PostedComments)
	g.outdatedDiscussions = make(map[string]*gitlab.Discussion)

	discussions, err := listAllMergeRequestDiscussion(g.cli, g.projects, g.pr, &gitlab.ListMergeRequestDiscussionsOptions{
		ListOptions: gitlab.ListOptions{
			PerPage: 100,
		},
	})
	if err != nil {
		return fmt.Errorf("failed to list all merge request discussions: %w", err)
	}
	for _, d := range discussions {
		for _, note := range d.Notes {
			pos := note.Position
			if pos == nil || pos.NewPath == "" || pos.NewLine == 0 || note.Body == "" {
				continue
			}
			// Extract meta comment to get fingerprint
			if meta := serviceutil.ExtractMetaComment(note.Body); meta != nil {
				g.postedcs.AddPostedComment(pos.NewPath, int(pos.NewLine), meta.GetFingerprint())
				// Track discussions from the same tool for potential resolution
				if meta.SourceName == g.toolName {
					g.outdatedDiscussions[meta.GetFingerprint()] = d
				}
			} else {
				// Legacy: fallback to body matching for comments without meta
				g.postedcs.AddPostedComment(pos.NewPath, int(pos.NewLine), note.Body)
			}
		}
	}
	return nil
}

func listAllMergeRequestDiscussion(cli *gitlab.Client, projectID string, mergeRequest int, opts *gitlab.ListMergeRequestDiscussionsOptions) ([]*gitlab.Discussion, error) {
	discussions, resp, err := cli.Discussions.ListMergeRequestDiscussions(projectID, int64(mergeRequest), opts)
	if err != nil {
		return nil, err
	}
	if resp.NextPage == 0 {
		return discussions, nil
	}
	newOpts := &gitlab.ListMergeRequestDiscussionsOptions{
		ListOptions: gitlab.ListOptions{
			Page:    resp.NextPage,
			PerPage: opts.PerPage,
		},
	}
	restDiscussions, err := listAllMergeRequestDiscussion(cli, projectID, mergeRequest, newOpts)
	if err != nil {
		return nil, err
	}
	return append(discussions, restDiscussions...), nil
}

// creates diff in markdown for suggested changes
// Ref gitlab suggestion: https://docs.gitlab.com/ee/user/project/merge_requests/reviews/suggestions.html
func buildSuggestions(c *reviewdog.Comment) string {
	var sb strings.Builder
	for _, s := range c.Result.Diagnostic.GetSuggestions() {
		if s.Range == nil || s.Range.Start == nil || s.Range.End == nil {
			continue
		}

		txt, err := buildSingleSuggestion(c, s)
		if err != nil {
			sb.WriteString(invalidSuggestionPre + err.Error() + invalidSuggestionPost + "\n")
			continue
		}
		sb.WriteString(txt)
		sb.WriteString("\n")
	}

	return sb.String()
}

func buildSingleSuggestion(c *reviewdog.Comment, s *rdf.Suggestion) (string, error) {
	var sb strings.Builder

	// we might need to use 4 or more backticks
	//
	// https://docs.gitlab.com/ee/user/project/merge_requests/reviews/suggestions.html#code-block-nested-in-suggestions
	// > If you need to make a suggestion that involves a fenced code block, wrap your suggestion in four backticks instead of the usual three.
	//
	// The documentation doesn't explicitly say anything about cases more than 4 backticks,
	// however it seems to be handled as intended.
	txt := s.GetText()
	backticks := commentutil.GetCodeFenceLength(txt)

	lines := strconv.Itoa(int(s.Range.End.Line - s.Range.Start.Line))
	sb.Grow(backticks + len("suggestion:-0+\n") + len(lines) + len(txt) + len("\n") + backticks)
	commentutil.WriteCodeFence(&sb, backticks)
	sb.WriteString("suggestion:-0+")
	sb.WriteString(lines)
	sb.WriteString("\n")
	if txt != "" {
		sb.WriteString(txt)
		sb.WriteString("\n")
	}
	commentutil.WriteCodeFence(&sb, backticks)

	return sb.String(), nil
}
