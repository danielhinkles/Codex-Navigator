import Foundation

struct QuickPrompt:Identifiable,Codable,Equatable {
    let id,title,length,text:String
    var isPersonal: Bool = false
    static let standard:[QuickPrompt] = [
        .init(id:"resume",title:"Where Was I?",length:"Short",text:"""
        Summarise where I left off in this game development project in no more than 280 characters total. Use the available conversation and project evidence: last completed work, unfinished work, and the immediate next step. If context is missing, say so; do not invent progress. Report only; do not change files.
        """),
        .init(id:"repo",title:"Repo Check",length:"Short",text:"""
        Give an incredibly brief repository readiness report so I know whether I can continue or need to deal with hidden work first. Inspect the current branch, staged/unstaged/untracked changes, conflicts, in-progress merges/rebases, stashes, other worktrees, unmerged local branches, and ahead/behind status against available remote-tracking refs. Distinguish unmerged work from work that actually needs merging; flag stale or unavailable remote information. Start with READY, ATTENTION, or UNKNOWN, then at most 5 short bullets covering tree cleanliness, pending work, and the next action. If this is not a Git repo, say so. Report only; do not modify, merge, stash, commit, or discard anything.
        """),
        .init(id:"design",title:"Evaluate Design",length:"Medium",text:"Evaluate this project honestly using its UI, features and available visual evidence. Report only; do not implement changes. Give five positives first (Love or Like), then five negatives (Dislike or Hate). Rank all ten by importance and estimate Impact per Effort from 1–5. Separate observed evidence from preferences. Finish with five prioritised recommendations, each with a concrete action, expected benefit and approximate effort. State what you could not evaluate."),
        .init(id:"bugs",title:"Bug Hunt",length:"Medium",text:"""
        Scan the entire game development project for bugs, covering gameplay, progression and saves, UI, input, performance, and integrations where present. Inspect all relevant first-party code and project configuration, and run appropriate existing checks where feasible. State coverage gaps and distinguish confirmed defects from suspected issues; do not claim exhaustive coverage if parts could not be checked. This pass is diagnosis only; do not fix bugs yet.

        Rank findings by priority (P0 critical, P1 high, P2 medium, P3 low), considering severity, likelihood, and player impact. Give each a quick-glance QA category such as Crash, Data Loss, Progression Blocker, Functional Defect, UI/Visual Defect, Performance, Accessibility, or Compatibility. Include concise evidence/file locations, reproduction steps where known, impact, and a proposed fix. Label each Technical Fix (no design decision needed) or Design Decision / User Approval Required, explaining any question that blocks a fix. Do not treat subjective preferences as confirmed bugs.

        Finish with concise recommendations and ask me to choose one of these 3 options:
        1. Fix the top 10 highest-priority bugs (or all findings if fewer than 10); ask about any required design decisions before their fixes.
        2. Fix all technical bugs that do not need my input; leave design-dependent findings pending.
        3. Fix all bugs; explain that I may need to answer follow-up design questions before affected fixes can proceed.
        Wait for my choice before making fixes.
        """)
    ]
}
