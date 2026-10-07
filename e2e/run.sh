#!/usr/bin/env bash
# End-to-end test on Kind: stand up the registry's environments with Argo CD
# in graph order, check config resolution, sandbox routing over HTTP and NATS,
# Kargo promotion into staging, and sandbox teardown.
#
# Needs: docker, kind, kubectl, helm, jq, yq, go, git. Checkouts of the other
# repos go in $DEPS (default .e2e-deps/): platform, platform-chart, orders,
# payments, inventory, identity.
#
#   e2e/run.sh                 # everything
#   PHASES="checks" e2e/run.sh # re-run checks against an existing cluster
#   KEEP=1 e2e/run.sh          # leave the cluster up afterwards
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
DEPS=${DEPS:-$REPO/.e2e-deps}
CLUSTER=${CLUSTER:-registry-e2e}
PHASES=${PHASES:-"cluster addons images git bootstrap checks"}

ISTIO_VERSION=${ISTIO_VERSION:-1.31.1}
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.6.3}
ARGOCD_CHART_VERSION=${ARGOCD_CHART_VERSION:-10.9.6}
ESO_VERSION=${ESO_VERSION:-2.12.0}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.21.2}
KARGO_VERSION=${KARGO_VERSION:-1.12.2}

# The registry as the cluster sees it (fixed ClusterIP) and as the host pushes.
REG=10.96.200.200:5000
REG_PUSH=localhost:5001
GIT_PUSH=http://e2e:e2e-password@localhost:8081
GIT_IN=http://git.git.svc.cluster.local
SANDBOX=e2e
SERVICES=(identity inventory payments orders)
WORK=${WORK:-$REPO/.e2e-work}

log() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok() { printf '\033[32mok\033[0m   %s\n' "$*"; }
die() { printf '\033[31mFAIL\033[0m %s\n' "$*"; diagnose; exit 1; }
has_phase() { [[ " $PHASES " == *" $1 "* ]]; }

# wait_for DESCRIPTION TIMEOUT_SECONDS COMMAND...
wait_for() {
  local desc=$1 timeout=$2; shift 2
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS > end)); then die "timed out after ${timeout}s: $desc"; fi
    sleep 5
  done
  ok "$desc"
}

diagnose() {
  echo "--- diagnostics"
  kubectl get applications -A 2>/dev/null || true
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
  for a in $(kubectl -n argocd get applications -o name 2>/dev/null); do
    s=$(kubectl -n argocd get "$a" -o jsonpath='{.status.health.status}/{.status.sync.status}' 2>/dev/null)
    [[ $s == Healthy/Synced ]] || {
      echo "## $a $s"
      kubectl -n argocd get "$a" -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}' 2>/dev/null || true
    }
  done
  kubectl get externalsecrets,pushsecrets -A 2>/dev/null || true
  kubectl -n services get stages,warehouses,freight,promotions 2>/dev/null || true
}

app_ok() { [[ $(kubectl -n argocd get application "$1" -o jsonpath='{.status.health.status}/{.status.sync.status}') == Healthy/Synced ]]; }

# Run curl from inside the mesh; prints the response body.
mesh_curl() { kubectl -n e2e-client exec curl -- curl -sS --max-time 15 "$@"; }

phase_cluster() {
  log "kind cluster"
  if ! kind get clusters | grep -qx "$CLUSTER"; then
    kind create cluster --name "$CLUSTER" --config "$HERE/kind.yaml" --wait 120s
  fi
  kubectl config use-context "kind-$CLUSTER"
  # Point containerd at the in-cluster registry over plain HTTP.
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" sh -c "mkdir -p /etc/containerd/certs.d/$REG && printf '[host.\"http://$REG\"]\n  capabilities = [\"pull\", \"resolve\"]\n' > /etc/containerd/certs.d/$REG/hosts.toml"
  done
  kubectl apply -f "$HERE/manifests/registry.yaml"
  kubectl -n registry rollout status deploy/registry --timeout=180s
}

phase_addons() {
  log "Gateway API $GATEWAY_API_VERSION"
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"

  log "Istio $ISTIO_VERSION (ambient)"
  local istio=oci://ghcr.io/istio/release/charts
  helm upgrade --install istio-base "$istio/base" --version "$ISTIO_VERSION" -n istio-system --create-namespace --wait
  helm upgrade --install istiod "$istio/istiod" --version "$ISTIO_VERSION" -n istio-system --set profile=ambient --wait
  helm upgrade --install istio-cni "$istio/cni" --version "$ISTIO_VERSION" -n istio-system --set profile=ambient --wait
  helm upgrade --install ztunnel "$istio/ztunnel" --version "$ISTIO_VERSION" -n istio-system --wait

  log "cert-manager $CERT_MANAGER_VERSION (for Kargo)"
  helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version "$CERT_MANAGER_VERSION" \
    -n cert-manager --create-namespace --set crds.enabled=true --wait

  log "External Secrets $ESO_VERSION"
  helm upgrade --install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets --version "$ESO_VERSION" \
    -n external-secrets --create-namespace --wait
  kubectl apply -f "$HERE/manifests/secret-stores.yaml"

  log "Argo CD (chart $ARGOCD_CHART_VERSION)"
  helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd --version "$ARGOCD_CHART_VERSION" \
    -n argocd --create-namespace -f "$HERE/values/argocd.yaml" --wait

  log "Kargo $KARGO_VERSION"
  helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo --version "$KARGO_VERSION" \
    -n kargo --create-namespace -f "$HERE/values/kargo.yaml" --wait

  log "NATS per environment, sandbox gateway, mesh client"
  for env in dev staging; do sed "s/ENV/$env/g" "$HERE/manifests/nats.yaml" | kubectl apply -f -; done
  kubectl apply -f "$HERE/manifests/sandbox-gateway.yaml" -f "$HERE/manifests/client.yaml"
  for env in dev staging; do kubectl -n "nats-$env" rollout status sts/nats --timeout=180s; done
}

build_push() { # context, target-or-empty, image:tag...
  local ctx=$1 target=$2; shift 2
  local args=()
  [[ -n $target ]] && args+=(--target "$target")
  docker build -q "${args[@]}" -t "$REG_PUSH/$1" "$ctx" >/dev/null
  for t in "$@"; do
    docker tag "$REG_PUSH/$1" "$REG_PUSH/$t"
    docker push -q "$REG_PUSH/$t" >/dev/null
  done
}

phase_images() {
  log "images -> $REG"
  build_push "$DEPS/platform" svcreg svcreg:e2e
  build_push "$DEPS/platform" gitserver gitserver:e2e
  for svc in "${SERVICES[@]}"; do
    # 0.1.0 runs in dev (pinned by the service layer), pr-1 in the sandbox,
    # and 0.1.1 is the newest semver for Kargo to promote into staging.
    build_push "$DEPS/$svc" "" "$svc:0.1.0" "$svc:0.1.1" "$svc:pr-1"
    ok "$svc"
  done
}

# Prepare the e2e copy of the services repo: drop example sandboxes, add the
# e2e sandbox, and generate against the in-cluster git server and registry.
prepare_work() {
  rm -rf "$WORK" && mkdir -p "$WORK"
  git -C "$REPO" ls-files -z | (cd "$REPO" && xargs -0 tar cf -) | (cd "$WORK" && tar xf -)
  rm -f "$WORK"/sandboxes/*.yaml
  cat >"$WORK/sandboxes/$SANDBOX.yaml" <<EOF
name: $SANDBOX
owner: e2e
baseline: dev
ttl: 2h
services:
  - name: orders
    image: orders:pr-1
  - name: payments
    image: payments:pr-1
    values:
      config:
        featureFlags:
          refundsV2: true
EOF
  regenerate
}

regenerate() {
  (cd "$DEPS/platform" && go run ./cmd/svcreg generate --root "$WORK" \
    --git-url "$GIT_IN/services.git" --git-revision main \
    --chart-url "$GIT_IN/platform-chart.git" --chart-revision main \
    --image-registry "$REG" --tools-image "$REG/svcreg:e2e")
}

push_work() { # message
  git -C "$WORK" add -A
  git -C "$WORK" -c user.name=e2e -c user.email=e2e@example.com commit -qm "$1" || true
  git -C "$WORK" push -q "$GIT_PUSH/services.git" HEAD:main
}

phase_git() {
  log "git server"
  kubectl apply -f "$HERE/manifests/gitserver.yaml"
  kubectl -n git rollout status deploy/git --timeout=180s
  wait_for "git server reachable from the host" 60 curl -sf http://localhost:8081/healthz

  local chart_work; chart_work=$(mktemp -d)
  cp -r "$DEPS/platform-chart/." "$chart_work/" && rm -rf "$chart_work/.git"
  git -C "$chart_work" init -q -b main && git -C "$chart_work" add -A
  git -C "$chart_work" -c user.name=e2e -c user.email=e2e@example.com commit -qm "platform-chart for e2e"
  git -C "$chart_work" push -qf "$GIT_PUSH/platform-chart.git" HEAD:main
  ok "platform-chart pushed"

  prepare_work
  git -C "$WORK" init -q -b main
  push_work "services registry for e2e"
  ok "services pushed"
  # Kargo-delivered environments stand up from seeded stage branches.
  "$REPO/scripts/seed-stage-branches.sh" "$WORK" "$GIT_PUSH/services.git"
}

phase_bootstrap() {
  log "bootstrap"
  # Kargo adopts a pre-created, labelled namespace; its git credentials must
  # exist before the first promotion.
  kubectl create namespace services --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace services kargo.akuity.io/project=true --overwrite
  kubectl -n services create secret generic services-git \
    --from-literal=repoURL="$GIT_IN/services.git" --from-literal=username=e2e --from-literal=password=e2e-password \
    --dry-run=client -o yaml | kubectl label --local -f - kargo.akuity.io/cred-type=git -o yaml | kubectl apply -f -
  sed "s|https://github.com/mcafeelabs/services|$GIT_IN/services.git|" "$REPO/bootstrap/registry.yaml" | kubectl apply -f -
}

check_standup() {
  log "stand-up: dev comes up in graph order"
  wait_for "registry app synced" 300 app_ok registry
  for svc in "${SERVICES[@]}"; do wait_for "dev-$svc Healthy/Synced" 900 app_ok "dev-$svc"; done
  wait_for "env-dev root app Healthy" 300 app_ok env-dev
  local ts=()
  for svc in identity payments orders; do
    ts+=("$(kubectl -n argocd get application "dev-$svc" -o jsonpath='{.metadata.creationTimestamp}')")
  done
  [[ ${ts[0]} < "${ts[1]}" && ${ts[1]} < "${ts[2]}" ]] || die "waves out of order: identity=${ts[0]} payments=${ts[1]} orders=${ts[2]}"
  ok "waves: identity (${ts[0]}) < payments (${ts[1]}) < orders (${ts[2]})"
}

check_config() {
  log "config: secrets, KV and dynamic outputs resolved by ESO"
  local out
  wait_for "orders reached its database" 300 sh -c "kubectl -n e2e-client exec curl -- curl -sS -X POST http://orders.dev/orders | jq -e '.orderId > 0'"
  out=$(mesh_curl -X POST http://orders.dev/orders)
  jq -e '.paymentsKeyLoaded == true' <<<"$out" >/dev/null || die "orders: \$secret not loaded: $out"
  jq -e '.checkoutV2 == "true"' <<<"$out" >/dev/null || die "orders: \$kv not loaded: $out"
  jq -e '.payment.identity.signingKeyLoaded == true' <<<"$out" >/dev/null || die "identity: \$secret not loaded: $out"
  ok "\$secret, \$kv and \$output (postgres via PushSecret) resolved"
}

check_routing() {
  log "sandbox routing over HTTP"
  wait_for "sandbox apps Healthy" 600 sh -c "for s in orders payments; do kubectl -n argocd get application sbx-$SANDBOX-\$s -o jsonpath='{.status.health.status}' | grep -qx Healthy || exit 1; done"
  wait_for "sandbox routing app synced" 300 app_ok "sbx-$SANDBOX-routing"
  local out
  out=$(mesh_curl -X POST http://orders.dev/orders)
  jq -e '.sandbox == "" and .payment.sandbox == "" and .payment.identity.sandbox == "" and .payment.refundsV2 == false' <<<"$out" >/dev/null \
    || die "untagged request left the baseline: $out"
  ok "untagged: orders, payments, identity all baseline"

  wait_for "tagged request reaches the sandbox" 180 sh -c \
    "kubectl -n e2e-client exec curl -- curl -sS -X POST -H 'baggage: sandbox=$SANDBOX' http://orders.dev/orders | jq -e '.sandbox == \"$SANDBOX\"'"
  out=$(mesh_curl -X POST -H "baggage: sandbox=$SANDBOX" http://orders.dev/orders)
  jq -e --arg s "$SANDBOX" '.sandbox == $s and .payment.sandbox == $s and .payment.refundsV2 == true and .payment.identity.sandbox == "" and .payment.identity.requestSandbox == $s' <<<"$out" >/dev/null \
    || die "tagged request misrouted: $out"
  ok "tagged: orders + payments in sandbox (refundsV2 from layer 5), identity on baseline with baggage intact"
  jq -e '.orderId > 0' <<<"$out" >/dev/null || die "sandbox orders has no isolated database: $out"
  ok "sandbox orders writes to its own (isolated) database"

  out=$(mesh_curl -X POST -H "Host: $SANDBOX.sbx.dev.localdev.test" http://sandbox-istio.istio-ingress/orders)
  jq -e --arg s "$SANDBOX" '.sandbox == $s and .payment.sandbox == $s' <<<"$out" >/dev/null || die "gateway did not tag the request: $out"
  ok "gateway: $SANDBOX.sbx.dev.localdev.test sets the baggage"
}

events() { mesh_curl "$1" | jq --arg sku "$2" '[.events[] | select(.data.sku == $sku)] | length'; }

check_nats() {
  log "sandbox routing over NATS"
  local sku_t="tagged-$RANDOM" sku_u="untagged-$RANDOM"
  wait_for "inventory connected to NATS" 180 sh -c "kubectl -n e2e-client exec curl -- curl -sf -X POST 'http://inventory.dev/restock?sku=warmup'"
  mesh_curl -X POST -H "baggage: sandbox=$SANDBOX" "http://inventory.dev/restock?sku=$sku_t" >/dev/null
  mesh_curl -X POST "http://inventory.dev/restock?sku=$sku_u" >/dev/null
  sleep 5
  local sb_t sb_u base_t base_u
  sb_t=$(events "http://orders.sbx-$SANDBOX/events" "$sku_t")
  sb_u=$(events "http://orders.sbx-$SANDBOX/events" "$sku_u")
  base_t=$(events http://orders.dev/events "$sku_t")
  base_u=$(events http://orders.dev/events "$sku_u")
  [[ $sb_t == 1 && $sb_u == 0 && $base_t == 0 && $base_u == 1 ]] \
    || die "NATS routing: sandbox got tagged=$sb_t untagged=$sb_u, baseline got tagged=$base_t untagged=$base_u"
  ok "tagged stock.changed went only to the sandbox copy, untagged only to baseline"
}

check_kargo() {
  log "Kargo: staging promoted from Freight"
  wait_for "staging-orders runs the newest semver (0.1.1)" 900 sh -c \
    "kubectl -n staging get deploy orders -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q ':0.1.1$'"
  for svc in "${SERVICES[@]}"; do wait_for "staging-$svc Healthy/Synced" 600 app_ok "staging-$svc"; done
  jq -e '.replicas == 2' <(kubectl -n staging get deploy orders -o json | jq '{replicas: .spec.replicas}') >/dev/null \
    || die "staging layer 4 (orders replicas: 2) not applied"
  ok "layer 4 (service x environment) applied in staging"

  build_push "$DEPS/orders" "" orders:0.1.2
  kubectl -n services annotate warehouse orders kargo.akuity.io/refresh="$(date +%s)" --overwrite
  wait_for "new image 0.1.2 promoted to staging" 600 sh -c \
    "kubectl -n staging get deploy orders -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q ':0.1.2$'"
  kubectl -n staging get deploy orders -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q "^$REG/orders:" || die "wrong repository"
  ok "promotion wrote stage/staging/orders and Argo CD synced it"
}

check_teardown() {
  log "sandbox teardown"
  rm -f "$WORK/sandboxes/$SANDBOX.yaml"
  regenerate
  push_work "remove sandbox $SANDBOX"
  for a in sandbox-routing sandbox-services; do
    kubectl -n argocd annotate applicationset "$a" argocd.argoproj.io/application-set-refresh=true --overwrite
  done
  wait_for "sandbox namespace removed" 600 sh -c "! kubectl get namespace sbx-$SANDBOX"
  wait_for "baseline HTTPRoutes removed" 120 sh -c "[ -z \"\$(kubectl -n dev get httproutes -o name)\" ]"
  wait_for "tagged requests fall back to baseline" 180 sh -c \
    "kubectl -n e2e-client exec curl -- curl -sS -X POST -H 'baggage: sandbox=$SANDBOX' http://orders.dev/orders | jq -e '.sandbox == \"\" and .requestSandbox == \"$SANDBOX\"'"
}

phase_checks() {
  check_standup
  check_config
  check_routing
  check_nats
  check_kargo
  check_teardown
  log "all checks passed"
}

for p in cluster addons images git bootstrap checks; do
  if has_phase "$p"; then "phase_$p"; fi
done
if [[ -z ${KEEP:-} && $PHASES == *checks* ]]; then
  log "deleting cluster (KEEP=1 to keep it)"
  kind delete cluster --name "$CLUSTER"
fi
