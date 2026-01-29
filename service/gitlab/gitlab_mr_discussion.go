package gitlab

import (
	"context"
	"fmt"
	"log"
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
	cli      *gitlab.Client
	pr       int
	sha      string
	projects string
	toolName string

	muComments          sync.Mutex
	postComments        []*reviewdog.Comment
	postedcs            commentutil.PostedComments
	outdatedDiscussions map[string]*gitlab.Discussion // fingerprint -> discussion
}

// NewGitLabMergeRequestDiscussionCommenter returns a new MergeRequestDiscussionCommenter service.
// MergeRequestDiscussionCommenter service needs git command in $PATH.
func NewGitLabMergeRequestDiscussionCommenter(cli *gitlab.Client, owner, repo string, pr int, sha, toolName string) *MergeRequestDiscussionCommenter {
	return &MergeRequestDiscussionCommenter{
		cli:      cli,
		pr:       pr,
		sha:      sha,
		projects: owner + "/" + repo,
		toolName: toolName,
	}
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
func (g *MergeRequestDiscussionCommenter) Flush(ctx context.Context) error {
	g.muComments.Lock()
	defer g.muComments.Unlock()
	defer func() { g.postComments = nil }()

	if err := g.setPostedComments(); err != nil {
		return fmt.Errorf("failed to set posted comments: %w", err)
	}
	if err := g.postCommentsForEach(ctx); err != nil {
		return err
	}
	return g.resolveOutdatedDiscussions(ctx)
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

func (g *MergeRequestDiscussionCommenter) postCommentsForEach(ctx context.Context) error {
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

		// Calculate fingerprint for this diagnostic
		fprint, err := serviceutil.Fingerprint(c.Result.Diagnostic)
		if err != nil {
			log.Printf("reviewdog: failed to calculate fingerprint: %v", err)
			continue
		}

		// Check if already posted using fingerprint
		if g.postedcs.IsPosted(c, lnum, fprint) {
			// Mark as non-outdated (issue still exists)
			delete(g.outdatedDiscussions, fprint)
			continue
		}

		// Build body with meta comment
		body := commentutil.MarkdownComment(c)
		if suggestion := buildSuggestions(c); suggestion != "" {
			body = body + "\n\n" + suggestion
		}
		body = body + "\n" + serviceutil.BuildMetaComment(fprint, g.toolName)

		eg.Go(func() error {
			pos := &gitlab.PositionOptions{
				StartSHA:     gitlab.Ptr(targetBranch.Commit.ID),
				HeadSHA:      gitlab.Ptr(g.sha),
				BaseSHA:      gitlab.Ptr(targetBranch.Commit.ID),
				PositionType: gitlab.Ptr("text"),
				NewPath:      gitlab.Ptr(loc.GetPath()),
				NewLine:      gitlab.Ptr(int64(lnum)),
			}
			if c.Result.OldPath != "" && c.Result.OldLine != 0 {
				pos.OldPath = gitlab.Ptr(c.Result.OldPath)
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

func (g *MergeRequestDiscussionCommenter) resolveOutdatedDiscussions(ctx context.Context) error {
	var eg errgroup.Group
	for _, d := range g.outdatedDiscussions {
		d := d
		// Skip already resolved discussions
		if isDiscussionResolved(d) {
			continue
		}
		eg.Go(func() error {
			resolved := true
			_, _, err := g.cli.Discussions.ResolveMergeRequestDiscussion(
				g.projects,
				int64(g.pr),
				d.ID,
				&gitlab.ResolveMergeRequestDiscussionOptions{
					Resolved: &resolved,
				},
				gitlab.WithContext(ctx),
			)
			if err != nil {
				return fmt.Errorf("failed to resolve discussion %s: %w", d.ID, err)
			}
			return nil
		})
	}
	return eg.Wait()
}

func isDiscussionResolved(d *gitlab.Discussion) bool {
	for _, note := range d.Notes {
		if note.Resolvable && !note.Resolved {
			return false
		}
	}
	return true
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
