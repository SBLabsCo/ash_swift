export const meta = {
  name: 'ship-ticket',
  description: 'Drive ready-for-agent ash_swift tickets to merge-ready PRs: preflight, implement, pre-PR review, address, open, drive to clean. Never merges.',
  whenToUse: 'Run with {issues: [n, ...], concurrency?: 3, answers?: {"<n>": "answer to its BLOCKED question"}} to ship ready-for-agent tickets through the delivery loop (docs/agents/ship-ticket.md). Ends at merge-ready; merge stays the human gate. One BLOCKED round per ticket per run can be answered.',
  phases: [
    { title: 'Preflight', detail: 'bin/orchestration-fresh (once), then bin/ticket-preflight --check-only per ticket, outside any isolated agent' },
    { title: 'Implement', detail: 'implementer agent in its own worktree, stops at READY' },
    { title: 'Review', detail: 'reviewer, refactorer, security and (on code) architect in parallel (skipped for docs-only diffs)' },
    { title: 'Address', detail: 'fix or decline each finding in the implementer worktree' },
    { title: 'Open PR', detail: 'bin/pr-open' },
    { title: 'Drive', detail: 'bin/pr-wait loop: rebase / fix CI / address review until merge-ready; then bin/pr-record posts the run record on the PR' },
  ],
}

// ---------------------------------------------------------------------------
// Ported from SBLabsCo/SwingClips' ship-ticket workflow, minus its iOS/web visual evidence and
// backend Client-Compatibility stages. Shape, and why:
//
// * The script owns every decision it can make from JSON; bin/ scripts do the
//   deterministic work; agents only implement, review, address and fix. The
//   workflow runtime has no shell, so a script runs through a low-effort
//   "runner" agent that reports exit code + stdout JSON and does nothing else.
// * A worktree-isolated agent may run git ONLY in its own harness worktree,
//   so only the implementer is isolated. Every later stage is a NON-isolated
//   agent working in the implementer's worktree by absolute path — a fresh
//   isolated agent would get a new, empty worktree.
// * Branch facts (paths, head) come from git, never from an agent's self-report:
//   they drive the docs-only skip and which review lenses run.
// * Never merges. Returns one run record per ticket, and persists each one that has
//   a PR as a hidden, versioned comment on it (bin/pr-record; format in
//   docs/agents/ship-ticket.md). The comment is written LAST, once the outcome is known,
//   and updated in place on a re-run.
// ---------------------------------------------------------------------------

// The main checkout. The runtime has no shell to derive it, so pass args.main on any other machine;
// preflight fails fast (below) when it doesn't exist.
const MAIN = (args && args.main) || '/Users/scott/Projects/src/github.com/SBLabsCo/ash_swift'
const REPO = 'SBLabsCo/ash_swift'
const WORKTREES = MAIN + '/.claude/worktrees/'
const ISSUES = [...new Set(((args && args.issues) || []).map(Number))]
const CONCURRENCY = Math.max(1, (args && args.concurrency) || 3)
const ANSWERS = (args && args.answers) || {}
// Resume replays any agent call whose prompt is unchanged. Bumping args.attempt makes every
// post-open stage (pr-wait, fix) run live on a deliberate re-drive instead of
// replaying the last run's now-stale answers.
const ATTEMPT = (args && args.attempt) ? ` · attempt ${args.attempt}` : ''
const MAX_FIXES = 4          // drive-loop fix passes before escalating
const MAX_PENDING = 6        // consecutive pr-wait timeouts (≈9 min each) per head
const MAX_TOOL_RETRIES = 2   // pr-wait exit 3 (gh/tool failure) retries

// The gates every code change must pass locally (mirrors .github/workflows/ci.yml).
const GATES = '`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, and `swift test` when Sources/, Tests/ or Package.swift changed (or the change alters generated Swift)'

// Docs-only = no review needed. Agent instructions are not docs.
const isDocs = p => (p.startsWith('docs/') || p.endsWith('.md')) &&
  !p.startsWith('.claude/') && !/(^|\/)(CLAUDE|AGENTS)\.md$/.test(p)
// Code with a domain model to drift: the Elixir extension, the Swift runtime, and their tests.
const touchesDomain = paths => paths.some(p => /^(lib|Sources|test|Tests)\//.test(p))
// The pre-PR review lenses a (non-docs-only) diff gets, each an agent in .claude/agents/ of the same name. The reviewer,
// refactorer and security run on every one; the architect only where there is a domain model to drift (not bin/ or CI tooling).
const reviewersFor = paths => ['reviewer', 'refactorer', ...(touchesDomain(paths) ? ['architect'] : []), 'security']
// Follow-ups from several lenses can name one problem; bin/after-merge would file each. One per normalized title.
const uniqueFollowups = fs => fs.filter((f, i) => fs.findIndex(g => normTitle(g.title) === normTitle(f.title)) === i)
const normTitle = t => String(t || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()
// Each lens's brief; the agent definition of the same name carries the rest.
const LENSES = {
  reviewer: ctx => `Pre-PR review of ${ctx}`,
  refactorer: ctx => `Code-health review of ${ctx}\n\nWider opportunities go in followups (title + body), not findings.`,
  architect: ctx => `Domain-design review of ${ctx}\n\nWider modelling problems the diff exposed but did not cause go in followups (title + body), not findings.`,
  security: ctx => `Security review of ${ctx}\n\nPre-existing weaknesses the diff exposed but did not cause go in followups (title + body); anything exploitable today is a finding.`,
}
// The one run-record shape; ship() fills it and the freshness guard refuses with it.
const newRecord = n => ({
  v: 2, issue: n, outcome: null, reason: null,
  verdicts: {}, findings: [], fixed: [], declined: [], followups: [], blocked: [], rounds: [], action_verdicts: [],
})
// What bin/orchestration-fresh's run (the runner's result, or null if it died) means for the whole run:
// null when fresh, else {outcome, reason, message}. A stale checkout is 'refused'; a dead runner or a tool
// that could not run (exit 3, a missing script) is 'failed' -- unknown freshness is not staleness.
const freshnessRefusal = (fresh, main) => {
  if (!fresh) return { outcome: 'failed', reason: 'freshness_runner_died', message: 'the freshness runner died' }
  const json = fresh.json || {}
  if (fresh.exit_code === 0 && json.ok) return null
  if (json.reason === 'stale') return { outcome: 'refused', reason: 'stale_orchestration', message: json.message || `the main checkout's orchestration differs from origin/main: ${(json.paths || []).join(', ')}` }
  return { outcome: 'failed', reason: 'freshness_unknown', message: `bin/orchestration-fresh could not confirm the main checkout is current (exit ${fresh.exit_code}): ${json.message || fresh.stderr_tail || 'no output'}. If it is missing, ${main} predates it: git -C ${main} merge --ff-only origin/main` }
}

// Declared up here, not beside durable(), on purpose: `const`s below the top-level `await parallel(...)`
// are still uninitialised when the workers call durable(), which threw `Cannot access 'categorySlug'
// before initialization` and killed every ticket that reached its run record.
// A lens's category as the kebab-case slug the record contract requires (bin/pr-record refuses anything else,
// which would lose the whole record): lowercased, runs of anything else collapsed to one hyphen.
const categorySlug = c => String(c || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'uncategorized'
// A finding's problem as one line: whitespace collapsed, clipped.
const oneLine = (t, max) => String(t || '').replace(/\s+/g, ' ').trim().slice(0, max)
// POSIX single-quote a value for a shell command line.
const sq = v => "'" + String(v).replace(/'/g, "'\\''") + "'"

const RUN = {
  type: 'object',
  properties: {
    exit_code: { type: 'integer' },
    json: { type: 'object', description: "the one JSON object the command printed on stdout, parsed; {} if it printed none" },
    stdout_lines: { type: 'array', items: { type: 'string' }, description: 'only when asked for raw stdout lines' },
    stderr_tail: { type: 'string' },
  },
  required: ['exit_code', 'json'],
}

const IMPLEMENTED = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['READY', 'BLOCKED'] },
    worktree: { type: 'string', description: 'absolute output of `git rev-parse --show-toplevel` in your worktree' },
    summary: { type: 'string', description: 'PR summary paragraph(s): what changed and why, for reviewers. No `Closes` line — bin/pr-open writes it.' },
    question: { type: 'string', description: 'BLOCKED only: the one specific question for the maintainer' },
  },
  required: ['status', 'worktree', 'summary'],
}

const FINDINGS = {
  type: 'object',
  properties: {
    verdict: { type: 'string', description: 'your closing verdict word (READY / READY AFTER FIXES / NEEDS REWORK; the refactorer: CLEAN / CLEAN AFTER FIXES / RESHAPE)' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['must-fix', 'should-fix', 'nit'] },
          where: { type: 'string' },
          problem: { type: 'string' },
          fix: { type: 'string' },
          verified: { type: 'boolean' },
          category: { type: 'string', description: 'kebab-case slug naming the KIND of mistake, from docs/agents/finding-categories.md (coin a new one only when none fits). Read by bin/findings-retro.' },
        },
        required: ['severity', 'where', 'problem', 'fix', 'category'],
      },
    },
    probed_clean: { type: 'array', items: { type: 'string' }, description: 'what you checked and found sound' },
    followups: { type: 'array', items: { type: 'object', properties: { title: { type: 'string' }, body: { type: 'string' } }, required: ['title', 'body'] } },
  },
  required: ['verdict', 'findings'],
}

const ADDRESSED = {
  type: 'object',
  properties: {
    fixed: { type: 'array', items: { type: 'integer' }, description: 'ids of findings fixed' },
    declined: { type: 'array', items: { type: 'object', properties: { id: { type: 'integer' }, rationale: { type: 'string' } }, required: ['id', 'rationale'] } },
    suites_green: { type: 'boolean' },
  },
  required: ['fixed', 'declined', 'suites_green'],
}

const FIXED = {
  type: 'object',
  properties: {
    pushed: { type: 'boolean', description: 'true only if you pushed a new commit' },
    summary: { type: 'string' },
    declined: { type: 'array', items: { type: 'object', properties: { finding: { type: 'string' }, rationale: { type: 'string' } }, required: ['finding', 'rationale'] } },
  },
  required: ['pushed', 'summary'],
}

const IN_WORKTREE = wt =>
  `Work ONLY in the existing worktree ${wt}: start every Bash command with \`cd ${sq(wt)} &&\` and use absolute paths. ` +
  `First confirm \`git rev-parse --show-toplevel\` prints ${wt}; stop and report if not. ` +
  `NEVER run git, mix or swift in ${MAIN} itself (the maintainer's checkout); never edit .git/info/exclude, git config or hooks; never revert a file you did not change. ` +
  `Run bin/ test suites one at a time. Do not wait for CI or poll anything — this workflow does all waiting.`

// One script run through a runner agent.
const runScript = (cmd, cwd, phase, label, opts = {}) => agent(
  `Run exactly this one command and report its exit code, its stdout parsed as JSON (it prints one JSON object; {} if none)` +
  (opts.lines ? ', and every stdout line verbatim in stdout_lines' : '') +
  `, and the last few stderr lines. Run it with the Bash tool's timeout set to 600000 ms. Do not redirect its output to files — read it from the tool result. Do nothing else.\n\n` +
  `  cd ${sq(cwd)} && ${cmd}\n\n(${label})`,
  { phase, label, schema: RUN, model: 'sonnet', effort: 'low' })

// One script run through a runner agent that first writes `content` to a file outside the repo
// (any file in the worktree would make it dirty). `cmd` names that file as `<that dir>/${name}`.
const runWithFile = (wt, name, content, cmd, phase, label) => agent(
  `${IN_WORKTREE(wt)}\n\n` +
  `Run \`echo "$TMPDIR"\` and write the content below, exactly as given and nothing else, to <that dir>/${name} with the Write tool. Then run exactly this one command, with <that dir> substituted (Bash timeout 600000 ms), and report its exit code and stdout JSON:\n\n` +
  `  cd ${sq(wt)} && ${cmd}\n\nCONTENT:\n${content}`,
  { phase, label, schema: RUN, model: 'sonnet', effort: 'low' })

// ---------------------------------------------------------------------------

// Step zero, before any agent works: this script, the agent definitions and the skills are read from
// the main checkout's working tree, which nobody pulls for us. Refuse to run on machinery that differs from
// origin/main. If the guard is missing altogether, the checkout is older than the guard: same fix.
const fresh = await runScript('bin/orchestration-fresh', MAIN, 'Preflight', 'orchestration freshness')
const refusal = freshnessRefusal(fresh, MAIN)
if (refusal) {
  log(`ship-ticket did not start (${refusal.outcome}): ${refusal.message}`)
  return ISSUES.map(n => Object.assign(newRecord(n), refusal))
}

const queue = ISSUES.slice()
const records = []
const worker = async () => { while (queue.length) { const n = queue.shift(); records.push(await ship(n)) } }
// Everything below runs only after the workers finish, but the workers call into it first: declare helpers
// below this line as `function`s (hoisted), never `const`/`let`, or they hit the temporal dead zone.
await parallel(Array.from({ length: Math.min(CONCURRENCY, ISSUES.length) }, () => worker))
return records

async function ship(n) {
  const rec = newRecord(n)
  const done = (outcome, reason, extra) => { Object.assign(rec, { outcome, reason: reason || null }, extra || {}); log(`#${n}: ${outcome}${reason ? ' — ' + reason : ''}`); return rec }
  await drive(n, rec, done)
  // The record is final only here, whichever way drive() returned. No PR, nothing to attach it to.
  if (rec.pr) await persist(rec)
  return rec
}

// One ticket, start to outcome; every exit goes through done(), which fills rec.
async function drive(n, rec, done) {

  // 1. Readiness, outside any isolated agent.
  const pre = await runScript(`bin/ticket-preflight ${n} --check-only`, MAIN, 'Preflight', `preflight #${n}`)
  if (!pre) return done('failed', 'preflight runner died')
  if (pre.exit_code !== 0 && !pre.json.reason) return done('failed', `preflight could not run from ${MAIN} — is args.main this machine's main checkout?`, { message: pre.stderr_tail || null })
  if (pre.exit_code !== 0 || !pre.json.ok) return done('refused', pre.json.reason || `exit ${pre.exit_code}`, { message: pre.json.message || null })
  let branch = pre.json.branch

  // 2. Implement (isolated), with one answerable BLOCKED round.
  let impl = await implement(n, branch, null, 1)
  if (!impl) return done('failed', 'implementer died')
  if (!underWorktrees(impl.worktree)) return done('failed', `implementer reported an unexpected worktree: ${impl.worktree}`)
  if (impl.status === 'BLOCKED') {
    rec.blocked.push(impl.question)
    const answer = ANSWERS[String(n)]
    if (!answer) return done('blocked', null, { question: impl.question, worktree: impl.worktree })
    const alive = await runScript(`test -d ${sq(impl.worktree)} && git -C ${sq(impl.worktree)} status --porcelain | wc -l`, MAIN, 'Implement', `worktree alive? #${n}`)
    if (alive && alive.exit_code === 0) {
      impl = await continueInWorktree(n, impl.worktree, branch, impl.question, answer)
    } else {
      branch = branch + '-r2'   // the first attempt's branch name may still exist without its worktree
      impl = await implement(n, branch, answer, 2)
    }
    if (!impl) return done('failed', 'implementer died after the answer')
    if (!underWorktrees(impl.worktree)) return done('failed', `unexpected worktree: ${impl.worktree}`)
    if (impl.status === 'BLOCKED') { rec.blocked.push(impl.question); return done('blocked', 'blocked again — re-run with a new answer', { question: impl.question, worktree: impl.worktree }) }
  }
  const wt = impl.worktree
  rec.worktree = wt

  // 3. Branch facts from git, not from the implementer.
  let facts = await branchFacts(wt, n)
  if (!facts) return done('failed', 'could not read branch facts')
  Object.assign(rec, { branch: facts.branch, head: facts.head })
  if (!facts.paths.length) return done('failed', 'implementer reported READY with no commits ahead of origin/main')
  const docsOnly = facts.paths.every(isDocs)

  // 4. Pre-PR review + address.
  if (!docsOnly) {
    const lenses = reviewersFor(facts.paths)
    const first = await review(n, wt, facts, [], lenses)
    const dead = lenses.filter(l => !first[l])
    if (dead.length) return done('escalated', `pre-PR ${dead.join(', ')} died — not opening an unreviewed PR`)
    rec.verdicts = Object.fromEntries(lenses.map(l => [l, first[l].verdict]))
    rec.followups = uniqueFollowups(lenses.flatMap(l => first[l].followups || []))
    let found = number(lenses.flatMap(l => tag(first[l].findings, l)), 0)
    rec.findings.push(...found)
    for (let pass = 1; found.length && pass <= 2; pass++) {
      const addr = await address(n, wt, facts.branch, found, pass)
      if (!addr) return done('escalated', 'address agent died')
      rec.fixed.push(...addr.fixed)
      rec.declined.push(...addr.declined.map(d => ({ ...d, finding: (found.find(f => f.id === d.id) || {}).problem })))
      if (!addr.suites_green) return done('escalated', 'suites red after addressing the pre-PR review')
      const fixedMust = found.filter(f => f.severity === 'must-fix' && addr.fixed.includes(f.id))
      if (!fixedMust.length || pass === 2) break
      // One re-review after a fixed must-fix: the reviewer always (the fix may have moved the spec), plus each
      // specialist lens whose own must-fix was fixed, to confirm the fix holds. The refactorer is never re-run: code-health fixes rarely regress.
      const again = ['reviewer', ...new Set(fixedMust.map(f => f.source).filter(l => l !== 'reviewer' && l !== 'refactorer'))]
      const re = await review(n, wt, facts, rec.declined, again, true)
      const alive = again.filter(l => re[l])
      if (!alive.length) break
      found = number(alive.flatMap(l => tag(re[l].findings, l)), rec.findings.length)
      rec.findings.push(...found)
    }
    // The address pass may have committed: the head the PR opens on is git's, not the first read's.
    const after = await branchFacts(wt, n, 'after address')
    if (!after) return done('failed', 'could not re-read branch facts after the address pass')
    facts = after
    Object.assign(rec, { head: facts.head })
  }

  // 5. Open the PR. The summary lives OUTSIDE the repo: any file in the worktree would make it dirty.
  const summaryName = `ship-ticket-summary-${n}-${facts.head}.md`
  const open = await runWithFile(wt, summaryName, impl.summary,
    `bin/pr-open ${n} --summary-file "<that dir>/${summaryName}"`,
    'Open PR', `pr-open #${n}`)
  if (!open) return done('failed', 'pr-open runner died')
  if (open.exit_code !== 0 || !open.json.pr) return done('failed', `pr-open: ${open.json.reason || 'exit ' + open.exit_code}`, { message: open.json.message || null })
  Object.assign(rec, { pr: open.json.pr, url: open.json.url })

  // 6. Drive to clean: the script waits and classifies; fix agents do one pass each.
  let fixes = 0, pending = 0, toolErrs = 0, waits = 0, lastHead = null
  for (;;) {
    const w = await runScript(`bin/pr-wait ${rec.pr} --timeout 540`, wt, 'Drive', `pr-wait #${rec.pr} (wait ${++waits}${ATTEMPT})`)
    if (!w) return done('failed', 'pr-wait runner died')
    const s = w.json || {}
    if (s.pr !== undefined && s.pr !== rec.pr) return done('failed', `pr-wait answered for PR ${s.pr}, not ${rec.pr}`)
    if (s.head && s.head !== lastHead) { lastHead = s.head; pending = 0 }

    if (w.exit_code === 4) { if (++pending > MAX_PENDING) return done('escalated', 'still pending after repeated waits', { reasons: s.reasons || [] }); continue }
    if (w.exit_code === 3) { if (++toolErrs > MAX_TOOL_RETRIES) return done('failed', `pr-wait tool failure: ${w.stderr_tail || s.message || ''}`); continue }
    if (w.exit_code !== 0 && w.exit_code !== 1) return done('failed', `pr-wait exit ${w.exit_code}: ${w.stderr_tail || ''}`)
    toolErrs = 0

    // One copy of each Action verdict (a head's verdict is the same on every wait): the merge-ready one lands here too.
    if (s.review_verdict && !rec.action_verdicts.some(v => v.sha === s.review_verdict.sha)) rec.action_verdicts.push(s.review_verdict)
    if (w.exit_code === 0 && s.merge_ready) return done('merge-ready', null, { final_head: s.head })
    if (w.exit_code === 0 && (s.state === 'merged' || s.state === 'closed')) return done(s.state)
    if (w.exit_code === 0 && s.review === 'not_run') return done('escalated', 'the review Action did not post a verdict for the head (skipped, timed out or out of turns)', { reasons: s.reasons || [] })
    if (w.exit_code === 0 && (s.missing_workflows || []).length) return done('escalated', `expected workflow(s) never ran: ${s.missing_workflows.join(', ')}`, { reasons: s.reasons || [] })

    if (fixes >= MAX_FIXES) return done('escalated', `not merge-ready after ${MAX_FIXES} fix passes`, { reasons: s.reasons || [] })
    fixes++
    const f = await fix(n, rec.pr, wt, s, w.exit_code === 1 || s.state === 'needs_rebase', fixes)
    rec.rounds.push({ state: s.state, reasons: s.reasons || [], review: s.review || null, threads: s.unresolved_threads, fix: f ? { pushed: f.pushed, summary: f.summary } : null })
    if (!f) return done('escalated', 'fix agent died')
    if (f.declined) rec.declined.push(...f.declined)
    if (!f.pushed) return done('escalated', 'the fix pass pushed nothing (findings declined or nothing it could change) — awaiting the maintainer', { reasons: s.reasons || [] })
  }
}

// ---------------------------------------------------------------------------

// The durable form of a run record: no agent prose beyond a short rationale, no worktree paths.
// Whatever bin/findings-retro (and bin/after-merge) read later is in here; each finding keeps a one-line problem
// and its category, while the full problem and fix text live only in the workflow's own result.
function durable(rec) {
  const clip = t => (t == null ? t : String(t).slice(0, 400))
  const declinedIds = new Set(rec.declined.map(d => d.id).filter(id => id !== undefined))
  const { worktree, message, question, ...rest } = rec
  return {
    ...rest,
    findings: rec.findings.map(f => ({
      id: f.id, source: f.source, severity: f.severity, where: f.where,
      category: categorySlug(f.category), problem: oneLine(f.problem, 240),
      outcome: rec.fixed.includes(f.id) ? 'fixed' : declinedIds.has(f.id) ? 'declined' : 'open',
    })),
    declined: rec.declined.map(d => ({ ...d, finding: clip(d.finding), rationale: clip(d.rationale) })),
    // Kept whole: bin/after-merge --followups files exactly these, so the bodies must outlive the run.
    followups: rec.followups,
    // Fix summaries clipped.
    rounds: rec.rounds.map(r => ({ ...r, fix: r.fix ? { pushed: r.fix.pushed, summary: clip(r.fix.summary) } : null })),
  }
}

// Post the record as the PR's hidden run-record comment (bin/pr-record). A failure here must not
// lose the ticket's outcome, which is also the workflow's return value: it is logged and moves on.
async function persist(rec) {
  const name = `ship-ticket-record-${rec.issue}-${rec.pr}.json`
  const r = await runWithFile(rec.worktree, name, JSON.stringify(durable(rec)),
    `bin/pr-record ${rec.pr} --file "<that dir>/${name}"`, 'Drive', `run record #${rec.pr}`)
  if (!r || r.exit_code !== 0) log(`#${rec.issue}: run record NOT persisted on PR ${rec.pr} (${(r && (r.json.reason || r.stderr_tail)) || 'runner died'})`)
  else rec.record_comment = r.json.comment_id
}

function underWorktrees(p) { return typeof p === 'string' && p.replace(/\/+$/, '').startsWith(WORKTREES) }
function tag(fs, source) { return (fs || []).map(f => ({ ...f, source })) }
function number(fs, from) { return fs.map((f, i) => ({ id: from + i, ...f })) }

async function branchFacts(wt, n, when) {
  const r = await runScript(
    `git rev-parse --abbrev-ref HEAD && git rev-parse HEAD && git fetch -q origin main && git diff --name-only origin/main...HEAD`,
    wt, 'Review', when ? `branch facts #${n} (${when})` : `branch facts #${n}`, { lines: true })
  if (!r || r.exit_code !== 0 || !r.stdout_lines || r.stdout_lines.length < 2) return null
  const [branch, head, ...paths] = r.stdout_lines.map(l => l.trim()).filter(Boolean)
  return { branch, head, paths }
}

function implement(n, branch, answer, attempt) {
  return agent(
    `THIS IS A FRESH IMPLEMENTATION of ${REPO}#${n} (attempt ${attempt}). Read the issue and its comments.\n\n` +
    `Your branch is \`${branch}\`. Create it in your OWN harness worktree with plain single commands (the sandbox refuses compound ones): ` +
    `\`git fetch origin main\`, then \`git checkout --no-track -b ${branch} FETCH_HEAD\`. ` +
    `Confirm \`git rev-parse --show-toplevel\` is under ${WORKTREES} and is not ${MAIN}; if not, stop and report BLOCKED.\n\n` +
    `Implement per your definition and commit. Then STOP at READY: do not push, open a PR, or ask for a review — this workflow runs the review, opens the PR and drives it.` +
    (answer ? `\n\nAn earlier attempt was BLOCKED; the maintainer's answer: ${answer}` : ''),
    { phase: 'Implement', label: `implement #${n} (attempt ${attempt})`, agentType: 'implementer', isolation: 'worktree', schema: IMPLEMENTED })
}

function continueInWorktree(n, wt, branch, question, answer) {
  return agent(
    `THIS IS A CONTINUATION of ${REPO}#${n} on branch \`${branch}\`. ${IN_WORKTREE(wt)}\n\n` +
    `The implementer stopped BLOCKED asking: ${question}\nThe maintainer's answer: ${answer}\n\n` +
    `Read .claude/agents/implementer.md and the issue, finish the implementation that way, commit, and stop at READY (no push, no PR).`,
    { phase: 'Implement', label: `continue #${n}`, schema: IMPLEMENTED, model: 'sonnet' })
}

// The named lenses in parallel; resolves to {lens: result}, a lens that died mapping to a falsy result.
async function review(n, wt, facts, declined, lenses, again) {
  const ctx = `${REPO}#${n}: worktree ${wt}, branch ${facts.branch}, head ${facts.head}; diff against \`git merge-base origin/main HEAD\`. Read-only. Return structured output.` +
    (declined.length ? `\n\nAlready DECLINED with these rationales — re-raise one only if its rationale does not hold:\n${JSON.stringify(declined, null, 1)}` : '')
  const results = await parallel(lenses.map(l => () => agent(LENSES[l](ctx),
    { phase: 'Review', label: `${l} #${n}${again ? ' (re-review)' : ''}`, agentType: l, schema: FINDINGS })))
  return Object.fromEntries(lenses.map((l, i) => [l, results[i]]))
}

function address(n, wt, branch, findings, pass) {
  return agent(
    `${IN_WORKTREE(wt)} Branch \`${branch}\`, ${REPO}#${n}.\n\n` +
    `Fix or decline-with-rationale EACH finding below (house rule: fix even nits; decline only with a real reason). ` +
    `Each carries the \`source\` lens that raised it; two lenses may flag one defect, and one fix settles both (list both ids as fixed). ` +
    `Append each decline, with its rationale, to ${wt}/.pr-declined-${n}.md. Re-run the gates: ${GATES}; for bin/ changes, the touched bin/*.test.sh one at a time. Commit; do not push.\n\n` +
    `Report finding ids in fixed / declined, and whether the suites ended green.\n\nFINDINGS:\n${JSON.stringify(findings, null, 1)}`,
    { phase: 'Address', label: `address #${n} (pass ${pass})`, schema: ADDRESSED, model: 'sonnet' })
}

function fix(n, pr, wt, s, rebase, k) {
  const task = rebase
    ? `The PR needs a rebase. \`git fetch origin\`, \`git rebase origin/main\`, resolve conflicts, re-run the gates the conflicts touched (${GATES}), then push with \`bin/pr-open ${n} --force-with-lease\`.`
    : `pr-wait says the PR is not merge-ready:\n${JSON.stringify({ reasons: s.reasons, checks: s.checks, review: s.review, review_verdict: s.review_verdict, unresolved_threads: s.unresolved_threads }, null, 1)}\n\n` +
      `ONE pass only. Failing checks: read the logs (\`gh run view <id> --log-failed\`) and fix. Review findings: the review Action's inline comments and its tracking comment on PR #${pr}; \`bin/pr-threads ${pr}\` lists threads. ` +
      `Fix or decline each (declines: append to ${wt}/.pr-declined-${n}.md and reply in the thread), resolve threads with \`bin/pr-threads ${pr} --resolve <id> [--reply <text>]\`. ` +
      `Re-run the gates you touched (${GATES}). Commit and push with \`bin/pr-open ${n}\` (it pushes and refreshes the body). If you changed nothing, do not push. Never edit the PR body by hand.`
  return agent(`${IN_WORKTREE(wt)} PR #${pr} for ${REPO}#${n}, fix pass ${k}${ATTEMPT}.\n\n${task}\n\nReport whether you pushed a new commit.`,
    { phase: 'Drive', label: `fix #${pr} (pass ${k}${ATTEMPT})`, schema: FIXED, model: 'sonnet' })
}
