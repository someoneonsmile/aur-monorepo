# AUR Monorepo

多 AUR 包的 monorepo，每个子目录对应一个 AUR 包。

## 目录结构

```
aur/
├── .github/workflows/update.yml   # CI 自动更新流水线
├── go2tv-bin/                     # AUR 包目录
│   ├── PKGBUILD
│   ├── .SRCINFO
│   └── .nvchecker.toml            # nvchecker 上游版本检查配置
└── <新包>/                        # 新增包照此结构
    ├── PKGBUILD
    ├── .SRCINFO
    └── .nvchecker.toml
```

## 包目录规范

每个 AUR 包目录必须包含：

- `PKGBUILD` — Arch Linux 包构建定义
- `.SRCINFO` — 由 `makepkg --printsrcinfo` 生成
- `.nvchecker.toml` — nvchecker 配置，定义上游版本检查源

## 添加新包

1. 在仓库根目录下创建包目录（与包名同名）
2. 添加 `PKGBUILD`、`.SRCINFO`、`.nvchecker.toml`
3. 工作流会自动扫描仓库根目录下包含 `PKGBUILD` 的包目录，无需手动修改 CI 配置
4. 在 GitHub 仓库 Settings → Secrets 中确保 `AUR_SSH_PRIVATE_KEY` 已配置

## CI 工作流

- **触发**: 每 6 小时（`0 */6 * * *`）+ 手动触发（`workflow_dispatch`）
- **容器**: `update` 与 `commit` 任务均使用 `archlinux:latest`
- **流程**: `pkgctl version upgrade` → `makepkg --printsrcinfo`
- **推送**: 变更自动 push 到 monorepo（main 分支）和 AUR 远程仓库

## 依赖

| Secret                | 说明                       |
| --------------------- | -------------------------- |
| `AUR_SSH_PRIVATE_KEY` | 用于推送 AUR 包的 SSH 私钥 |
