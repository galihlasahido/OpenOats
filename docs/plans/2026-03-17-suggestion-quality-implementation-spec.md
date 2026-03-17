# Suggestion Quality Improvement Implementation Spec

Improve the suggestion system so it stays quiet by default and only surfaces suggestions that are timely, grounded in the KB, and immediately useful in the flow of a live conversation.

## Goal

Shift the product behavior from:

- "Generate suggestions whenever the latest utterance matches the KB"

to:

- "Abstain unless there is a high-confidence, conversation-aware suggestion that is worth interrupting the user for"

## Primary Use Case

Two founders are discussing startup ideas in a loose, natural way. The KB may contain YC guidance, startup manuals, internal docs, or founder notes. Suggestions should only appear when the conversation reaches a moment where the KB can materially improve the user's next move.

Examples of high-value moments:

- The other person is making a decision
- The other person asks a question
- The conversation reveals a risk, assumption, or contradiction
- The other person is talking about customer, problem, wedge, distribution, prioritization, or validation

Examples of low-value moments:

- Small talk
- Half-finished thoughts
- Generic brainstorming with no clear angle
- Repeated discussion where the same advice was already surfaced

## Current Failure Modes

Current implementation problems:

- Suggestions trigger on every finalized `them` utterance in `ContentView.handleNewUtterance()`
- KB retrieval uses only the latest utterance text as the query
- The model sees only raw recent utterances, not a rolling summary of the conversation state
- The prompt asks for relevance to KB, but not whether surfacing is genuinely helpful right now
- Partial suggestion text is streamed into the UI before the app knows whether the final suggestion is worth showing

Relevant files:

- `OnTheSpot/Sources/OnTheSpot/Views/ContentView.swift`
- `OnTheSpot/Sources/OnTheSpot/Intelligence/SuggestionEngine.swift`
- `OnTheSpot/Sources/OnTheSpot/Intelligence/KnowledgeBase.swift`
- `OnTheSpot/Sources/OnTheSpot/Models/TranscriptStore.swift`
- `OnTheSpot/Sources/OnTheSpot/Views/SuggestionsView.swift`
- `OnTheSpot/Sources/OnTheSpot/Models/Models.swift`
- `OnTheSpot/Sources/OnTheSpot/Storage/SessionStore.swift`

## Product Principles

These rules should drive all implementation decisions:

1. Silence is correct unless there is a strong reason to interrupt.
2. A suggestion must help the user in the next one or two turns.
3. A suggestion must be grounded in retrieved KB evidence.
4. Conversation context matters more than the latest sentence.
5. One strong suggestion is better than four weak ones.
6. Repeated or obvious advice is noise.
7. The system must be inspectable: every surfaced suggestion should have traceable inputs and reasons.

## Non-Goals

- Do not build a generic brainstorming assistant.
- Do not optimize for always showing something.
- Do not add many user-facing tuning controls in the first pass.
- Do not require a second model provider or a separate backend.

## High-Level Architecture Changes

The new pipeline should be:

```text
TranscriptionEngine
  -> TranscriptStore
  -> ConversationState updater
  -> Trigger heuristic
  -> KB retrieval from conversation-aware query set
  -> Surfacing gate
  -> Suggestion generation
  -> UI commit
  -> Feedback + session logging
```

The most important change is to separate:

- "Should the app surface anything now?"

from:

- "What should it say?"

The first question is a gate. The second is generation. They should not be collapsed into one call.

## Data Model Additions

Add the following types, either in `Models.swift` or in a new `Intelligence/SuggestionModels.swift` file.

### `ConversationState`

Represents the running state of the meeting.

Suggested fields:

```swift
struct ConversationState: Sendable, Codable {
    var currentTopic: String
    var shortSummary: String
    var openQuestions: [String]
    var activeTensions: [String]
    var recentDecisions: [String]
    var themGoals: [String]
    var suggestedAnglesRecentlyShown: [String]
    var lastUpdatedAt: Date
}
```

Notes:

- Keep this compact. It is prompt context, not a transcript replacement.
- `shortSummary` should be 2-4 sentences max.
- `suggestedAnglesRecentlyShown` is for duplicate suppression.

### `SuggestionTrigger`

Represents why the current moment might be worth evaluating.

```swift
enum SuggestionTriggerKind: String, Codable, Sendable {
    case explicitQuestion
    case decisionPoint
    case disagreement
    case assumption
    case prioritization
    case customerProblem
    case distributionGoToMarket
    case productScope
    case unclear
}

struct SuggestionTrigger: Sendable, Codable {
    var kind: SuggestionTriggerKind
    var utteranceID: UUID
    var excerpt: String
    var confidence: Double
}
```

### `SuggestionEvidence`

Represents retrieved KB support.

```swift
struct SuggestionEvidence: Sendable, Codable {
    var sourceFile: String
    var headerContext: String
    var text: String
    var score: Double
}
```

### `SuggestionDecision`

Represents the output of the surfacing gate.

```swift
struct SuggestionDecision: Sendable, Codable {
    var shouldSurface: Bool
    var confidence: Double
    var relevanceScore: Double
    var helpfulnessScore: Double
    var timingScore: Double
    var noveltyScore: Double
    var reason: String
    var trigger: SuggestionTrigger?
}
```

### `SuggestionFeedback`

Optional in first pass, but model it now so logs have room for it.

```swift
enum SuggestionFeedback: String, Codable, Sendable {
    case helpful
    case notHelpful
    case dismissed
}
```

### Extend `Suggestion`

Add metadata to the existing `Suggestion` model.

Suggested fields:

```swift
struct Suggestion: Identifiable, Sendable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let kbHits: [KBResult]
    let decision: SuggestionDecision?
    let trigger: SuggestionTrigger?
    let summarySnapshot: String?
    let feedback: SuggestionFeedback?
}
```

The initial implementation can keep `feedback` nil until UI support is added.

## Retrieval Changes

## Step 1: Preserve richer KB metadata

Modify `KBResult` so it includes `headerContext`.

Current issue:

- `KBChunk` stores `headerContext`, but `KBResult` drops it.

Required changes:

- Add `headerContext` to `KBResult`
- Populate it in `KnowledgeBase.search()`
- Include it in suggestion prompts and UI evidence labels

## Step 2: Add chunk adjacency

Improve retrieval context by preserving chunk neighborhoods during indexing.

Suggested approach:

- Extend `KBChunk` with a stable chunk ID and neighboring chunk IDs or simple `previousIndex` / `nextIndex`
- When returning top hits, optionally expand each result with one adjacent chunk on each side
- Keep final evidence small; do not dump entire documents

This matters because section meaning is often split across adjacent chunks.

## Step 3: Use conversation-aware retrieval queries

Replace single-query retrieval with fused retrieval across multiple query strings.

Suggested query set:

1. Latest `them` utterance
2. `ConversationState.currentTopic`
3. `ConversationState.shortSummary`
4. Top open question, if any
5. Trigger-specific query, if detected

Example:

- Latest utterance: "Maybe we should build this for all small businesses"
- Current topic: "Who the initial customer should be"
- Open question: "Should the wedge be narrow or broad?"
- Trigger kind: `productScope`

The resulting fused query context is much better than the utterance alone.

Implementation options:

- Run multiple `KnowledgeBase.search()` calls and merge results
- Or add a new `search(queries: [String], topK: Int)` method with score fusion

Score fusion rules:

- Deduplicate by source chunk ID
- Use max score or weighted average
- Boost results that match both latest utterance and conversation summary

## Conversation State Changes

## Step 4: Add `ConversationState` to `TranscriptStore`

Modify `TranscriptStore` to own the rolling state.

Suggested API:

```swift
@Observable
@MainActor
final class TranscriptStore {
    private(set) var utterances: [Utterance] = []
    private(set) var conversationState = ConversationState(...)
    ...
}
```

The conversation state should update only on finalized utterances, not on volatile partials.

## Step 5: Update conversation state incrementally

Add a lightweight summarization path that runs only when needed.

Recommended cadence:

- On every finalized `them` utterance that passes a minimum length threshold
- But only recompute the summary every 2-3 finalized utterances, or when trigger heuristics detect a meaningful shift

This avoids excessive API calls while still keeping the state fresh.

Implementation guidance:

- Add a non-streaming completion method to `OpenRouterClient`, for example `complete(...) async throws -> String`
- Use the same selected model initially
- Ask for compact structured JSON, then decode it into `ConversationState`

Do not summarize the full transcript every time.

Use:

- previous conversation state
- last N utterances
- latest utterance

to produce the updated state.

## Step 6: Keep summary prompts tightly scoped

Summary prompt objective:

- capture the current meeting state, not write meeting notes

Rules:

- 2-4 sentence summary max
- prefer unresolved questions over historical detail
- prefer what "them" appears to want or optimize for
- output compact JSON only

Suggested output schema:

```json
{
  "currentTopic": "string",
  "shortSummary": "string",
  "openQuestions": ["string"],
  "activeTensions": ["string"],
  "recentDecisions": ["string"],
  "themGoals": ["string"]
}
```

If JSON decoding fails:

- log the failure
- keep the previous conversation state
- do not block the app

## Trigger Heuristics

## Step 7: Add a local heuristic pre-filter before any LLM gate

This should happen inside `SuggestionEngine` before retrieval or generation.

Heuristics should skip evaluation when:

- utterance length is too short
- utterance is mostly filler
- the previous suggestion was too recent
- the utterance is near-duplicate of a recent utterance
- the conversation appears mid-thought

Suggested initial rules:

- minimum utterance word count: 8
- minimum character count: 30
- cooldown after surfaced suggestion: 90 seconds
- duplicate suppression window: last 3 surfaced suggestion angles

Heuristics should create a `SuggestionTrigger?` when they detect a real moment.

Signals to detect:

- question mark or interrogative phrasing
- "should we", "what if", "I think", "the problem is", "maybe", "but", "however"
- domain phrases like customer, market, distribution, pricing, MVP, wedge, retention, churn

These should not directly surface a suggestion. They only justify entering retrieval + gate evaluation.

## Surfacing Gate

## Step 8: Split surfacing from generation

After retrieval, run a dedicated gate prompt that decides whether the app should show anything now.

Inputs:

- latest utterance
- recent 4-6 utterances
- `ConversationState`
- candidate KB evidence
- trigger, if any
- recently surfaced suggestion angles

Output:

`SuggestionDecision` JSON only.

Suggested decision rubric:

- `relevanceScore`: how strongly the evidence matches the actual topic
- `helpfulnessScore`: whether it would materially improve the user's next reply
- `timingScore`: whether now is the right moment to interrupt
- `noveltyScore`: whether this is not obvious or already surfaced
- `confidence`: overall confidence
- `shouldSurface`: true only when all dimensions clear threshold

Suggested initial thresholds:

- `relevanceScore >= 0.72`
- `helpfulnessScore >= 0.75`
- `timingScore >= 0.70`
- `noveltyScore >= 0.65`
- `confidence >= 0.75`

These numbers should be hardcoded first, then tuned with replay.

## Step 9: Gate prompt contract

The gate prompt should explicitly optimize for abstention.

Required instructions:

- stay silent unless the suggestion would be genuinely useful right now
- penalize generic advice
- penalize advice already obvious from the conversation
- penalize weak or tangential KB matches
- penalize interruptions during loose or unfinished ideation
- only approve if the user could plausibly use the suggestion in the next one or two turns

Gate output schema:

```json
{
  "shouldSurface": true,
  "confidence": 0.84,
  "relevanceScore": 0.88,
  "helpfulnessScore": 0.82,
  "timingScore": 0.79,
  "noveltyScore": 0.73,
  "reason": "The conversation is at a concrete customer-segmentation decision point and the KB evidence offers a specific wedge-narrowing principle not already stated.",
  "trigger": {
    "kind": "productScope",
    "excerpt": "Maybe we should just build this for all small businesses",
    "confidence": 0.78
  }
}
```

If the gate says `shouldSurface = false`, stop immediately. Do not stream anything to the UI.

## Suggestion Generation

## Step 10: Generate only after the gate approves

Only run suggestion generation when the gate passes.

Inputs:

- latest utterance
- `ConversationState`
- `SuggestionDecision.reason`
- top 2-3 evidence chunks

The generator should produce one suggestion, not a list.

Required output shape:

- short headline
- one concise coaching line the user can use
- optional evidence line or source label

The final user-facing suggestion should be immediately usable in live conversation.

Example:

- Headline: `Narrow the wedge`
- Coaching line: `Ask which specific customer has the sharpest pain right now instead of broadening to all SMBs.`
- Evidence line: `YC advice: early startups usually win by dominating a narrow use case first.`

## Step 11: Make suggestion generation grounded and terse

Update the prompt in `SuggestionEngine.buildMessages(...)` or replace it with a new dedicated prompt builder.

Rules:

- one suggestion max
- no generic startup advice
- no multi-bullet lists
- no filler or hedging
- tie the suggestion to a concrete moment in the conversation
- ground it in the retrieved evidence
- prefer a suggested question, reframing, or caution the user can use immediately

Abstention is already handled by the gate, so generator prompt can assume the moment is valid.

## UI Changes

## Step 12: Remove live partial suggestion streaming for uncommitted suggestions

Current behavior shows partial LLM output as it streams. This is noisy.

Change:

- Keep streaming internally if desired
- Do not render `currentSuggestion` to the user until the gate has passed
- Prefer showing only committed suggestions

If streaming is kept for the final generator:

- buffer the streamed text internally
- commit it to UI only after the output is complete and valid

## Step 13: Update `SuggestionsView` to support single strong suggestions

UI changes:

- make the top card emphasize one suggestion
- show source labels using file name and `headerContext`
- optionally show a short "why now" line in a subtle style for debugging

Do not add debug UI to the main experience by default.

Possible internal-only properties:

- `headline`
- `coachingLine`
- `evidenceLabel`
- `reason`

## Step 14: Add lightweight feedback controls

After the core behavior is stable, add small controls on each suggestion card:

- Helpful
- Not helpful
- Dismiss

This can be phase 2 if needed, but the data model and logging should leave room for it now.

## Logging and Evaluation

## Step 15: Extend `SessionRecord` and session logging

Persist enough information to evaluate false positives and false negatives later.

Suggested additions:

```swift
struct SessionRecord: Codable {
    let speaker: Speaker
    let text: String
    let timestamp: Date
    let suggestionDecision: SuggestionDecision?
    let surfacedSuggestion: Suggestion?
    let conversationStateSummary: String?
    let kbHits: [String]?
}
```

Important:

- Log decisions even when no suggestion is surfaced
- This is necessary for replay and threshold tuning

If storage cost becomes an issue:

- log compact summaries, not full prompt bodies

## Step 16: Add replay tooling

Add a developer-only replay tool that reads stored session JSONL and prints:

- trigger rate
- gate pass rate
- surfaced suggestion rate
- repeated suggestion rate
- top reasons for abstention

Implementation can be a small script under `scripts/` or a debug-only Swift entry point.

The tool should let the team replay a session and inspect where the system was noisy or too quiet.

## Step 17: Add threshold tuning workflow

After replay tooling exists:

1. Run it on real founder-conversation sessions
2. Inspect false positives first
3. Increase thresholds until noise is acceptably low
4. Only then work on recovering missed opportunities

Bias toward reducing false positives before improving recall.

## File-by-File Implementation Plan

## 1. `OnTheSpot/Sources/OnTheSpot/Models/Models.swift`

Add:

- `ConversationState`
- `SuggestionTriggerKind`
- `SuggestionTrigger`
- `SuggestionDecision`
- `SuggestionEvidence`
- `SuggestionFeedback`
- extended `Suggestion`
- extended `SessionRecord`

## 2. `OnTheSpot/Sources/OnTheSpot/Models/TranscriptStore.swift`

Add:

- `conversationState`
- helper methods to update and read compact conversation context
- duplicate suppression state if stored here instead of `SuggestionEngine`

Suggested methods:

- `func updateConversationState(_ state: ConversationState)`
- `var recentUtterancesForPrompt: [Utterance]`
- `var recentThemUtterances: [Utterance]`

## 3. `OnTheSpot/Sources/OnTheSpot/Intelligence/OpenRouterClient.swift`

Add:

- non-streaming completion method for structured JSON tasks

Suggested method:

```swift
func complete(
    apiKey: String,
    model: String,
    messages: [Message],
    maxTokens: Int = 512
) async throws -> String
```

This is needed for:

- conversation state updates
- surfacing gate decisions

## 4. `OnTheSpot/Sources/OnTheSpot/Intelligence/KnowledgeBase.swift`

Modify:

- `KBResult` construction to include `headerContext`
- indexing to preserve chunk identity and adjacency
- retrieval to support multi-query search and score fusion

Suggested API additions:

- `func search(queries: [String], topK: Int = 5) async -> [KBResult]`
- optional helper for neighborhood expansion

## 5. `OnTheSpot/Sources/OnTheSpot/Intelligence/SuggestionEngine.swift`

This file will take most of the changes.

Add internal stages:

1. `shouldEvaluateUtterance(_:)`
2. `detectTrigger(for:)`
3. `updateConversationStateIfNeeded(...)`
4. `retrieveEvidence(...)`
5. `runSurfacingGate(...)`
6. `generateSuggestion(...)`
7. `isDuplicateSuggestion(...)`
8. `logSuggestionDecision(...)`

Refactor `onThemUtterance(_:)` into a pipeline that:

1. rejects trivial utterances
2. updates conversation state
3. retrieves evidence from multiple queries
4. runs the gate
5. only then generates and stores a suggestion

## 6. `OnTheSpot/Sources/OnTheSpot/Views/SuggestionsView.swift`

Modify:

- stop showing uncommitted partial suggestions
- support a single strong primary suggestion
- show evidence labels more clearly
- optionally support feedback buttons later

## 7. `OnTheSpot/Sources/OnTheSpot/Views/ContentView.swift`

Keep trigger entry point the same for now, but ensure:

- suggestion logging includes decisions
- session records include new metadata
- no UI regressions when the engine abstains often

## 8. `OnTheSpot/Sources/OnTheSpot/Views/SettingsView.swift`

Do not add new user-facing knobs in the first pass.

Optional later:

- a hidden debug toggle for showing gate reasons
- a hidden debug toggle for showing abstention stats

## Prompt Contracts

All prompt-based stages should request strict JSON when possible.

## A. Conversation state updater prompt

Input:

- previous conversation state
- last 4-6 utterances
- latest utterance

Output:

- updated `ConversationState` JSON

Rules:

- compact
- no prose outside JSON
- focus on current topic and unresolved questions

## B. Surfacing gate prompt

Input:

- latest utterance
- recent exchange
- `ConversationState`
- retrieved KB evidence
- recent suggestion angles

Output:

- `SuggestionDecision` JSON

Rules:

- abstain aggressively
- optimize for whether the suggestion is worth showing now

## C. Suggestion generator prompt

Input:

- approved `SuggestionDecision`
- `ConversationState`
- latest utterance
- top evidence

Output:

- compact JSON or tightly constrained text

Suggested JSON:

```json
{
  "headline": "string",
  "coachingLine": "string",
  "evidenceLine": "string"
}
```

Using JSON here is preferable to freeform bullet parsing.

## Acceptance Tests

Claude should validate behavior with at least these scenarios.

### Scenario 1: Loose ideation

Transcript pattern:

- vague founder brainstorming
- incomplete sentences
- no clear question or decision

Expected:

- mostly no suggestions
- gate should abstain frequently

### Scenario 2: Narrowing customer segment

Transcript pattern:

- founders debating broad vs narrow market

Expected:

- suggestion appears near the decision point
- suggestion references wedge narrowing or customer pain specificity
- suggestion is concrete and reusable in next turn

### Scenario 3: Repeated topic

Transcript pattern:

- same product-scope discussion repeated several minutes later

Expected:

- duplicate advice suppressed unless new evidence or framing appears

### Scenario 4: Weak KB match

Transcript pattern:

- the other person says something unrelated to the KB

Expected:

- no suggestion
- gate rejects due to low relevance

### Scenario 5: Mid-thought utterance boundary

Transcript pattern:

- system audio flush produces a short, unfinished utterance

Expected:

- local heuristic skips evaluation

### Scenario 6: Strong explicit question

Transcript pattern:

- the other person asks a direct startup strategy question

Expected:

- suggestion appears if KB evidence is strong
- output is one actionable question or reframing

## Rollout Order

Claude should implement in this order:

1. Extend models and logging types
2. Add non-streaming OpenRouter method
3. Add conversation state support
4. Add local heuristic trigger filter
5. Add multi-query KB retrieval with richer evidence
6. Add surfacing gate
7. Refactor final suggestion generation to one suggestion
8. Remove noisy partial UI behavior
9. Add replay tooling
10. Tune thresholds using recorded sessions

## Success Criteria

The implementation is successful when:

- the app is quiet during casual or low-signal conversation
- surfaced suggestions feel timely rather than random
- suggestions reflect the broader conversation state, not only the last utterance
- suggestions are grounded in KB evidence with clear source context
- repeated advice is visibly reduced
- logs make it possible to explain why a suggestion was or was not shown

## Final Guidance for Claude

- Favor simple, inspectable heuristics before adding more model calls
- Bias for precision over recall
- Keep first-pass thresholds conservative
- Do not ship many user-facing settings until the behavior is stable
- Prefer structured JSON outputs over freeform text parsing
- If a stage fails, fall back safely and abstain rather than surfacing weak output
