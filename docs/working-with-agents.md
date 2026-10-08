# Working with agents

Agents write most of Redlamp: its code, its tests and its documentation, directed by the owner and held to the checks in [AGENTS.md](../AGENTS.md). This document is for anyone who works on Redlamp with an agent. It sets out the bar every change meets, how agent work is billed, what it costs to develop Redlamp the way this document recommends, and the habits that keep it within a budget.

Redlamp's agent work is moving to fixed subscriptions, with no on-demand spending. Tokens are a budget: what a session wastes is work that doesn't get done that week.

## The bar

The standard doesn't depend on the tool, the model or the plan that produced a change. Every change:

- passes the push gate before it reaches `main`, and its scheme's full suite before it's called done;
- keeps the reference tests passing (golden renders, process references, recorded reports, the sidecar schema), and changes how an existing edit renders only in a new process version;
- lands with its regression scenario, worked through the user's own input path;
- follows the clean-room policy, and is documented in plain, complete sentences.

[AGENTS.md](../AGENTS.md) has the details, and the README's [Contributing](../README.md#contributing) section has the conventions. The checks run on the Mac and cost no tokens, so relying on them is free. They are what keeps the standard when the model or the budget changes.

## How agent work is billed

An agent works in steps, and each step is one model call that sends the whole conversation so far: the system prompt, the rules and skills, every message, every file it read and every tool result. The provider caches what it has already seen. On Claude Opus 5.5, reading the conversation back from the cache costs $0.20 per million tokens, writing new content to it costs $5, and output, including thinking, costs $20.

The cache usually lives five minutes. When an agent sits idle for longer, waiting for its owner, a build or the push gate, the cache expires and the next step writes the whole conversation again, at 25 times the price of reading it. So what a step costs depends mostly on how large the conversation is, and on whether the cache is still warm:

| Conversation size | A step with a warm cache | A step after the cache expired |
| --- | --- | --- |
| 50K tokens | $0.01 | $0.25 |
| 200K tokens | $0.04 | $1.00 |
| 700K tokens | $0.14 | $3.50 |

These are Opus 5.5's prices for sending the conversation; Sonnet 5.5 costs half. Each step also writes what's new (a few thousand tokens) and its output (several hundred), about $0.03 on Opus.

## What drives the cost

Redlamp's own agent sessions were measured in October 2026, before these habits, by rebuilding every model call from Cursor's local record of each conversation:

- **Expired caches were the largest cost:** 43% went on writing a conversation again after an idle wait, split evenly between waits for the owner between turns and waits on commands such as the push gate and the test suites.
- **Large conversations were most of the rest.** Reading conversations back from the cache took 38%. Calls with more than 300K tokens of context were a third of the calls and half of the cost, and chats left open for a day or more accounted for about 70%.
- **Output was 9%,** thinking included, and writing new content 10%.
- **Some things cost little.** A lower effort setting, with half the thinking, saves about 2%. Canvas edits came to well under 1%. Trimming the skills list, which loads with every call, from 30K tokens to 3K saves about 6%.

## What the habits save

The same sessions, replayed call by call under each change:

| Change | Saving |
| --- | --- |
| Main chats capped at 200K tokens | 38% |
| No idle cache expiries | 41% |
| Main chats capped at 200K tokens, subagents at 120K | 44% |
| Sonnet 5.5 for everything | 50% |
| Both caps, a trimmed skills list, half the expiries and lower effort, on Opus | 58% |
| The same, with Sonnet 5.5 subagents | 69% |

Smaller conversations are summarised more often, and each summary is a call of its own; the replay counts them. It doesn't model what a cheaper model would do differently, such as taking more steps.

## What it costs to work this way

Projected at list prices, for work like Redlamp's (commits on `main` and roadmap rows), following the habits below:

| Way of working | A commit | A roadmap row | A typical task | One task in ten costs more than |
| --- | --- | --- | --- | --- |
| Opus for everything | $3.20 | $33 | $11 | $75 |
| Opus main chats, Sonnet 5.5 subagents (recommended) | $2.40 | $25 | $10 | $66 |
| Sonnet 5.5 main chats, Composer 2.5 subagents | $1.30 | $14 | $5 | $35 |

A task is one main chat with its subagents. Commits and roadmap rows are averages: a row can be an afternoon's fix or a week's feature. On the recommended mix, a roadmap row a week comes to about $100 a month, and a row every working day to about $550. For comparison, Anthropic [reports](https://code.claude.com/docs/en/costs) an average of about $13 per developer per active day across enterprise deployments of Claude Code, most of it interactive use rather than agents working through whole tasks.

On a subscription, the same work counts against the plan's limits instead of a bill, so these figures show how much of a month's allowance a piece of work uses. Neither Anthropic nor Cursor publishes its plans' limits in tokens.

The projections replay real sessions, calibrated against the context sizes Cursor recorded for each conversation; treat them as accurate to about 15%.

## Habits

These apply to anyone directing agents on Redlamp. [AGENTS.md](../AGENTS.md#working-within-a-budget) has the ones an agent follows by itself.

1. **One task per chat.** Hand over through the tracker, the workstream canvas or the plan, not through a conversation that runs for days. Start a new chat when one passes about 200K tokens.
2. **Don't wait inside a large conversation.** Run the push gate and full suites in the background, and check on them at intervals under four minutes, or end the turn and pick up the result in a short new chat.
3. **Opus for the thinking:** plans, architecture, hard bugs and final reviews. Sonnet 5.5 or Composer 2.5 for implementation subagents and mechanical edits, kept where they meet the bar.
4. **Two or three agents at a time.** Audits and waves that ran six or more agents at once run one or two at a time.
5. **Small defaults:** a 300K context rather than 1M, and exploration subagents on a cheaper model.
6. **Nothing on demand:** extra usage off on Claude, on-demand usage off on Cursor, and no API key in the environment, so the worst case is waiting for a limit to reset.
7. **Keep what's cheap.** Canvases, including the [rooms](rooms.md) that releases, reports, the blog and press outreach are run from, the push gate and the tests cost little or nothing, and they carry the standard.

## Measuring

- **Claude Code:** `/usage` shows the session's tokens and cache misses and, on a subscription, what counts against the plan's limits, including long context and cache misses.
- **Cursor:** the dashboard's Usage page lists each request's tokens, and exports them as a CSV.

## Prices

Per million tokens, from [Cursor](https://cursor.com/docs/models-and-pricing) and [Anthropic](https://platform.claude.com/docs/en/about-claude/pricing) on 8 October 2026:

| Model | Input | Cache write | Cache read | Output |
| --- | --- | --- | --- | --- |
| Claude Opus 5.5 | $4 | $5 | $0.20 | $20 |
| Claude Sonnet 5.5 | $2 | $2.50 | $0.10 | $10 |
| Claude Haiku 5.5, prompts up to 100K tokens | $0.10 | $0.125 | $0.01 | $0.50 |
| Claude Opus 5 | $5 | $6.25 | $0.50 | $25 |
| Composer 2.5, in Cursor | $0.50 | – | $0.20 | $2.50 |

Cache writes are at the five-minute rate. For agents, the cache-read price matters most: about 95% of the tokens measured were cache reads. Prices change; the linked pages have the current ones.
