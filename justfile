# AUR 自动更新流水线 - 本地开发/调试命令
#
# 用法: just <recipe>，不带参数运行 `just` 会列出所有可用命令。
# 需要 https://github.com/casey/just
#
# 大部分命令实际执行是在一个一次性的 archlinux:latest 容器里跑的，
# 因为脚本依赖 pacman / pkgctl / makepkg / nvchecker，本地非 Arch 系统跑不了。

image := "archlinux:latest"
deps := "base-devel git devtools nvchecker openssh jq github-cli"

# 默认命令：列出所有 recipe
default:
    @just --list

# 对所有脚本做一次语法检查（不依赖容器，本地 bash 就行）
lint:
    bash -n scripts/sync-all.sh
    bash -n scripts/precheck.sh
    bash -n scripts/update-package.sh
    @echo "语法检查通过"

# 如果本机装了 shellcheck，再跑一遍静态检查（可选，失败不阻断）
shellcheck:
    @command -v shellcheck >/dev/null 2>&1 && \
        shellcheck scripts/*.sh || \
        echo "未安装 shellcheck，跳过（brew/apt/pacman install shellcheck）"

# 在容器里装好依赖后打开一个交互 shell，方便手动调试
shell:
    docker run --rm -it \
        -v "$(pwd):/repo" -w /repo \
        {{ image }} bash -c "pacman -Syu --noconfirm --needed {{ deps }} && chmod +x scripts/*.sh && bash"

# 只跑 nvchecker 批量预检，看看哪些包会被判定为"可能有更新"
precheck:
    docker run --rm \
        -v "$(pwd):/repo" -w /repo \
        {{ image }} bash -c "\
            pacman -Syu --noconfirm --needed base-devel devtools nvchecker jq >/dev/null && \
            chmod +x scripts/*.sh && \
            find . -maxdepth 2 -name PKGBUILD -exec dirname {} \\; | sed 's|^\\./||' \
                | ./scripts/precheck.sh .ci/state"

# 处理单个包，跳过预检和版本比对（force），不做 AUR 推送/不做 git push，只验证构建逻辑
dry-run pkg:
    docker run --rm \
        -v "$(pwd):/repo" -w /repo \
        {{ image }} bash -c "\
            pacman -Syu --noconfirm --needed {{ deps }} >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            mkdir -p /tmp/status && \
            AUR_DRY_RUN=1 ./scripts/update-package.sh {{ pkg }} /tmp/status true"

# 处理单个包的完整流程（含推 AUR），需要把私钥挂进容器
sync-one pkg:
    docker run --rm \
        -v "$(pwd):/repo" -w /repo \
        -v "${AUR_SSH_KEY_PATH:?请先设置 AUR_SSH_KEY_PATH 环境变量指向私钥文件}:/root/.ssh/aur_key:ro" \
        -e "GIT_SSH_COMMAND=ssh -i /root/.ssh/aur_key -o StrictHostKeyChecking=accept-new" \
        {{ image }} bash -c "\
            pacman -Syu --noconfirm --needed {{ deps }} openssh >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            ./scripts/sync-all.sh {{ pkg }} false"

# 强制处理单个包（跳过预检和版本比对），走完整流程含推送
force-one pkg:
    docker run --rm \
        -v "$(pwd):/repo" -w /repo \
        -v "${AUR_SSH_KEY_PATH:?请先设置 AUR_SSH_KEY_PATH 环境变量指向私钥文件}:/root/.ssh/aur_key:ro" \
        -e "GIT_SSH_COMMAND=ssh -i /root/.ssh/aur_key -o StrictHostKeyChecking=accept-new" \
        {{ image }} bash -c "\
            pacman -Syu --noconfirm --needed {{ deps }} openssh >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            ./scripts/sync-all.sh {{ pkg }} true"

# 处理仓库里所有包的完整流程（跟 workflow 里跑的命令一致），需要挂私钥
sync-all:
    docker run --rm \
        -v "$(pwd):/repo" -w /repo \
        -v "${AUR_SSH_KEY_PATH:?请先设置 AUR_SSH_KEY_PATH 环境变量指向私钥文件}:/root/.ssh/aur_key:ro" \
        -e "GIT_SSH_COMMAND=ssh -i /root/.ssh/aur_key -o StrictHostKeyChecking=accept-new" \
        {{ image }} bash -c "\
            pacman -Syu --noconfirm --needed {{ deps }} openssh >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            ./scripts/sync-all.sh '' false"

# 给新包生成一份 .nvchecker.toml 骨架（source 需要你手动改成实际值）
new-nvchecker pkg source="github":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{ pkg }}"
    cat > "{{ pkg }}/.nvchecker.toml" <<EOF
    [{{ pkg }}]
    source = "{{ source }}"
    # github 示例: github = "owner/repo"
    # aur 示例:    aur = "{{ pkg }}"
    # pypi 示例:   pypi = "{{ pkg }}"
    EOF
    echo "已生成 {{ pkg }}/.nvchecker.toml，请按需要填写具体字段"

# 清理本地运行产生的临时文件（不会动 .ci/state，那是要提交的状态账本）
clean:
    rm -rf /tmp/status .ci/state/nvchecker-new.json .ci/state/nvchecker-combined.toml
    @echo "已清理临时文件"
