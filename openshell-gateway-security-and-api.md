# OpenShell Gateway Security and API

This note describes the OpenShell `0.1.2` Kubernetes installation used by this
repository. It distinguishes transport security, user authorization, and the
Kubernetes admission controls that prevent callers from bypassing the gateway.

## Security in this demo

The Helm chart enables TLS and mutual TLS by default. The gateway terminates TLS
and validates client certificates using its configured client CA. Sandbox
supervisors also authenticate their callbacks to the gateway, with bootstrap
credentials exchanged for gateway-minted, sandbox-bound JWTs.

The gateway Service is a Kubernetes `ClusterIP`. The demo reaches it through a
`kubectl port-forward`, and `scripts/gateway.sh` copies the client certificate,
key, and CA from the `openshell-client-tls` Secret into repository-local CLI
state.

This repository deliberately relaxes **user authentication** for local
development:

```yaml
server:
  auth:
    allowUnauthenticatedUsers: true
```

That setting maps unauthenticated requests to a local-development principal.
The shared mTLS client certificate protects the connection but does not provide
an individual human identity. This configuration must not be exposed outside a
trusted local development environment.

## Restricting sandbox creation

A shared or production installation should disable the development principal
and configure OIDC:

```yaml
server:
  auth:
    allowUnauthenticatedUsers: false
  oidc:
    issuer: https://idp.example.com/realms/openshell
    audience: openshell-cli
    rolesClaim: realm_access.roles
    adminRole: openshell-admin
    userRole: openshell-user
```

`CreateSandbox` requires the `sandbox:write` scope and at least the workspace
`user` role. An identity can create a sandbox only in a workspace of which it is
a member. Workspace administrators manage membership; platform administrators
manage broader gateway resources. Limit the configured OIDC roles, scopes, and
workspace membership to approved identities.

OIDC authorization protects the gateway API, but Kubernetes users could
otherwise bypass it by creating Agent Sandbox custom resources directly. The
Kyverno policy in
`config/kyverno/policies/require-openshell-provisioning.yaml` denies every
`Sandbox` CREATE unless the Kubernetes caller is:

```text
system:serviceaccount:openshell:openshell
```

Use both controls:

1. OIDC roles, scopes, and workspace membership control requests to OpenShell.
2. Kubernetes RBAC should not grant humans direct `sandboxes` creation rights.
3. Kyverno provides a fail-closed admission guard against accidental RBAC
   over-permission and forces creation through the gateway.
4. Keep the gateway private, or expose it only through a TLS-enabled,
   authenticated edge with appropriate network restrictions.

## Gateway protocols

The management API is primarily **gRPC over HTTP/2**, defined by the protobuf
service `openshell.v1.OpenShell`. It is not a conventional JSON REST management
API. One gateway listener multiplexes traffic by protocol and content type:

| Surface | Protocol | Purpose |
| --- | --- | --- |
| Management API | gRPC over HTTP/2 | Sandbox, policy, provider, workspace, configuration, and service management |
| Streaming operations | Streaming gRPC | Interactive exec, TCP forwarding, watches, supervisor sessions, logs, and relays |
| Exposed sandbox services | HTTP/HTTPS proxy | Routes HTTP requests to services exposed from sandboxes |
| Edge tunnel | Optional WebSocket | Carries gRPC through an authenticated HTTP/1.1-oriented edge proxy |
| Health | HTTP | `/health`, `/healthz`, and `/readyz` on the health listener |
| Metrics | HTTP | Prometheus `/metrics` on the metrics listener |

OpenShell also has internal gRPC surfaces for compute drivers, sandbox
supervisors, and gateway peers. Their authentication modes are distinct from
ordinary bearer-authenticated user/controller calls and should not be treated
as public controller APIs.

## Major management API areas

The public `OpenShell` service includes:

- sandbox create, get, list, start, stop, delete, watch, exec, and SSH;
- TCP forwarding and exposed sandbox service management;
- reusable sandbox workload templates;
- provider records, profiles, credentials, attachment, and readiness status;
- workspace and workspace-membership management;
- effective configuration and policy updates;
- policy revision history, load status, drafts, and approval workflows;
- sandbox logs and gateway metadata.

Several operations are streaming RPCs. Controllers should use the supplied SDK
instead of attempting to model these as REST endpoints.

## External controller access

An external controller can query the gateway using the Go, Python, TypeScript,
or Rust SDK, or generated protobuf stubs. The Go SDK is explicitly intended for
applications, operators, and controllers. Keep the SDK and gateway on matching
OpenShell releases when possible.

For a non-interactive production controller, use an OIDC client-credentials
identity with TLS and grant only the scopes and workspace memberships it needs.
The important read APIs are:

| RPC | Information returned |
| --- | --- |
| `ListSandboxes` | Workspace sandbox inventory and current state |
| `GetSandbox` | Desired specification, creation policy, labels, conditions, lifecycle phase, active policy version, endpoint status, and configuration admission |
| `WatchSandbox` | Streaming status snapshots, correlated gateway logs, and platform events |
| `GetSandboxConfig` | Effective policy, version, hash, source, settings, revisions, workspace, and validation/admission details |
| `ListSandboxPolicies` | Paginated policy revision history, load state, hashes, timestamps, provenance, and optional full policy bodies |
| `GetSandboxPolicyStatus` | A selected or latest revision, its active version, load result, and load error |
| `GetSandboxLogs` | Recent sandbox logs |
| `GetDraftPolicy` / `GetDraftHistory` | Pending policy recommendations and decision history |
| `ListSandboxProviders` / `GetSandboxProviderStatus` | Desired attachments and observed installed provider authority |

The structured sandbox policy contains filesystem access, Landlock posture,
process identity, network rules, L7 restrictions, and network middleware
configuration.

Read operations generally require `sandbox:read` or `config:read` plus workspace
`user` membership. Policy changes require `config:write` and workspace `admin`.
Sandbox-only reporting RPCs reject normal external identities.

Querying Kubernetes `Sandbox` custom resources is useful for infrastructure
observation but is not equivalent to querying the gateway. The gateway owns the
richer effective policy, revision history, configuration admission, logs,
provider state, workspace authorization, and normalized lifecycle model.

## Version basis

These findings were verified against:

- the repository's pinned OpenShell Helm chart version `0.1.2`;
- the chart defaults and generated README for `0.1.2`;
- `proto/openshell.proto` and `proto/sandbox.proto` at the OpenShell `v0.1.2`
  tag; and
- the Go and TypeScript SDK documentation shipped with that tag.

API details and authorization requirements may change in later releases, so
controllers should pin compatible SDK and gateway versions.
