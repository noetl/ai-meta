playbook = """apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: gui_development_deploy
  path: automation/development/gui
  description: Build/load/deploy helpers for standalone GUI in local kind

executor:
  profile: local
  version: noetl-runtime/1

workload:
  action: help # build, load, deploy, redeploy, status
  registry: local
  image_name: gui
  gui_repo_dir: "../gui"
  expected_kube_context: "kind-noetl"

workflow:
  - step: run
    desc: Run selected action
    tool:
      kind: shell
      cmds:
        - |
          set -euo pipefail
          ACTION="{{ workload.action }}"
          GUI_REPO="{{ workload.gui_repo_dir }}"
          REGISTRY="{{ workload.registry }}"
          IMAGE_NAME="{{ workload.image_name }}"
          EXPECTED_CONTEXT="{{ workload.expected_kube_context }}"

          ensure_repo() {
            if [ ! -d "$GUI_REPO" ]; then
              echo "ERROR: GUI repository not found: $GUI_REPO"
              exit 1
            fi
          }

          ensure_kind_context() {
            CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
            if [ "$CURRENT_CONTEXT" = "none" ]; then
              echo "ERROR: No kubernetes context selected."
              echo "Set context to $EXPECTED_CONTEXT before deploy/status actions."
              exit 1
            fi
            if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
              echo "ERROR: Refusing to run local kind deploy against context '$CURRENT_CONTEXT'."
              echo "Expected context: '$EXPECTED_CONTEXT'"
              echo "Run: kubectl config use-context $EXPECTED_CONTEXT"
              exit 1
            fi
          }

          build() {
            ensure_repo
            IMAGE_TAG=$(date +%Y-%m-%d-%H-%M)
            echo "$IMAGE_TAG" > .gui_last_build_tag.txt
            docker buildx build --load --platform linux/amd64 \\
              -t "$REGISTRY/$IMAGE_NAME:$IMAGE_TAG" \\
              -f "$GUI_REPO/Dockerfile" "$GUI_REPO"
            echo "Built $REGISTRY/$IMAGE_NAME:$IMAGE_TAG"
          }

          load() {
            if [ ! -f .gui_last_build_tag.txt ]; then
              echo "ERROR: .gui_last_build_tag.txt not found. Run action=build first."
              exit 1
            fi
            IMAGE_TAG=$(cat .gui_last_build_tag.txt)
            echo "Loading $REGISTRY/$IMAGE_NAME:$IMAGE_TAG into kind cluster..."
            kind load docker-image "$REGISTRY/$IMAGE_NAME:$IMAGE_TAG" --name noetl
          }

          deploy() {
            ensure_kind_context
            if [ ! -f .gui_last_build_tag.txt ]; then
              echo "ERROR: .gui_last_build_tag.txt not found. Run action=build first."
              exit 1
            fi
            IMAGE_TAG=$(cat .gui_last_build_tag.txt)
            IMAGE="$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"
            for manifest in ci/manifests/gui/*.yaml; do
              if [ -f "$manifest" ]; then
                sed "s|image_name:image_tag|$IMAGE|g" "$manifest" | kubectl apply -f -
              fi
            done
            kubectl rollout restart deployment/gui -n noetl 2>/dev/null || true
            kubectl wait --for=condition=ready pod -l app=gui -n noetl --timeout=90s || true
          }

          status() {
            ensure_kind_context
            kubectl get pods -l app=gui -n noetl
            echo ""
            kubectl get svc gui -n noetl
          }

          case "$ACTION" in
            build)
              build
              ;;
            load)
              load
              ;;
            deploy)
              deploy
              ;;
            redeploy)
              build
              load
              deploy
              status
              ;;
            status)
              status
              ;;
            help|*)
              echo "Usage:"
              echo "  noetl run automation/development/gui.yaml --runtime local --set action=<action>"
              echo ""
              echo "Actions: build, load, deploy, redeploy, status"
              echo "Optional: --set gui_repo_dir=../gui"
              ;;
          esac
    next:
      - step: end

  - step: end
    desc: End workflow
    tool:
      kind: noop
"""
with open("repos/ops/automation/development/gui.yaml", "w") as f:
    f.write(playbook)
