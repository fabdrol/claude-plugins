# Concept: Hybrid Claude Code Agent Infrastructure

> This is the original concept behind the plugins in this repository, published
> so users can follow the thinking. `tender` implements the "cheap I/O layer"
> that fell out of it: before building a worker service, offload the file
> reading and boilerplate generation that burns most premium-model tokens.
> The later phases (worker service, usage-aware routing) are future plugins.
> Design details for tender live in `docs/superpowers/specs/`.

**Status:** Concept / implementation plan  
**Objective:** Preserve Claude Code + Fable 5.1 as the high-intelligence orchestration layer while offloading suitable execution work to dramatically cheaper open-weight models.

---

## 1. Background

My current development workflow relies heavily on Claude Code.

I typically run **4–6 concurrent Claude Code sessions**, each operating in a different codebase. These sessions run remotely on a Mac mini, allowing development work to continue when my MacBook is closed or when I switch to my phone.

Claude Code is allowed to work autonomously and can spawn multiple subagents as required.

The primary models are:

- **Fable 5.1**
- **Opus 5** for selected tasks

My personal Anthropic account is on **Max 20× (€180/month)**.

The Max subscription provides substantially more included Claude usage than purchasing the equivalent tokens through the API. Consequently, replacing subscription-backed Fable with Fable through OpenRouter or another pay-per-token API would be economically counterproductive.

Until recently, the Max allowance was generally sufficient for a full week because Anthropic temporarily provided approximately 50% higher limits. Following the end of that promotion, my current workload can exhaust the allowance approximately halfway through the week.

Claude then switches to usage-based billing, at which point costs can increase rapidly.

The wider development team separately uses an Anthropic Team plan at approximately:

|Cost|Monthly|
|---|---|
|Team subscriptions|~€770|
|Team usage-based charges|~€1,000–1,200|
|Personal Max subscription|€180|
|Personal usage overages|Variable|
|**Typical combined AI spend**|**~€3,500/month**|

The goal is **not primarily to reduce the €3,500**.

The more important goal is:

> **Remove AI inference as a constraint on how much autonomous development work can be performed.**

Ideally, I should be able to continue running many concurrent coding agents throughout the week without either exhausting Fable allowances or generating disproportionate API bills.

---

# 2. Core Idea

Do not replace Claude Code.

Do not replace Fable.

Instead, separate **reasoning/orchestration** from **execution**.

Use:

> **Fable 5.1 as the lead engineer / architect / planner / reviewer**

and use much cheaper models for delegated implementation work.

Conceptually:

```
                     Fable 5.1
                Claude Code / Max
                       │
              architect / planner
                       │
             classify/decompose work
                       │
          ┌────────────┼────────────┐
          │            │            │
          ▼            ▼            ▼
      DeepSeek        GLM          GLM
       worker         worker       worker
          │            │            │
          └────────────┼────────────┘
                       │
                implementation
                tests / commits
                       │
                       ▼
                     Fable
                review / integrate
```

The expensive frontier model is therefore concentrated on tasks where its intelligence has the greatest marginal value.

Cheap models perform the bulk of mechanical and well-specified execution.

---

# 3. Critical Constraint

The Fable orchestrator must continue using the **Anthropic Max subscription**.

It must therefore remain a normal Claude Code session authenticated against Anthropic.

It should **not** be routed through:

- OpenRouter
- LiteLLM
- Anthropic API billing
- another inference provider

Otherwise the economic advantage of the €180/month Max subscription is lost.

The architecture must therefore maintain two completely separate inference paths:

```
PREMIUM PATH

Claude Code
    │
    ▼
Anthropic account
    │
    ▼
Max subscription allowance
    │
    ▼
Fable 5.1 / Opus 5
```

and:

```
WORKER PATH

Spawned Claude Code
    │
    ▼
alternative API environment
    │
    ▼
OpenRouter
    │
    ├── DeepSeek
    ├── GLM
    └── other open-weight models
```

The two systems coexist on the same Mac mini.

---

# 4. Why Claude Code Should Also Be the Worker Harness

A delegated worker should **not** simply be an LLM API call.

For example, this is insufficient:

```
Fable
  │
  ▼
"Implement feature X"
  │
  ▼
GLM API
  │
  ▼
text response
```

A coding worker needs to operate as an actual coding agent.

It must be able to:

- inspect the repository;
- search files;
- read existing code;
- edit files;
- execute shell commands;
- run tests;
- inspect failures;
- iterate;
- inspect Git history;
- understand `CLAUDE.md`;
- use existing project configuration;
- potentially access MCP tools;
- return a completed implementation.

Instead of building another coding harness, **reuse Claude Code itself**.

A worker therefore becomes another Claude Code process:

```
Fable
  │
  │ delegate task
  ▼
worker launcher
  │
  ▼
claude -p
  │
  ├── same Claude Code binary
  ├── same repository
  ├── same CLAUDE.md
  ├── same .claude configuration
  ├── same user configuration
  ├── same tools
  └── DIFFERENT MODEL PROVIDER
          │
          ▼
      OpenRouter
          │
          ▼
       GLM / DeepSeek
```

This creates a much fairer comparison between models.

We are comparing:

> Fable + Claude Code

against:

> GLM + Claude Code

rather than:

> Fable + Claude Code

against:

> GLM + an entirely different agent framework.

---

# 5. Environment Isolation

The parent Claude Code process continues to use normal Anthropic authentication.

The worker process receives different environment variables.

Conceptually:

```
ANTHROPIC_BASE_URL="https://openrouter.ai/..." \
ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY" \
ANTHROPIC_API_KEY="" \
claude -p \
    --model "<worker-model>" \
    "<delegated task>"
```

These environment variables exist only for the child process.

Therefore:

```
Parent process
──────────────
Provider: Anthropic
Authentication: Max account
Model: Fable 5.1
Billing: subscription allowance


Child process
─────────────
Provider: OpenRouter
Authentication: API key
Model: GLM / DeepSeek
Billing: pay per token
```

The parent's environment and authentication remain untouched.

---

# 6. Delegation Interface

Fable needs an explicit mechanism for spawning external workers.

The preferred architecture is a small **delegation MCP service/tool** exposed to Claude Code.

For example:

```
delegate_fast()
delegate_standard()
delegate_parallel()
```

Fable sees these as tools in exactly the same way it sees other tools.

A conceptual call might look like:

```
delegate_standard(
    task="Implement notification preferences for saved searches",
    working_directory="/repos/superyachtiq",
    context="Follow the architecture described above...",
    acceptance_criteria=[
        "...",
        "...",
        "..."
    ]
)
```

The delegation service then:

1. selects the appropriate worker model;
2. prepares an isolated workspace;
3. starts a Claude Code worker;
4. provides the task;
5. monitors execution;
6. records usage and cost;
7. waits for completion;
8. returns the result to Fable.

---

# 7. Intelligence Levels

Fable should explicitly classify work before deciding whether to perform it itself.

A simple initial classification:

|Level|Description|Example|Default executor|
|---|---|---|---|
|**0 — Mechanical**|Little reasoning required|Search, tests, lint, docs|DeepSeek|
|**1 — Normal**|Well-defined coding|API endpoint, component, migration|GLM|
|**2 — Difficult**|Significant reasoning|Multi-file refactor, difficult bug|GLM first / Fable|
|**3 — Critical**|High ambiguity or consequence|Architecture, security, complex production issue|Fable|

These rules should live in the relevant `CLAUDE.md`.

Example:

```
## Delegation policy

You are the lead engineer and technical decision maker.

Preserve premium-model capacity by aggressively delegating
well-defined execution work.

Before performing substantial work, classify independent work
units from 0–3.

### Level 0 — Mechanical

Delegate to `delegate_fast`.

Examples:

- repository exploration
- locating references
- straightforward tests
- documentation
- lint errors
- type errors
- repetitive refactoring
- mechanical migrations

### Level 1 — Normal implementation

Delegate to `delegate_standard`.

Examples:

- API endpoints
- frontend components
- isolated bug fixes
- migrations
- normal test implementation
- well-defined features

### Level 2 — Difficult

Attempt `delegate_standard` once where the problem can be
specified clearly.

Review the result carefully.

Take over directly if the worker fails or misunderstands the task.

### Level 3 — Critical

Handle yourself.

Examples:

- architectural decisions
- ambiguous requirements
- security-sensitive changes
- difficult production debugging
- work requiring significant product judgement

### Complex tasks

For complex work:

1. Understand the problem.
2. Design the solution.
3. Break implementation into independent tasks.
4. Delegate appropriate tasks in parallel.
5. Review all worker results.
6. Integrate the work.
7. Correct failures.
8. Perform final validation.
```

---

# 8. Git Isolation

Multiple autonomous agents should not generally modify the same checkout simultaneously.

Each delegated implementation should therefore receive its own **Git worktree**.

Example:

```
main repository
      │
      ├── worktree/task-a → GLM worker
      │
      ├── worktree/task-b → GLM worker
      │
      └── worktree/task-c → DeepSeek worker
```

The delegation service can automatically create:

```
git worktree add \
    /tmp/agents/task-123 \
    -b agent/task-123
```

The worker then runs inside:

```
/tmp/agents/task-123
```

It can:

```
read
edit
test
iterate
commit
```

without interfering with either the main Fable session or another worker.

On completion it returns something equivalent to:

```
{
  "status": "completed",
  "branch": "agent/task-123",
  "commit": "84b71e2",
  "tests_passed": true,
  "summary": "Implemented notification preferences..."
}
```

Fable can then inspect:

```
git show 84b71e2
```

before accepting or integrating the change.

---

# 9. Worker Permissions

Workers should **not automatically inherit unlimited permissions**.

The parent Fable session is interactive and can make higher-risk decisions.

Cheap autonomous workers should operate inside a narrower sandbox.

Suitable permissions might include:

```
ALLOW

Read
Glob
Grep
Edit
Write

git status
git diff
git log

npm test
npm run lint
npx tsc
bundle exec rspec
rails test
etc.
```

Potentially prohibit:

```
DENY

git push
git reset --hard
git clean
production deployments
production database access
infrastructure changes
credential access
destructive filesystem operations
```

The precise policy can be adjusted after experience with the workers.

---

# 10. Worker Subagents

Initially, workers should **not themselves aggressively spawn further workers**.

Desired topology:

```
                 Fable
             /     |     \
           GLM    GLM   DeepSeek
```

rather than:

```
                    Fable
                  /       \
                GLM       GLM
              / | \       / | \
            DS DS DS    DS DS DS
```

The latter makes:

- concurrency unpredictable;
- costs harder to control;
- failures harder to understand;
- benchmarks less meaningful.

Fable should initially remain the sole orchestration layer.

Nested delegation can be explored later.

---

# 11. Model Strategy

The initial candidates are:

### DeepSeek V4.1 Flash

Use primarily for inexpensive, high-volume work:

- repository exploration;
- mechanical changes;
- tests;
- documentation;
- simple bugs;
- lint/type errors;
- straightforward refactoring.

Its primary attraction is extremely low inference cost.

### GLM 5.3

Use as the initial **general-purpose external coding worker**.

Suitable for:

- features;
- normal bugs;
- backend implementation;
- frontend implementation;
- migrations;
- moderate refactors;
- well-specified multi-file work.

This is likely the most important model to benchmark against Fable.

### Fable 5.1

Remain the principal:

- planner;
- architect;
- orchestrator;
- reviewer;
- difficult debugger;
- integrator.

Consume from the Max subscription wherever possible.

### Opus 5

Use selectively where appropriate for:

- difficult reasoning;
- second opinions;
- particularly complex reviews;
- tasks where Fable is not producing satisfactory results.

---

# 12. OpenRouter vs LiteLLM

These solve different problems.

## OpenRouter

OpenRouter provides the actual hosted inference.

Initially:

```
Claude Code worker
        │
        ▼
    OpenRouter
        │
   ┌────┴────┐
   ▼         ▼
DeepSeek    GLM
```

Advantages:

- no GPUs to manage;
- pay only for actual inference;
- easy model experimentation;
- one API account;
- multiple inference providers;
- easy switching between models.

### Phase 1 should use OpenRouter directly.

There is no reason to introduce infrastructure before proving that the models work reliably as Claude Code workers.

---

# 13. LiteLLM

LiteLLM becomes the **internal inference control plane** once the concept is proven.

Architecture:

```
Claude Code workers
         │
         ▼
      LiteLLM
         │
         ▼
     OpenRouter
      /      \
DeepSeek     GLM
```

Claude Code workers then use internal model aliases:

```
aqua-fast
aqua-code
aqua-code-max
```

instead of provider-specific names.

For example:

```
aqua-fast
    ↓
DeepSeek V4.1 Flash

aqua-code
    ↓
GLM 5.3

aqua-code-max
    ↓
best current high-quality open-weight model
```

This allows the underlying models to change without modifying the delegation system.

LiteLLM also provides useful central controls:

- spend tracking;
- budgets;
- virtual API keys;
- rate limits;
- retries;
- fallbacks;
- provider routing;
- model aliases;
- per-user accounting;
- per-project accounting.

---

# 14. Long-Term Provider Independence

Eventually:

```
                        LiteLLM
                           │
             ┌─────────────┼──────────────┐
             │             │              │
             ▼             ▼              ▼
        OpenRouter     direct APIs      local GPU
             │
       ┌─────┼─────┐
       ▼     ▼     ▼
      GLM    DS   future
```

For example, if GLM becomes heavily used, it may become cheaper to switch:

```
OpenRouter → GLM
```

to:

```
Z.ai direct → GLM
```

without changing Claude Code.

Likewise, future local hardware could replace a hosted model:

```
aqua-fast
   │
   ▼
OpenRouter / DeepSeek
```

becomes:

```
aqua-fast
   │
   ▼
M5 Ultra / local DeepSeek
```

The developer workflow remains unchanged.

---

# 15. Cost Visibility

A major requirement is better cost visibility.

The current Anthropic billing model makes it easy for agentic usage to produce unexpectedly large charges.

The worker system should record at least:

```
timestamp
developer
repository
parent Claude session
worker
model
provider
task
input tokens
cached tokens
output tokens
duration
API cost
result
```

This should eventually make it possible to see:

```
TODAY

DeepSeek                 €8.41
GLM                     €23.17
─────────────────────────────
External workers         €31.58


BY REPOSITORY

SuperYacht iQ            €14.21
SuperYacht Times          €8.62
Internal                  €5.59
Other                     €3.16
```

More importantly, we should eventually measure:

> **cost per successfully completed coding task**

rather than merely token cost.

---

# 16. Success Metrics

Raw benchmark performance is not sufficient.

The experiment should measure actual development performance.

For each model:

|Metric|Fable|GLM|DeepSeek|
|---|---|---|---|
|Tasks attempted||||
|Completed autonomously||||
|Human intervention required||||
|Fable rescue required||||
|Tests passing||||
|Average wall-clock time||||
|Token cost||||
|Cost per successful task||||

Additional useful metric:

```
successful autonomous tasks
───────────────────────────
             €
```

The objective is not necessarily to find the cheapest model.

It is to maximise:

> **useful autonomous engineering output per euro.**

---

# 17. Important Hypothesis to Test

A cheap model being 20–40× cheaper per token is irrelevant if:

- it fails repeatedly;
- produces poor code;
- requires substantial Fable repair;
- takes many retries;
- introduces regressions.

Conversely, it does **not** need to match Fable's intelligence.

If a worker costs 20× less and successfully completes 70–80% of appropriately selected work, it may have exceptional economic value.

Fable can handle the remaining difficult work.

---

# 18. Phase 1 — Minimal Proof of Concept

Do **not** start with LiteLLM.

Do **not** build automatic routing.

Do **not** roll this out to the development team.

Start with one Mac mini and one user.

Build:

```
Fable Claude Code
      │
      ▼
delegate_standard
      │
      ▼
spawn claude -p
      │
      ▼
OpenRouter
      │
      ▼
GLM
```

Then add:

```
delegate_fast
      │
      ▼
DeepSeek
```

The purpose of Phase 1 is simply to answer:

> **Can GLM and/or DeepSeek operate reliably as Claude Code coding agents?**

---

# 19. Phase 2 — Real-World Personal Trial

Run the system for approximately one week.

Maintain the existing working style:

- 4–6 concurrent repositories;
- multiple long-running tasks;
- normal development work;
- normal level of autonomy;
- no artificial benchmark tasks.

Use Fable normally, but delegate suitable work.

Measure:

```
Fable-only tasks
GLM delegated tasks
DeepSeek delegated tasks
```

Track successes, failures, cost and required intervention.

The key question becomes:

> **Does delegation extend useful Fable capacity across the entire week without materially reducing development velocity or quality?**

---

# 20. Phase 3 — Introduce LiteLLM

If Phase 2 succeeds, introduce LiteLLM:

```
Fable
  │
  ▼
delegation MCP
  │
  ▼
Claude Code worker
  │
  ▼
LiteLLM
  │
  ▼
OpenRouter
```

Add:

- `aqua-fast`;
- `aqua-code`;
- `aqua-code-max`;
- central usage logging;
- budgets;
- per-model accounting;
- retries;
- provider fallback.

At this stage, model selection becomes infrastructure rather than individual configuration.

---

# 21. Phase 4 — Smarter Delegation

Once sufficient task data exists, refine the delegation policy.

Potential routing:

```
Task
 │
 ▼
Fable classifies complexity
 │
 ├── Level 0
 │      ↓
 │   DeepSeek
 │
 ├── Level 1
 │      ↓
 │     GLM
 │
 ├── Level 2
 │      ↓
 │   GLM attempt
 │      │
 │      └── failure → Fable
 │
 └── Level 3
        ↓
      Fable
```

The routing policy should be based on **actual observed task success**, not generic model benchmarks.

---

# 22. Phase 5 — Development Team Rollout (out of scope for now)

Only after the personal experiment demonstrates a clear benefit should the architecture be offered to the wider development team.

At that stage:

```
                    Developers
                        │
                 Claude Code
                        │
               Anthropic plans
                        │
                   Fable/Opus
                        │
                delegation tools
                        │
                        ▼
                  Worker service
                        │
                    LiteLLM
                        │
             ┌──────────┼──────────┐
             ▼          ▼          ▼
         DeepSeek      GLM       future
```

Each developer could receive an internal worker budget.

Example:

```
Fabian           €50/day
Developer A      €10/day
Developer B      €10/day
Developer C      €10/day
```

Limits can initially be generous because open-weight inference is inexpensive compared with Fable/Opus API usage.

---

# 23. What We Are Explicitly Not Doing

At this stage:

**No H200 cluster.**

The economics do not currently justify renting an 8× H200 system given total organisational AI expenditure of roughly €3,500/month.

**No M5 Ultra cluster.**

Interesting later, but hosted inference should first establish actual demand and model suitability.

**No replacement for Claude Code.**

Claude Code remains the coding-agent harness.

**No replacement for Fable.**

Fable remains the premium intelligence layer.

**No proxying Fable through OpenRouter.**

Doing so would discard the economic advantage of the Max subscription.

**No automatic multi-level recursive agent swarm initially.**

Keep Fable as the sole orchestrator until the behaviour and economics are understood.

---

# 24. Target Architecture

The eventual system is:

```
                              Mac mini
                                  │
                 ┌────────────────┼────────────────┐
                 │                │                │
                 ▼                ▼                ▼
           Claude Code       Claude Code      Claude Code
             Fable             Fable            Fable
              Max               Max              Max
                 │                │                │
                 └────────┬───────┴────────┬───────┘
                          │                │
                    delegate()        delegate()
                          │                │
                          ▼                ▼
                    Delegation MCP / service
                              │
                     classify / launch
                              │
              ┌───────────────┼───────────────┐
              │                               │
              ▼                               ▼
        Git worktree A                  Git worktree B
              │                               │
              ▼                               ▼
         Claude Code                     Claude Code
          headless                        headless
              │                               │
          GLM worker                   DeepSeek worker
              │                               │
              └───────────────┬───────────────┘
                              │
                           LiteLLM
                              │
                         OpenRouter
                              │
                  ┌───────────┼───────────┐
                  ▼           ▼           ▼
                 GLM      DeepSeek      future
                              │
                              ▼
                    result / commit / cost
                              │
                              ▼
                            Fable
                      review / integrate
```

---

# 25. Desired Outcome

Today the limiting resource is effectively:

> **premium-model inference allowance.**

The proposed architecture changes that.

Fable becomes a scarce but highly capable **technical lead**, while inexpensive models provide a much larger pool of execution capacity.

Instead of:

```
Fable
 ├── think
 ├── search
 ├── read
 ├── implement
 ├── test
 ├── debug
 ├── spawn Fable
 ├── spawn Fable
 └── review
```

the desired workflow becomes:

```
Fable
 ├── understand
 ├── architect
 ├── plan
 │
 ├──── GLM → implementation
 ├──── GLM → implementation
 ├──── DeepSeek → tests
 ├──── DeepSeek → investigation
 │
 ├── review
 ├── correct
 └── integrate
```

The intended result is **not merely a lower AI bill**.

It is:

> **more autonomous software-engineering capacity for the same budget, while preserving Fable 5.1 for the work where frontier-model intelligence actually matters.**

The immediate next step is therefore deliberately small:

> **Build a single `delegate_standard` proof of concept that allows a Max-authenticated Fable Claude Code session to spawn a headless Claude Code worker running GLM through OpenRouter, give that worker an isolated Git worktree, and return its result to Fable.**

If that works reliably on real development tasks, the rest of the architecture can be introduced incrementally.

# Notes

- OpenRouter API key is available in the env as `OPENROUTER_API_KEY`. 