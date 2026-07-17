# AUR 自动更新流水线

## 架构

```
.github/workflows/update.yml   单 job，装一次构建环境
scripts/precheck.sh            nvchecker 批量预检，过滤明显没变化的包
scripts/update-package.sh      单包：版本比对 -> makepkg -> 更新状态账本 -> 推 AUR
scripts/sync-all.sh            编排：发现包 -> 预检 -> 并发处理 -> 汇总 commit -> push -> 通知
.ci/state/<pkg>.json           每个包的状态账本（已发布的 pkgver/pkgrel）
.ci/state/nvchecker-old.json   nvchecker 预检缓存（跨次运行持久化，随 git 提交）
```

流程：

1. `find` 扫描所有含 `PKGBUILD` 的一级目录，得到包列表。
2. **预检**：把每个包目录下的 `.nvchecker.toml`（如果有）合并成一份配置，跑一次
   `nvchecker`，只留下"版本可能变化"的包进入下一步；没有 `.nvchecker.toml` 的包
   一律放行，不参与过滤，避免漏检。`force=true` 时整段跳过。
3. **并发处理**：`xargs -P 4` 对筛出来的包分别跑 `update-package.sh`：
   - 读 `.ci/state/<pkg>.json` 里记录的旧 `pkgver/pkgrel`
   - 跑 `pkgctl version upgrade`，跟新版本号比对，确认是否真的需要更新
   - 需要更新则生成 `.SRCINFO`、写状态账本、用独立的临时 `git --git-dir` 推送到 AUR
     （不碰 monorepo 的 `.git`，所以多个包并发跑这一步不会互相冲突）
4. **汇总**（串行）：逐包 `git add` + `git commit`（每包一条 commit message），
   全部完成后 `fetch/rebase/push` 一次。
5. **缓存回写**：只把「本次跑过且没失败」的包的 nvchecker 新版本号写回缓存；
   失败的包保留旧值，下次预检会重新把它识别为"有变化"，自动重试。
6. **失败通知**：有包处理失败时，`::error::` 标注 + 用 `gh issue` 开/更新一个
   汇总 issue（标题固定为 `AUR 自动更新失败`，避免每次都开新 issue）。

## 状态账本 schema

`.ci/state/<pkg>.json`：

```json
{
  "pkgver": "1.2.3",
  "pkgrel": "1",
  "pushed_at": "2026-07-17T08:00:00Z"
}
```

`.ci/state/nvchecker-old.json`：nvchecker 原生格式，`{ "<pkgbase>": "<version>" }`。

## 首次接入注意事项

仓库里还没有 `.ci/state/` 时，所有包的旧版本都是"未知"，第一次跑会被判定为
全部需要更新，从而触发一轮全量 `.SRCINFO` 重新生成和全量推 AUR（树对象比对会
让"内容其实没变"的包在推送阶段被跳过，所以不会产生垃圾 commit，但仍然会跑一遍
完整构建流程）。如果不想要这个副作用，可以提前手动生成 `.ci/state/<pkg>.json`，
把当前 PKGBUILD 里的 `pkgver/pkgrel` 填进去再提交。

## 本地测试

```bash
# 只测试单个包，跳过预检和版本比对
docker run --rm -it -v "$PWD:/repo" -w /repo archlinux:latest bash -c '
  pacman -Syu --noconfirm --needed base-devel git devtools nvchecker openssh jq
  chmod +x scripts/*.sh
  ./scripts/sync-all.sh some-package true
'
```

（本地测试如果没有配置 AUR SSH key，`update-package.sh` 里的推送步骤会失败，
可以先注释掉"推送到 AUR"那一段，只验证版本检测和 `.SRCINFO` 生成逻辑。）

## 已知取舍 / 可能需要按你仓库实际情况调整的地方

- 并发数 `xargs -P 4` 是经验值，AUR 对短时间内多次 SSH 连接可能有限速，包很多时
  建议调小。
- `.nvchecker.toml` 的 section 名假定与包目录内的 pkgbase 一一对应、全仓库不重名；
  如果有重名情况，合并配置那一步需要加前缀处理。
- 失败通知走 `gh issue`，依赖 `permissions.issues: write`；如果更想用 Slack/
  企业微信等 webhook，把 `sync-all.sh` 第 7 步换掉即可，其余逻辑不受影响。
- rebase 冲突时脚本直接失败退出，不做自动合并，需要人工介入——这是有意为之，
  自动解决 PKGBUILD 冲突风险更大。
