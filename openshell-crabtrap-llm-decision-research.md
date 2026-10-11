# Policy Automation for AI Agents: OpenShell, CrabTrap, and an LLM Decision API

## Executive summary

OpenShell and CrabTrap address different layers of agent security:

- **OpenShell** enforces structured sandbox capabilities and uses formal methods to determine whether a candidate policy exceeds an explicit boundary.
- **CrabTrap** intercepts HTTP/HTTPS requests and uses deterministic rules followed by an LLM judge to decide whether each request matches a natural-language policy.
- **An LLM Decision API** can connect task intent to concrete policy, but it should not be the final authority. Its output should be compiled into narrow, expiring rules and checked by deterministic controls and the OpenShell prover before enforcement.

The recommended model is:

```text
FinalAllow =
    WithinFormalBoundary
    AND NoHardRiskFinding
    AND NoStaticDeny
    AND (StaticAllow OR ConstrainedLLMAllow)
```

This preserves the LLM's ability to interpret intent while keeping the security boundary deterministic and fail-closed.

## 1. OpenShell policy automation

OpenShell supports two related but distinct workflows:

1. Runtime proposal and approval of a narrow network rule.
2. Offline proof that a complete candidate policy is contained within an operator-defined boundary.

OpenShell does **not** ask Z3 to invent a policy or prove an informal statement such as “this policy is safe.” An agent or OpenShell first produces a concrete rule or policy. The prover then checks a precisely encoded property of that artifact.

### 1.1 Runtime policy-advisor flow

```text
Agent attempts network request
          |
          v
Current policy denies it
          |
          v
Agent or OpenShell drafts a narrow rule
          |
          v
OpenShell validates the proposal
          |
          v
Prover compares current policy with current + proposal
          |
          v
Risk findings and destination flags
          |
          v
Manual approval or conditional auto-approval
          |
          v
Rule is added and the sandbox policy is reloaded
          |
          v
Agent retries the original request
```

The detailed sequence is:

1. A sandboxed process attempts a network operation.
2. OpenShell denies the operation and records the denial.
3. A proposal is produced in one of two ways:
   - **Agent-authored:** the agent reads the policy-advisor guide, examines the current policy and recent denials, and submits a narrow rule.
   - **Mechanistic:** OpenShell derives a draft from the blocked connection, generally scoped to one binary, hostname, and port.
4. OpenShell validates the proposal's schema and its compatibility with overlapping endpoints.
5. OpenShell runs its formal proposal-risk checks and deterministic destination checks.
6. In manual mode, the proposal remains pending for an operator.
7. In automatic mode, the proposal is approved only if the prover and destination checks produce no relevant findings.
8. The approved rule is appended to the sandbox's own policy.
9. The running sandbox reloads the policy without a restart and closes connections established under the old policy.
10. The agent waits for confirmation that the policy was reloaded, then retries the original action.

### 1.2 Agent-facing API

When the policy advisor is enabled, an agent can use the sandbox-local `policy.local` service:

```text
GET  http://policy.local/v1/policy/current
GET  http://policy.local/v1/denials?last=10
POST http://policy.local/v1/proposals
GET  http://policy.local/v1/proposals/{chunk_id}
GET  http://policy.local/v1/proposals/{chunk_id}/wait?timeout=300
```

The agent should retry only after an approval response reports `policy_reloaded: true`.

Agent-authored proposals are deliberately limited. They can add network rules but cannot arbitrarily change filesystem, process, Landlock, or credential policy. Some network-policy features also cannot be proposed through this API.

### 1.3 Runtime proposal-risk checks

For each proposal, OpenShell effectively constructs:

```text
before = current effective policy
after  = current effective policy + proposed rule
```

It then asks whether the new rule introduces specific classes of risky access. The documented queries include:

| Finding | Meaning |
|---|---|
| `link_local_reach` | The proposal reaches a link-local address or known cloud metadata destination. |
| `l7_bypass_credentialed` | A binary using traffic that cannot be inspected gains access to a destination where a credential is available. |
| `credential_reach_expansion` | A binary gains credentialed access to a host and port it could not previously reach. |
| `capability_expansion` | The proposal adds a new HTTP method where credentialed access already exists. |

Conceptually, each check asks:

```text
Does there exist an action newly enabled by the proposal
that satisfies this risky condition?
```

The solver result is interpreted as follows:

- `sat`: a risky action exists; the model provides a concrete counterexample.
- `unsat`: no modeled action satisfies that risk query.
- `unknown` or unsupported: the system must fail closed and require review.

Passing these proposal checks does not prove that the resulting policy stays within a broader organizational boundary. It only establishes that the built-in proposal-risk queries did not find a modeled risk.

### 1.4 Complete boundary proof

The stronger OpenShell workflow compares a complete candidate policy with a boundary policy:

```text
Human or parent agent defines boundary.yaml
          |
          v
Agent constructs candidate.yaml
          |
          v
OpenShell translates both policies into SMT formulas
          |
          v
Z3 searches for an action allowed by the candidate
but not allowed by the boundary
```

The command is:

```shell
openshell-prover check candidate.yaml \
  --boundary boundary.yaml \
  --output json
```

Formally, OpenShell wants to establish:

```text
Allowed(candidate) subset-of Allowed(boundary)
```

It does this by searching for a counterexample:

```text
CandidateAllows(action) AND NOT BoundaryAllows(action)
```

or, equivalently:

```text
Allowed(candidate) - Allowed(boundary) is non-empty
```

The results mean:

| Result | Interpretation |
|---|---|
| `within_boundary` | No modeled counterexample exists. |
| `exceeds_boundary` | The solver found an action allowed by the candidate but forbidden by the boundary. |
| `unsupported` | A policy uses semantics outside the current formal model. |
| `inconclusive` | The solver could not establish either answer within its limits. |

Only `within_boundary` is a passing result. Unsupported and inconclusive checks must not be treated as approval.

The current model covers documented portions of filesystem, process identity, Landlock, network L4, and REST policy. Features outside the model, such as certain GraphQL or MCP rules, cause an unsupported result rather than being silently ignored.

### 1.5 A fully bounded automatic OpenShell workflow

For strong automation, use both OpenShell mechanisms:

1. Define and human-review a maximum boundary policy.
2. Let an agent generate a complete candidate policy.
3. Require the standalone prover to return `within_boundary` before applying it.
4. During runtime, allow the policy advisor to propose narrow network additions.
5. Run the proposal-risk checks.
6. Construct the complete effective post-change policy.
7. Prove that post-change policy against the maximum boundary.
8. Apply it only if every required check passes.

The last boundary check is essential. OpenShell's built-in automatic proposal approval does not, by itself, prove compliance with an independently defined maximum policy.

## 2. CrabTrap's approach

CrabTrap is an outbound HTTP/HTTPS proxy for agents. The agent is configured to use it through `HTTP_PROXY` and `HTTPS_PROXY`. For HTTPS, CrabTrap terminates TLS with its own certificate authority and creates a separate upstream connection.

Its request flow is:

```text
Outbound HTTP request
        |
        v
Static URL and method rules
        |
        +-- matching deny --> DENY
        |
        +-- matching allow -> ALLOW
        |
        v no match
LLM judge evaluates the full request
against the agent's natural-language policy
        |
        +-- ALLOW --> forward request
        |
        +-- DENY --> return 403 with reason
```

Deny rules take precedence. Static matches avoid an LLM call and execute quickly. Only the long tail of unmatched traffic reaches the LLM judge.

### 2.1 What the judge receives

The judge receives a structured representation of the request, including method, URL, selected headers, and body. CrabTrap describes several safeguards:

- Request data is represented as structured JSON instead of being interpolated directly into instructions.
- Header content is capped.
- Bodies are truncated with an explicit indication of truncation.
- Multipart requests are summarized structurally.
- The circuit breaker and fallback behavior are configurable.

These measures reduce common prompt-injection and availability risks, but they cannot turn a probabilistic model decision into a formal authorization guarantee.

### 2.2 Policy generation and evaluation

CrabTrap includes two important feedback systems:

- A **policy builder** analyzes historical traffic and drafts a natural-language policy representing observed behavior.
- An **evaluation system** replays historical audit entries against a draft policy and reports how decisions would change.

This observation-first approach is useful for discovering the real behavior of an agent and promoting frequent, well-understood actions into fast static rules.

### 2.3 Current boundaries

CrabTrap's documented limitations include:

- It is an outbound proxy, not an inbound WAF.
- It sees decrypted request content, including credentials, inside its trust boundary.
- It does not redact secrets automatically.
- It does not currently provide a human approval queue.
- It evaluates requests but does not filter upstream responses.
- It evaluates the WebSocket upgrade but not subsequent frames.
- Direct egress needs to be blocked separately to prevent proxy bypass.

## 3. Comparison

| Dimension | CrabTrap | OpenShell advisor/prover |
|---|---|---|
| Primary layer | HTTP/HTTPS request proxy | Sandbox capability enforcement |
| Decision granularity | Individual request | Policy rule or complete policy |
| Policy representation | Natural language plus static URL rules | Structured policy |
| Reasoning mechanism | Probabilistic LLM judgment | Deterministic checks and SMT proof |
| Understands task intent | Yes, approximately | No |
| Formal containment | No | Yes, for modeled semantics |
| Automatic policy creation | Infers policy from observed traffic | Drafts narrow network rules from denials |
| Human approval | Not currently built in | Pending/approve/reject workflow |
| Coverage | Primarily outbound HTTP/HTTPS | Network plus other sandbox capabilities |
| Main failure mode | Incorrect or manipulated model decision | Incomplete formal-model coverage |
| Useful evidence | Audit history and replay evaluation | Counterexamples, coverage, and proof result |

The two systems answer different questions:

- CrabTrap: **Does this particular request appear consistent with the agent's assigned task?**
- OpenShell: **Does the policy permit any modeled action outside the declared capability boundary?**

Semantic judgment and formal containment are complementary; neither subsumes the other.

## 4. Risks of an LLM-only decision boundary

Allowing a model to authorize unmatched requests directly creates several important risks:

1. **Nondeterminism:** equivalent requests may receive different decisions.
2. **Ambiguous policy:** natural-language rules may contain gaps or conflicting interpretations.
3. **Prompt injection:** attacker-controlled URLs, headers, or bodies may influence the judge.
4. **Incomplete visibility:** truncation can omit the decisive part of a request.
5. **Secret exposure:** request headers and bodies may contain credentials or sensitive data.
6. **Proxy bypass:** a process may use another protocol or direct connection unless the runtime blocks it.
7. **Capability mismatch:** approving one request does not establish that a broad rule is safe for every request it permits.
8. **Sequence blindness:** individually reasonable actions can form a dangerous multi-step sequence.
9. **Model drift:** model or prompt changes can silently alter authorization behavior.
10. **Availability pressure:** latency, rate limits, or provider failures can encourage unsafe passthrough fallbacks.

Structured prompts, static deny precedence, traffic limits, SSRF protection, and fail-closed operation reduce risk, but the model should still not be the root authorization authority.

## 5. A hybrid LLM Decision API

The Decision API should translate task intent into a constrained recommendation. Deterministic enforcement and formal proof should remain authoritative.

### 5.1 Recommended architecture

```text
Agent action
    |
    v
Canonical typed action
    |
    v
Hard denies and static policy
    |
    v
Formal maximum-boundary check
    |
    v
LLM Decision API for semantic ambiguity
    |
    v
Compile the decision into a narrow temporary rule
    |
    v
Run proposal-risk checks
    |
    v
Prove the complete post-change policy against the boundary
    |
    v
Apply, execute, audit, and expire
```

The combined authorization condition should be:

```text
FinalAllow =
    WithinFormalBoundary
    AND NoHardRiskFinding
    AND NoStaticDeny
    AND (
        StaticPolicyAllows
        OR LLMDecisionAllowsUnderConstraints
    )
```

The LLM must never override:

- A formal boundary violation
- A static deny
- An unsupported or inconclusive proof
- Credential scope restrictions
- Link-local, metadata, or private-network protections
- An explicit human-approval requirement

### 5.2 Decision request

A useful request schema would include:

```json
{
  "agent": {
    "id": "docs-agent",
    "binary": "/usr/bin/gh"
  },
  "task": {
    "id": "task-123",
    "intent": "Update documentation in nirmata/demo-openshell"
  },
  "action": {
    "protocol": "rest",
    "method": "PUT",
    "host": "api.github.com",
    "port": 443,
    "path": "/repos/nirmata/demo-openshell/contents/docs/guide.md",
    "body_digest": "sha256:..."
  },
  "credential": {
    "provider": "github",
    "scope_class": "repository-write"
  },
  "policy": {
    "current_version": "42",
    "boundary_version": "7"
  },
  "history_summary": {
    "recent_actions": [],
    "recent_denials": []
  }
}
```

Raw secrets should be removed before calling an external model. The judge generally needs credential identity and scope, not the credential value.

### 5.3 Decision response

Avoid a response containing only `ALLOW` or `DENY`. Require explicit constraints:

```json
{
  "decision": "allow_with_constraints",
  "reason_code": "task_consistent_documentation_update",
  "constraints": {
    "binary": "/usr/bin/gh",
    "credential": "github-docs-provider",
    "host": "api.github.com",
    "port": 443,
    "protocol": "rest",
    "method": "PUT",
    "path": "/repos/nirmata/demo-openshell/contents/docs/**",
    "max_uses": 1,
    "expires_in_seconds": 120
  },
  "confidence": 0.94,
  "requires_human_review": false
}
```

The trusted control plane should then:

1. Validate the response schema.
2. Intersect the returned constraints with the caller's maximum boundary.
3. Compile the constraints into a concrete OpenShell rule.
4. Run proposal-risk checks.
5. Prove the complete resulting policy against the boundary.
6. Apply the rule only when all checks pass.

### 5.4 Bind approval to the exact action

A decision must not be reusable for a materially different request. The authorization record should bind:

```text
agent identity
task identity
binary identity
credential identity
HTTP method
normalized destination and path
security-relevant headers
body digest
current policy version
boundary version
expiration
maximum use count
```

The record should be signed or generated by the trusted decision service and checked atomically by the enforcement point.

Without request binding, an agent could obtain approval for a benign request and reuse it with a different body, credential, or policy state. This is a policy time-of-check/time-of-use problem.

For large or streaming bodies, either buffer and hash the complete body before approval or use a deterministic streaming validator. A model must not approve content it did not observe.

### 5.5 Use `allow`, `deny`, and `escalate`

The API should support at least three outcomes:

```text
ALLOW_WITH_CONSTRAINTS
DENY
ESCALATE
```

Escalation is appropriate when:

- The action has irreversible or high-impact consequences.
- The prover reports unsupported or inconclusive semantics.
- Request content was truncated or unavailable.
- The model has low confidence.
- The action uses a new credential, destination, binary, or capability class.
- The requested rule would live longer than the current action.
- The action conflicts with prior decisions or unusual session behavior.

Confidence alone must never authorize an action outside the deterministic boundary.

## 6. Safe automatic policy learning

A robust policy-learning loop combines CrabTrap-style observation with OpenShell-style containment:

```text
Observed traffic and operator decisions
            |
            v
LLM proposes candidate rules
            |
            v
Replay against historical traffic
            |
            v
Measure false allows and false denies
            |
            v
OpenShell proves candidate is within the boundary
            |
            v
Shadow deployment
            |
            v
Human review or risk-based promotion
            |
            v
Deterministic static policy
```

Recommended promotion criteria include:

- No boundary violations
- No unsupported proof domains relevant to the rule
- Zero known false allows in the evaluation set
- An acceptable false-deny rate
- Stable results across model and prompt versions
- A minimum number of representative observations
- Shadow-mode performance over a defined period
- Explicit owner and expiration or review date

The LLM discovers and explains policy. Historical replay evaluates policy behavior. The prover establishes containment. The runtime enforces the result.

## 7. Sequence-aware decisions

Some risks emerge only across a sequence of actions:

```text
read customer records
        -> upload a file
        -> create a public sharing link
```

Each request may appear reasonable in isolation. A Decision API should therefore receive a bounded, security-focused session summary containing facts such as:

- Sensitive sources accessed during the task
- Data classifications currently held by the agent
- Credentials used
- External destinations contacted
- State-changing actions already performed
- Outstanding approvals and denied operations

This summary should be produced by trusted telemetry rather than by the agent itself. Formal state-machine checks should handle invariants that can be expressed deterministically; the LLM can interpret ambiguous task relationships within those hard limits.

## 8. Operational safeguards

### 8.1 Fail closed

Timeouts, malformed responses, provider failures, circuit-breaker activation, unsupported proofs, and policy-version mismatches should deny or escalate. Passthrough fallback is inappropriate for a security boundary.

### 8.2 Minimize disclosed data

- Strip authorization tokens, cookies, session IDs, and unnecessary personal data.
- Replace secrets with typed metadata describing their identity and scope.
- Prefer body digests plus deterministic extracted facts where possible.
- Use an appropriately controlled model deployment for sensitive request content.

### 8.3 Version everything

Every audit record should include:

- Decision API version
- Model and model snapshot
- System prompt and policy versions
- Static-rule version
- OpenShell policy and boundary versions
- Prover version and modeled coverage
- Canonical action hash
- Final enforcement result

### 8.4 Separate explanation from authority

LLM-generated reasons are useful for operators, but authorization should depend on structured fields and deterministic checks. Never parse free-form prose to determine the enforced scope.

### 8.5 Cache carefully

Cache only decisions whose complete security-relevant inputs match. Include the policy version, boundary version, model decision version, credential identity, and request body digest in the cache key. Prefer converting repeated safe decisions into reviewed static rules rather than maintaining a broad semantic cache.

## 9. Recommended implementation phases

### Phase 1: Decision API in shadow mode

- Send unmatched or denied actions to the Decision API.
- Do not let its output change enforcement.
- Compare its decisions with existing static policy and operator decisions.
- Build an evaluation corpus from disagreements.

### Phase 2: Proposal assistant

- Let the API generate narrow OpenShell proposal constraints.
- Require human approval for every proposal.
- Present the LLM rationale, prover findings, and counterexamples together.

### Phase 3: Low-risk automatic approval

- Permit automatic approval only for short-lived, single-use rules.
- Require successful proposal-risk and maximum-boundary checks.
- Exclude sensitive credentials, private destinations, destructive methods, and unsupported policy features.

### Phase 4: Policy learning

- Generate candidate static rules from repeated approved actions.
- Replay historical traffic and run regression evaluations.
- Prove the candidate policy against the maximum boundary.
- Promote only after shadow deployment and review criteria pass.

### Phase 5: Sequence-aware governance

- Add trusted session-state summaries.
- Encode deterministic cross-action invariants where possible.
- Use the LLM for ambiguous intent classification and escalation recommendations.

## 10. Conclusions

CrabTrap and OpenShell solve complementary parts of agent authorization:

- CrabTrap supplies semantic, request-level judgment and traffic-driven policy discovery.
- OpenShell supplies structured runtime enforcement, explicit policy-change workflows, and formal containment proofs.
- An LLM Decision API can bridge human intent and concrete capabilities, but it should generate constrained proposals rather than unrestricted authorization decisions.

The strongest design is therefore:

```text
LLM proposes or interprets
Deterministic policy constrains
Formal methods prove containment
Runtime enforcement executes
Audit and replay improve the policy
```

This architecture does not attempt to make an LLM deterministic. It places the model where probabilistic reasoning is valuable while retaining deterministic controls wherever a security guarantee is required.

## Sources

### OpenShell

- NVIDIA OpenShell Research, [What we have learned applying formal methods to control AI agents](https://nvidia.github.io/OpenShell-Research/dev-notes/posts/2026-09-10-learning-formal-methods-agent-policy-prover/)
- NVIDIA OpenShell, [Policy Advisor documentation source](https://github.com/NVIDIA/OpenShell/blob/main/docs/how-it-works/policies/advisor.mdx)
- NVIDIA OpenShell, [Policy Prover documentation source](https://github.com/NVIDIA/OpenShell/blob/main/docs/how-it-works/policies/prover.mdx)
- NVIDIA OpenShell, [OpenShell repository](https://github.com/NVIDIA/OpenShell)
- Microsoft Research, [Z3 Guide](https://microsoft.github.io/z3guide/)

### CrabTrap

- Brex, [CrabTrap: an LLM-as-a-judge HTTP proxy to secure agents in production](https://www.brex.com/journal/building-crabtrap-open-source)
- Brex, [CrabTrap repository](https://github.com/brexhq/CrabTrap)
- Brex, [CrabTrap quickstart](https://github.com/brexhq/CrabTrap/blob/main/QUICKSTART.md)

## Research date

October 9, 2026.
