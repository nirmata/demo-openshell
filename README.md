# OpenShell on kind

A local demo of [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) and
[Kyverno](https://kyverno.io/) running on a kind cluster named `openshell`. It
demonstrates both OpenShell's in-sandbox policy enforcement and Kyverno's
protection of the Kubernetes control-plane boundary around each sandbox.

## What is installed

| Component | Version | Purpose |
| --- | --- | --- |
| Kubernetes | 1.35.0 | two-node kind cluster named `openshell` |
| Cilium | 1.20.0 | enforces ingress and egress `NetworkPolicy` |
| Agent Sandbox | v1.0.5 | provisions sandbox workloads on Kubernetes |
| OpenShell | 0.1.3 | workspace-aware gateway, supervisor, sandbox runtime, and policy engine |
| Kyverno | 1.18.2 | admission guardrails around OpenShell and Agent Sandbox |
| netshoot | v0.13 | multi-architecture demo workload with `curl` |

Versions are pinned in `scripts/lib.sh` and can be overridden with environment
variables. OpenShell requires a CNI that actually enforces Kubernetes network
policies; that is why this demo replaces kindnet with Cilium.

The demo creates a logical OpenShell workspace named `demo` and scopes its
sandboxes, policy, logs, and cleanup operations to that workspace. Override it
with `OPENSHELL_WORKSPACE`; Kubernetes resources remain in the shared `openshell`
namespace, which is the appropriate workspace mode for this single-team demo.

See [`openshell-sandbox-lifecycle.md`](docs/dev/openshell-sandbox-lifecycle.md) for a
step-by-step explanation of how the gateway, Kubernetes driver, Agent Sandbox
controller, supervisor, and sandbox runtime create and manage a sandbox.

## Requirements

Install Docker, kind, kubectl, Helm, curl, SSH, and `nc`. On macOS:

```sh
brew install kind kubernetes-cli helm curl openssh netcat
brew install --cask docker
```

Docker must be running.

## Setup

```sh
./scripts/setup.sh
./scripts/install-cli.sh
./scripts/verify.sh
```

Every command explicitly targets `kind-openshell`; the scripts do not change
your current kubectl context. Setup is idempotent and safe to rerun.

`install-cli.sh` downloads the pinned, checksum-verified OpenShell CLI into
`.tools/bin`. It does not install a system package or start OpenShell's separate
host gateway. CLI state and Kubernetes client certificates remain under
`.state/` in this repository.

The gateway enables OpenShell's unauthenticated local-development principal so
the port-forwarded demo does not require an external OIDC provider. TLS remains
enabled, the client bundle stays repo-local, and the Service is `ClusterIP`—do
not expose this configuration outside a trusted local development machine.
The sandbox policy requires Landlock rather than silently degrading when its
configured filesystem restrictions cannot be installed.

## Demo

### OpenShell network policy

```sh
./scripts/demo.sh
```

To create the same workload in the kind cluster and enter its shell
interactively, first connect and keep the gateway port-forward running in one
terminal:

```sh
./scripts/gateway.sh
```

Then use the repository-local CLI configuration in another terminal:

```sh
export XDG_CONFIG_HOME="$PWD/.state/config"

.tools/bin/openshell gateway select kind-openshell
.tools/bin/openshell workspace create --name demo # first run only
.tools/bin/openshell sandbox create \
  --workspace demo \
  --name policy-demo \
  --from nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b \
  --no-auto-providers
```

The final command creates the sandbox through the OpenShell gateway on the
`openshell` kind cluster and connects directly to its interactive shell. If the
sandbox already exists, reconnect with:

```sh
.tools/bin/openshell sandbox connect policy-demo --workspace demo
```

Exit the shell and remove the sandbox when finished:

```sh
.tools/bin/openshell sandbox delete policy-demo --workspace demo
```

#### See the Kyverno policies in action

OpenShell renders each sandbox as a Kubernetes `Sandbox` resource named
`<workspace>--<name>`, so Kyverno admits, mutates, or denies it like any other
workload. While the sandbox exists, inspect the defaults that Kyverno added:

```sh
kubectl --context kind-openshell -n openshell get sandbox demo--policy-demo \
  -o jsonpath='{.spec.podTemplate.spec.containers[0].resources}'
```

Kyverno fills in any CPU, memory, or ephemeral-storage request or limit that the
sandbox omits, so OpenShell resource flags within the bounds work:

```sh
.tools/bin/openshell sandbox create --workspace demo --name cpu-two --cpu 2 \
  --from nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b \
  --no-auto-providers --no-tty -- echo ready
```

Requests that break a policy fail with the policy message:

```sh
# Denied: A sandbox container may use at most 4 CPU, 8Gi memory, and 20Gi ephemeral storage.
.tools/bin/openshell sandbox create --workspace demo --name cpu-eight --cpu 8 \
  --from nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b \
  --no-auto-providers --no-tty -- echo ready

# Denied: Sandbox images must use immutable sha256 digest references.
.tools/bin/openshell sandbox create --workspace demo --name mutable \
  --from nicolaka/netshoot:v0.13 --no-auto-providers --no-tty -- echo ready
```

Remove the allowed sandbox when finished:

```sh
.tools/bin/openshell sandbox delete cpu-two --workspace demo
```

The automated walkthrough:

1. port-forwards the Kubernetes gateway using mTLS;
2. creates an OpenShell sandbox with default-deny networking;
3. proves a request to `api.github.com` is denied;
4. hot-applies a rule allowing `curl` read-only access to that API;
5. proves GET is allowed while POST is denied at layer 7; and
6. prints the policy audit events and deletes the sandbox.

### Kyverno production guardrails

```sh
./scripts/kyverno-demo.sh
```

This tests controls that remain useful when Kubernetes RBAC is correctly
configured:

1. rejects a privileged sandbox;
2. rejects wildcard expansion of an OpenShell Role;
3. rejects a network-fence change that enables direct workload egress;
4. rejects a mutable workload image tag;
5. adds missing resource defaults and rejects an oversized sandbox;
6. rejects raw Kubernetes Secret injection; and
7. creates a compliant OpenShell sandbox with immutable images and resource
   bounds.

The enforce-mode policies are under `config/kyverno/policies/`:

| Policy | Control |
| --- | --- |
| `default-sandbox-resources` | supplies each missing CPU, memory, and ephemeral-storage request and limit, keeping requests at or below limits |
| `enforce-sandbox-resource-bounds` | requires requests and limits and caps each sandbox container |
| `enforce-sandbox-pod-security` | enforces non-root, capability-free, seccomp-confined workloads without host access |
| `protect-sandbox-credentials` | requires provider-based credentials instead of raw Secrets or ServiceAccount tokens |
| `enforce-sandbox-image-hygiene` | requires immutable SHA-256 image references |
| `restrict-openshell-rbac` | prevents wildcard and privilege-escalation permissions in OpenShell roles |
| `verify-openshell-network-boundary` | validates the workload fence's selectors, ingress path, and default-deny egress semantics |

OpenShell remains the primary owner of its network, filesystem, process,
provider, and inference policy. Kyverno supplies missing Kubernetes defaults
and verifies the rendered cluster boundary.

Advanced attestation, vulnerability, runtime-isolation, CNI-specific, and
lifecycle policies are deliberately not installed without their required trust
and infrastructure configuration.

The equivalent complete policy is in `config/openshell/policy.yaml`. The demo
uses `policy update` so the policy change is visible while the sandbox is
running.

Useful inspection commands:

```sh
kubectl --context kind-openshell get pods -A
kubectl --context kind-openshell -n openshell get networkpolicy
kubectl --context kind-openshell -n openshell logs statefulset/openshell --tail=100
./scripts/operations.sh --since 10m
./scripts/kubernetes-events.sh
```

`operations.sh` turns the verbose gateway logs into a compact timeline of API,
sandbox, driver, and supervisor activity. Pass `--follow` to watch operations
live, or `--all` to include background reconciliation and credential refreshes.
`kubernetes-events.sh` watches new cluster events across all namespaces and
highlights workload lifecycle and policy violations. Pass `--warnings-only` to
focus on failures, or `--namespace openshell` to limit the watch.

## Cleanup

```sh
./scripts/cleanup.sh
```

This deletes only the kind cluster named `openshell`. The ignored `.tools/` and
`.state/` directories can be removed separately if the local CLI and demo state
are no longer wanted.

## Upstream references

- [OpenShell Kubernetes setup](https://docs.nvidia.com/openshell/latest/kubernetes/setup)
- [OpenShell workspaces](https://docs.nvidia.com/openshell/latest/how-it-works/workspaces)
- [OpenShell first network-policy tutorial](https://docs.nvidia.com/openshell/latest/tutorials/first-network-policy)
- [Agent Sandbox](https://agent-sandbox.sigs.k8s.io/)
- [Nirmata network-policy automation demo](https://github.com/nirmata/demo-network-policy-automation)
