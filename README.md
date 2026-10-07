# services

The service registry. Each service declares what it provides and consumes in
a manifest. CI publishes that manifest here, and `svcreg` turns the repo into
everything Argo CD and Kargo read:

- the deployment graph;
- validated config for every environment and sandbox;
- one app-of-apps per environment, synced in dependency order;
- sandbox routing;
- Kargo Warehouses and Stages.

This is a proof of concept of the *Service Registry, Config & Sandbox
Platform* design. The rest of it lives in:

| Repo | Role |
|---|---|
| [platform](https://github.com/mcafeelabs/platform) | `svcreg`, the sandbox propagation library, `servicekit` |
| [platform-chart](https://github.com/mcafeelabs/platform-chart) | The central Helm chart and `capabilities.yaml` |
| [orders](https://github.com/mcafeelabs/orders), [payments](https://github.com/mcafeelabs/payments), [inventory](https://github.com/mcafeelabs/inventory), [identity](https://github.com/mcafeelabs/identity) | Demo services; each owns its `service.yaml` and publishes it here |

## Layout

```
registry.yaml                         git, chart, image registry, Argo CD, Kargo settings
platform/capabilities.yaml            vendored from platform-chart (CI checks it)
_global/values.yaml                   layer 1   platform team
environments/<env>/values.yaml        layer 2   platform team
services/<svc>/service.yaml           published by the service's CI
services/<svc>/config-values.schema.yaml
services/<svc>/values.yaml            layer 3   service team
services/<svc>/environments/<env>/values.yaml   layer 4   service team
sandboxes/<name>.yaml                 layer 5   sandbox owner
rendered/<env>/<svc>/values.yaml      generated
rendered/sbx/<name>/<svc>/values.yaml generated
apps/<env>/                           generated: namespace, waypoint, sandbox index, kv-sync, Applications
apps/_sandboxes/<name>/               generated: sandbox namespace, quota, ReferenceGrant, HTTPRoutes
apps/_platform/                       generated: ApplicationSets, Kargo Project/Warehouses/Stages
bootstrap/registry.yaml               apply once per Argo CD
e2e/                                  Kind end-to-end test
```

## The demo graph

```
$ svcreg graph
wave 0  identity
wave 0  inventory
wave 1  payments             identity
wave 2  orders               identity, inventory, payments
```

`orders` follows the design doc's example. It provides `api`, `events-queue`
(isolated), `db` (postgres, isolated) and `orders.created`. It consumes
`payments/api` and `inventory/stock.changed`, and has an ordering-only edge on
`identity`.

## Day-to-day

```sh
go install github.com/mcafeelabs/platform/cmd/svcreg@main

svcreg validate                         # everything CI checks
svcreg effective-config orders dev      # resolved config
svcreg effective-config payments dev --sandbox ryan-checkout-v2
svcreg dependents identity
svcreg generate                         # CI does this after merge
```

### Config

Config is five layers merged with Helm semantics (later wins, maps
deep-merge, `null` deletes). The result is validated against the service's
schema in every environment, then resolved:

```yaml
config:
  payments:
    url: {$output: payments/api}                     # -> http://payments.dev.svc.cluster.local
    apiKey: {$secret: aws-sm://orders/payments-api-key}
  database:
    password: {$output: orders/db#password}          # dynamic: -> $kv to /services/dev/orders/db
  featureFlags:
    checkoutV2: {$kv: ssm://orders/flags/checkout-v2}
```

Each environment maps provider names (`aws-sm`, `ssm`) to its own
`ClusterSecretStore` under `platform.secretStores`. The chart then renders a
single ExternalSecret per service. The demo environments point at local
stand-ins (ESO's Kubernetes provider); an AWS account would use Secrets
Manager and Parameter Store with `keyStyle: path`.

### Sandboxes

Add a file and merge it:

```yaml
# sandboxes/ryan-checkout-v2.yaml
name: ryan-checkout-v2
owner: ryan
baseline: dev
ttl: 72h
services:
  - name: orders
    image: orders:pr-1          # service CI pushes pr-<n> images
  - name: payments
    image: payments:pr-1
    values:
      config:
        featureFlags:
          refundsV2: true
```

This creates:

- namespace `sbx-ryan-checkout-v2`, holding only `orders` and `payments`;
- one HTTPRoute per overridden service, attached to the baseline Service, that
  sends requests with `baggage: sandbox=ryan-checkout-v2` to the sandbox copy;
- an ingress route at `ryan-checkout-v2.sbx.dev.localdev.test` that sets the
  baggage header;
- an entry in the `sandboxes` NATS KV bucket, so baseline consumers skip that
  sandbox's messages for `orders` and `payments`.

Isolated resources (`orders/db`, `orders/events-queue`) get their own copy in
the sandbox; everything else resolves to `dev`. The `sandbox-expire` workflow
deletes the file when the TTL runs out (the TTL counts from the commit that
added the file, or from `created:`).

### Delivery

- **dev** (`delivery: direct`) syncs `rendered/dev` from `main`. A new
  environment of this kind stands up from the repo alone. Each Application's
  sync wave is its graph depth, and the Application health check in
  `argocd-cm` makes the waves wait.
- **staging** (`delivery: kargo`) reads `stage/staging/<svc>` branches. Each
  service's Warehouse subscribes to its image and to its
  `rendered/staging/<svc>` path. Its Stage uses only built-in steps: copy the
  rendered values, set the image tag from the Freight, commit, push, then
  `argocd-update`. `scripts/seed-stage-branches.sh` creates missing stage
  branches so a new Kargo environment can also stand up from the repo.

## CI

| Workflow | What it does |
|---|---|
| `ci` | Checks that the capabilities copy matches the chart, runs `svcreg validate`, puts the graph and a generated-output diff in the PR summary, and runs kubeconform on generated manifests. After a merge to main, commits `rendered/` and `apps/`. |
| `e2e` | Runs the whole thing on Kind: Argo CD, Istio ambient, ESO, NATS, Kargo, cert-manager (see below). |
| `sandbox-expire` | Hourly: removes expired sandboxes and regenerates. |

### What e2e checks

1. dev stands up in wave order (identity < payments < orders).
2. ESO resolves `$secret`, `$kv`, and a dynamic `$output`. The postgres
   connection is pushed with a PushSecret and read back through the outputs
   store.
3. Untagged requests stay on baseline. With `baggage: sandbox=e2e`, the
   request reaches the sandbox `orders` and `payments` (`refundsV2` comes from
   layer 5) and the baseline `identity`, with the baggage intact. The ingress
   host sets the baggage.
4. NATS: a tagged `stock.changed` reaches only the sandbox `orders`; an
   untagged one reaches only the baseline.
5. Kargo promotes the newest semver into staging. A new image is promoted
   after a Warehouse refresh. The service × environment layer (2 replicas) is
   applied.
6. Removing the sandbox file removes its namespace and routes, and tagged
   requests fall back to baseline.

## Not in this POC

- Crossplane compositions. The chart emits `PostgresInstance` and `Queue`
  claims when `provisioner: crossplane`. Local environments use an in-cluster
  postgres and a queue stub instead.
- Terragrunt and the account bootstrap. Environments here are namespaces on
  one cluster; NATS runs once per environment.
- Wildcard certificates and DNS for `*.sbx.<env domain>`, and Karpenter. The
  chart supports a sandbox node pool (`platform.sandbox.nodePool`), but it is
  off by default.
- Per-Freight schema validation (schema and image skew).
- Real code-owner teams. The `CODEOWNERS` teams are placeholders.
