# Issue tracker: GitHub

Repository: sesameoil13/note-agent (https://github.com/sesameoil13/note-agent).
Issues and specs live in GitHub Issues. Use the gh CLI; infer the repository from origin when in this checkout, or pass --repo sesameoil13/note-agent explicitly.

## Operations

- Create: gh issue create --repo sesameoil13/note-agent --title "..." --body-file <file>.
- Read: gh issue view <number> --repo sesameoil13/note-agent --json number,title,body,labels,comments.
- List: gh issue list --repo sesameoil13/note-agent --state open --json number,title,body,labels,comments, using appropriate label/state filters.
- Comment: gh issue comment <number> --repo sesameoil13/note-agent --body-file <file>.
- Labels: gh issue edit <number> --repo sesameoil13/note-agent --add-label <label> or --remove-label <label>.
- Close: gh issue close <number> --repo sesameoil13/note-agent; post an explanatory comment first when needed.
- For multiline bodies, write the exact text to a temporary file and use --body-file.

## Pull requests as a triage surface

PRs as a request surface: no.

## Skill terminology

"Publish to the issue tracker" means create a GitHub issue.
"Fetch the relevant ticket" means read that GitHub issue, including labels and comments.
GitHub shares issue and PR numbers; resolve ambiguity before updating a numbered item.

## Wayfinding

- Map: an issue labeled wayfinder:map, with Notes / Decisions-so-far / Fog.
- Child tickets: link as sub-issues when supported; otherwise record Part of #<map> and maintain the map task list. Label by wayfinder:<type> (research/prototype/grilling/task).
- Dependencies: use native blocking links when supported; otherwise add Blocked by: #<number> near the top of the body. A ticket is unblocked when every blocker is closed.
- Frontier: open, unblocked, unassigned children, in map order.
- Claim: assign the ticket to the driving developer before work.
- Resolve: comment the result, close the ticket, and append a concise result and link to the map.
