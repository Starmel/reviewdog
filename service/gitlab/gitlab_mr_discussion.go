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
// Uses Draft Notes API for batch operations (single notification for all changes).
func (g *MergeRequestDiscussionCommenter) Flush(ctx context.Context) error {
	g.muComments.Lock()
	defer g.muComments.Unlock()
	defer func() { g.postComments = nil }()

	if err := g.setPostedComments(); err != nil {
		return fmt.Errorf("failed to set posted comments: %w", err)
	}

	// Create all draft notes (new comments + resolve replies) then bulk publish once
	draftsCreated, err := g.createDraftNotes(ctx)
	if err != nil {
		return err
	}

	// Single bulk publish for all drafts (one notification)
	if draftsCreated > 0 {
		_, err := g.cli.DraftNotes.PublishAllDraftNotes(g.projects, int64(g.pr), gitlab.WithContext(ctx))
		if err != nil {
			return fmt.Errorf("failed to publish draft notes: %w", err)
		}
	}

	return nil
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

// createDraftNotes creates draft notes for new comments and resolve replies.
// Returns the total number of drafts created.
func (g *MergeRequestDiscussionCommenter) createDraftNotes(ctx context.Context) (int, error) {
	mr, _, err := g.cli.MergeRequests.GetMergeRequest(g.projects, int64(g.pr), nil, gitlab.WithContext(ctx))
	if err != nil {
		return 0, fmt.Errorf("failed to get merge request: %w", err)
	}
	targetBranch, _, err := g.cli.Branches.GetBranch(mr.TargetProjectID, mr.TargetBranch, nil)
	if err != nil {
		return 0, err
	}

	var draftsCreated int
	var eg errgroup.Group

	// Create draft notes for new comments
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

		draftsCreated++
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
			draftNote := &gitlab.CreateDraftNoteOptions{
				Note:     gitlab.Ptr(body),
				Position: pos,
			}
			_, _, err := g.cli.DraftNotes.CreateDraftNote(g.projects, int64(g.pr), draftNote, gitlab.WithContext(ctx))
			if err != nil {
				return fmt.Errorf("failed to create draft note: %w", err)
			}
			return nil
		})
	}

	// Create draft notes with resolve flag for outdated discussions
	for _, d := range g.outdatedDiscussions {
		d := d
		if isDiscussionResolved(d) {
			continue
		}
		draftsCreated++
		eg.Go(func() error {
			draftNote := &gitlab.CreateDraftNoteOptions{
				Note:                  gitlab.Ptr("Issue resolved."),
				InReplyToDiscussionID: gitlab.Ptr(d.ID),
				ResolveDiscussion:     gitlab.Ptr(true),
			}
			_, _, err := g.cli.DraftNotes.CreateDraftNote(g.projects, int64(g.pr), draftNote, gitlab.WithContext(ctx))
			if err != nil {
				return fmt.Errorf("failed to create resolve draft note for discussion %s: %w", d.ID, err)
			}
			return nil
		})
	}

	if err := eg.Wait(); err != nil {
		return draftsCreated, err
	}

	return draftsCreated, nil
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
