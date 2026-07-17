# AUR 自动更新流水线 - 本地开发/调试命令
#
# 用法: just <recipe>，不带参数运行 `just` 会列出所有可用命令（按分组展示）。
# 需要 https://github.com/casey/just >= 1.17（用到了 [confirm] 属性）
#
# ---- 国内网络加速 ----
# 默认给容器里的 pacman 换成清华源，两种方式二选一：
#
#   1) 用别的国内源（不改文件，临时覆盖）：
#        PACMAN_MIRROR='https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch' just sync-all
#      常见可选：
#        中科大  https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
#        阿里云  https://mirrors.aliyun.com/archlinux/$repo/os/$arch
#        清华    https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch（默认）
#
#   2) 直接复用宿主机已有的 mirrorlist 文件，挂载优先级高于上面的 PACMAN_MIRROR：
#        LOCAL_MIRRORLIST=/etc/pacman.d/mirrorlist just sync-all
#
# 也可以把这些环境变量写进项目根目录的 .env 文件（已开启 dotenv-load，
# 会自动加载，不用每次手动 export），比如：
#   PACMAN_MIRROR='https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch'
#   AUR_SSH_KEY_PATH=/home/you/.ssh/aur_ed25519
# 记得把 .env 加进 .gitignore，里面可能有私钥路径这类本机专属信息。
#
# 注意：PACMAN_MIRROR 里的 $repo / $arch 要用单引号包住再传，
# 避免被你自己的 shell 提前展开成空字符串。

set dotenv-load

image := "archlinux:latest"
deps := "base-devel git devtools nvchecker openssh jq github-cli"

mirror := env_var_or_default("PACMAN_MIRROR", "https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch")
local_mirrorlist := env_var_or_default("LOCAL_MIRRORLIST", "")

# 把 mirror 里的 $repo/$arch 转义成 \$repo/\$arch，
# 这样嵌进 docker ... bash -c "..." 这个双引号字符串时，
# 才不会被宿主机的 shell 提前当成（不存在的）变量展开成空。
mirror_escaped := replace(replace(mirror, "$repo", "\\$repo"), "$arch", "\\$arch")

# 有 LOCAL_MIRRORLIST 就挂载它，没有就是空字符串（docker run 里多一个空参数无害）
mirror_mount := if local_mirrorlist != "" { "-v " + local_mirrorlist + ":/etc/pacman.d/mirrorlist:ro" } else { "" }

# 有 LOCAL_MIRRORLIST 时跳过写文件（挂载的是只读文件，写了也会失败）；
# 否则在 pacman -Syu 之前先把镜像源写进 mirrorlist。
mirror_setup := if local_mirrorlist != "" { "" } else { "echo 'Server = " + mirror_escaped + "' > /etc/pacman.d/mirrorlist && " }

# 默认命令：列出所有 recipe
default:
    @just --list

[doc('对所有脚本做一次语法检查（不依赖容器，本地 bash 就行）')]
[group('调试')]
lint:
    bash -n scripts/sync-all.sh
    bash -n scripts/precheck.sh
    bash -n scripts/update-package.sh
    @echo "语法检查通过"

[doc('如果本机装了 shellcheck，再跑一遍静态检查（可选，失败不阻断）')]
[group('调试')]
shellcheck:
    @command -v shellcheck >/dev/null 2>&1 && \
        shellcheck scripts/*.sh || \
        echo "未安装 shellcheck，跳过（brew/apt/pacman install shellcheck）"

[doc('在容器里装好依赖后打开一个交互 shell，方便手动调试')]
[group('调试')]
shell:
    docker run --rm -it \
        {{ mirror_mount }} \
        -v "$(pwd):/repo" -w /repo \
        {{ image }} bash -c "{{ mirror_setup }} pacman -Syu --noconfirm --needed {{ deps }} && chmod +x scripts/*.sh && bash"

[doc('只跑 nvchecker 批量预检，看看哪些包会被判定为"可能有更新"')]
[group('调试')]
precheck:
    docker run --rm \
        {{ mirror_mount }} \
        -v "$(pwd):/repo" -w /repo \
        {{ image }} bash -c "\
            {{ mirror_setup }} pacman -Syu --noconfirm --needed base-devel devtools nvchecker jq >/dev/null && \
            chmod +x scripts/*.sh && \
            find . -maxdepth 2 -name PKGBUILD -exec dirname {} \\; | sed 's|^\\./||' \
                | ./scripts/precheck.sh .ci/state"

[doc('处理单个包，跳过预检和版本比对，不推 AUR/不 git push，只验证构建逻辑')]
[group('调试')]
dry-run pkg:
    docker run --rm \
        {{ mirror_mount }} \
        -v "$(pwd):/repo" -w /repo \
        {{ image }} bash -c "\
            {{ mirror_setup }} pacman -Syu --noconfirm --needed {{ deps }} >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            mkdir -p /tmp/status && \
            DRY_RUN=1 ./scripts/update-package.sh {{ pkg }} /tmp/status true"

[doc('全量 dry-run：完整流程但不推 AUR、不 push、不开 issue')]
[group('调试')]
dry-run-all:
    docker run --rm \
        {{ mirror_mount }} \
        -v "$(pwd):/repo" -w /repo \
        -e DRY_RUN=1 \
        {{ image }} bash -c "\
            {{ mirror_setup }} pacman -Syu --noconfirm --needed {{ deps }} >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            ./scripts/sync-all.sh '' false"

[confirm('这会实际推送到 AUR（该包）并 push 到 origin/main，确定继续吗？')]
[doc('处理单个包的完整流程（含推 AUR），需要把私钥挂进容器')]
[group('生产')]
sync-one pkg:
    docker run --rm \
        {{ mirror_mount }} \
        -v "$(pwd):/repo" -w /repo \
        -v "${AUR_SSH_KEY_PATH:?请先设置 AUR_SSH_KEY_PATH 环境变量指向私钥文件}:/root/.ssh/aur_key:ro" \
        -e "GIT_SSH_COMMAND=ssh -i /root/.ssh/aur_key -o StrictHostKeyChecking=accept-new" \
        {{ image }} bash -c "\
            {{ mirror_setup }} pacman -Syu --noconfirm --needed {{ deps }} openssh >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            ./scripts/sync-all.sh {{ pkg }} false"

[confirm('force 会跳过版本比对，强制重新生成并推送该包，确定继续吗？')]
[doc('强制处理单个包（跳过预检和版本比对），走完整流程含推送')]
[group('生产')]
force-one pkg:
    docker run --rm \
        {{ mirror_mount }} \
        -v "$(pwd):/repo" -w /repo \
        -v "${AUR_SSH_KEY_PATH:?请先设置 AUR_SSH_KEY_PATH 环境变量指向私钥文件}:/root/.ssh/aur_key:ro" \
        -e "GIT_SSH_COMMAND=ssh -i /root/.ssh/aur_key -o StrictHostKeyChecking=accept-new" \
        {{ image }} bash -c "\
            {{ mirror_setup }} pacman -Syu --noconfirm --needed {{ deps }} openssh >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            ./scripts/sync-all.sh {{ pkg }} true"

[confirm('这会处理仓库里所有包，可能推送多个包到 AUR 并 push main，确定继续吗？')]
[doc('处理仓库里所有包的完整流程（跟 workflow 里跑的命令一致），需要挂私钥')]
[group('生产')]
sync-all:
    docker run --rm \
        {{ mirror_mount }} \
        -v "$(pwd):/repo" -w /repo \
        -v "${AUR_SSH_KEY_PATH:?请先设置 AUR_SSH_KEY_PATH 环境变量指向私钥文件}:/root/.ssh/aur_key:ro" \
        -e "GIT_SSH_COMMAND=ssh -i /root/.ssh/aur_key -o StrictHostKeyChecking=accept-new" \
        {{ image }} bash -c "\
            {{ mirror_setup }} pacman -Syu --noconfirm --needed {{ deps }} openssh >/dev/null && \
            chmod +x scripts/*.sh && \
            git config --global --add safe.directory /repo && \
            ./scripts/sync-all.sh '' false"

[doc('给新包生成一份 .nvchecker.toml 骨架（source 需要你手动改成实际值）')]
[group('维护')]
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

[doc('清理本地运行产生的临时文件（不会动 .ci/state，那是要提交的状态账本）')]
[group('维护')]
clean:
    rm -rf /tmp/status .ci/state/nvchecker-new.json .ci/state/nvchecker-combined.toml
    @echo "已清理临时文件"
