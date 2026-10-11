# OpenShell Sandbox Lifecycle

This document explains how an OpenShell sandbox is created, operated, stopped,
restarted, and deleted in this Kubernetes demo. It describes the roles of the
OpenShell CLI and gateway, the OpenShell Kubernetes compute driver, the
Kubernetes Agent Sandbox controller, and the per-sandbox supervisor.

## Components

| Component | Responsibility |
| --- | --- |
| OpenShell CLI | Submits sandbox intent and attaches the user's terminal to the running sandbox. |
| OpenShell gateway | Authenticates the caller, validates policy and resources, stores sandbox state, and coordinates the lifecycle. |
| Kubernetes compute driver | Translates the OpenShell sandbox specification into Kubernetes resources and verifies the resulting isolation boundary. |
| Agent Sandbox controller | Reconciles the `Sandbox` custom resource into the workload Pod and persistent workspace. |
| Supervisor | Maintains the trusted control channel, enforces network policy, proxies traffic, and relays exec, logs, and file operations. |
| Sandbox runtime | Runs inside the untrusted workload and applies filesystem, process, socket, and DNS controls before launching the requested process. |
| Cilium | Enforces the outer Kubernetes `NetworkPolicy` fence around workload and supervisor Pods. |

The OpenShell sandbox is the logical resource stored by the gateway. Its Pods,
Services, Secrets, PVC, and network policies are replaceable implementation
details managed by the Kubernetes driver and Agent Sandbox controller.

## Creation Flow

```text
OpenShell CLI
    │ CreateSandbox
    ▼
OpenShell gateway
    │ validate and persist Provisioning state
    ▼
Kubernetes compute driver
    │ create network fences and suspended Sandbox CR
    ▼
Agent Sandbox controller
    │ create gated workload Pod and workspace PVC
    ▼
Kubernetes compute driver
    │ validate admitted Pod and create supervisor resources
    ▼
Supervisor ───────── authenticate and connect ───────── Gateway
    │ synchronize policy and confirm enforcement
    ▼
Sandbox runtime launches the requested command
    │
    ▼
Sandbox is ready for exec, SSH, logs, and policy updates
```

### 1. The CLI submits sandbox intent

The demo creates a sandbox with a command equivalent to:

```sh
.tools/bin/openshell sandbox create \
  --workspace demo \
  --name policy-demo \
  --from nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b \
  --no-auto-providers
```

The request identifies the logical workspace, sandbox name, immutable workload
image, initial command or shell, resource requirements, providers, environment,
labels, and optional policy. The CLI sends it to the selected gateway over the
TLS-protected OpenShell API.

### 2. The gateway validates and records the request

The gateway:

1. authenticates and authorizes the caller in the selected workspace;
2. resolves the requested template, image, policy, providers, and resources;
3. rejects invalid or unsafe configuration before provisioning;
4. creates a durable sandbox record in the `Provisioning` phase; and
5. generates launch authentication bound to the sandbox and runtime
   generation.

The gateway then invokes its configured Kubernetes compute driver. The durable
record prevents a Kubernetes Pod from becoming the authoritative sandbox state.

### 3. The driver builds the outer fence first

Before the workload can run, the Kubernetes driver creates generation-specific
network policies that distinguish two boundary roles:

- **workload**: the untrusted user or agent environment;
- **supervisor**: the trusted OpenShell control and policy component.

The workload is fenced from direct egress and communicates through only its
matching supervisor boundary. Cilium enforces these Kubernetes network
policies in this demo.

The driver then creates an Agent Sandbox `Sandbox` custom resource in a
suspended state. This ordering prevents an unfenced workload from racing ahead
of its security controls.

### 4. Agent Sandbox creates the workload

The Agent Sandbox controller observes the custom resource and prepares:

- the workload Pod based on the requested image;
- the PVC-backed `/sandbox` workspace; and
- initialization that seeds the workspace on its first use.

OpenShell releases the custom resource far enough for the controller to create
the Pod, but a scheduling gate and missing generation-specific bootstrap
material keep the workload from starting prematurely.

### 5. OpenShell validates the admitted Pod

The compute driver reads the Pod after Kubernetes admission and confirms that
the effective object still preserves the intended boundary, including:

- non-root numeric UID and GID;
- no added Linux capabilities or privilege escalation;
- `RuntimeDefault` seccomp;
- no host network, PID, or IPC namespaces;
- no Kubernetes ServiceAccount token in the workload;
- the expected owner UID, boundary labels, volumes, and network fence; and
- the expected restart, DNS, and scheduling-gate configuration.

Admission mutation that weakens these properties causes creation to fail
closed. Kyverno adds resource, image, pod-security, credential, RBAC, and
network-boundary checks around this same Kubernetes control-plane boundary.

### 6. OpenShell provisions the supervisor side

After validating the workload, the driver creates the trusted resources for
the current runtime generation:

- a supervisor Pod;
- a private boundary Service;
- per-sandbox TLS and bootstrap Secrets;
- audience-bound supervisor authentication; and
- any required generation-specific image pull material.

The workload does not receive gateway credentials. The supervisor receives a
projected, audience-bound token that it exchanges through the gateway's
sandbox authentication flow.

When all required objects exist, OpenShell removes the scheduling gates from
the supervisor and workload Pods.

### 7. The supervisor establishes the control channel

The supervisor authenticates to the gateway with an identity bound to the
Kubernetes namespace, immutable Sandbox resource UID, supervisor Pod UID, and
OpenShell runtime generation. It then receives the effective policy and
runtime configuration.

Inside the workload, the sandbox runtime establishes filesystem, process,
socket, DNS, and network enforcement. The requested process cannot start until
the control path attaches and the runtime confirms that enforcement is active.

### 8. The sandbox becomes ready

After policy activation, the runtime starts the requested command or
interactive shell. The sandbox is now available for:

- SSH and exec sessions;
- log streaming;
- file upload and synchronization;
- port forwarding and exposed services;
- credential-provider mediation; and
- live network-policy updates.

User operations are relayed through the supervisor rather than exposing the
workload Pod directly.

## Policy Updates While Running

The demo begins with default-deny networking. It then uses `policy update` to
allow only `/usr/bin/curl` to make read-only REST requests to
`api.github.com:443`.

The gateway validates and stores the new policy generation, sends it through
the supervisor control channel, and waits for the sandbox to report that the
generation loaded. The workload does not restart. Requests outside the new
rule, such as a `POST`, remain denied and produce audit events.

## Stop, Start, and Delete

### Stop

Stopping a Kubernetes sandbox suspends its Agent Sandbox resource and removes
the active workload Pod while retaining the logical sandbox and its workspace
PVC. User files under `/sandbox` survive the stop.

### Start

Starting the sandbox creates a new runtime generation and replacement Pods.
OpenShell rebuilds and revalidates the boundary before releasing the workload.
The replacement workload mounts the existing workspace.

### Delete

Deletion is terminal:

1. the gateway transitions the durable sandbox record to `Deleting`;
2. the compute driver deletes the Agent Sandbox resource and runtime
   companions;
3. Kubernetes owner references remove dependent Pods, Services, Secrets,
   policies, and owned storage; and
4. the gateway removes its durable record after backend deletion is confirmed.

The automated demo installs an exit trap that deletes `policy-demo`, including
when the script fails or is interrupted.

## Failure and Rollback Behavior

Creation is fail-closed and uses compensating cleanup:

- validation failures occur before Kubernetes provisioning where possible;
- failure while creating supervisor companions rolls back the Sandbox custom
  resource;
- failure after backend creation triggers a driver deletion attempt;
- a durable `Deleting` record remains while asynchronous cleanup is pending;
  and
- the workload stays gated when bootstrap or boundary validation is
  incomplete.

This prevents a partially configured workload from being treated as a ready
sandbox.

## Observe the Lifecycle in This Demo

Run these watchers before starting `./scripts/demo.sh`:

```sh
# OpenShell API, driver, policy, and supervisor activity
./scripts/operations.sh --since 1m --follow

# Kubernetes Sandbox, Pod, PVC, scheduling, and policy events
./scripts/kubernetes-events.sh
```

For the underlying resources:

```sh
kubectl --context kind-openshell -n openshell get \
  sandboxes,pods,services,secrets,pvc,networkpolicies -w
```

The OpenShell timeline shows logical operations and control-channel state. The
Kubernetes event timeline shows how those operations materialize into cluster
resources.

## Related Files

- [`README.md`](README.md): setup and demo instructions
- [`scripts/demo.sh`](scripts/demo.sh): automated network-policy walkthrough
- [`config/openshell/policy.yaml`](config/openshell/policy.yaml): complete demo policy
- [`openshell-gateway-security-and-api.md`](openshell-gateway-security-and-api.md): gateway security and API notes

