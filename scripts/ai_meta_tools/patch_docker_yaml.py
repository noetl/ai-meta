import re
filepath = "repos/ops/automation/development/docker.yaml"
with open(filepath, "r") as f:
    content = f.read()

# Add gui_repo_dir
content = re.sub(r'NOETL_REPO="\{\{ workload\.noetl_repo_dir \}\}"', 'NOETL_REPO="{{ workload.noetl_repo_dir }}"\n          GUI_REPO="{{ workload.gui_repo_dir }}"', content)

# Add build-gui action
gui_build_action = """
            build-gui)
              if [ ! -d "$GUI_REPO" ]; then
                echo "ERROR: GUI repository not found: $GUI_REPO"
                exit 1
              fi
              IMAGE_TAG=$(date +%Y-%m-%d-%H-%M)
              docker build -t "local/gui:$IMAGE_TAG" -f "$GUI_REPO/Dockerfile" "$GUI_REPO"
              echo "$IMAGE_TAG" > .gui_last_build_tag.txt
              echo "Built local/gui:$IMAGE_TAG"
              ;;
"""
content = re.sub(r'(build\)\n[\s\S]*?;;\n)', r'\1' + gui_build_action, content)

# Add help text
content = re.sub(r'echo "  build              Build NoETL image"', 'echo "  build              Build NoETL image"\n              echo "  build-gui          Build GUI image"', content)

with open(filepath, "w") as f:
    f.write(content)
