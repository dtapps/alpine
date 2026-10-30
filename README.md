# Alpine 基础镜像

[![定时构建](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/alpine/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/alpine/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/alpine/-/security) ![基础镜像](https://img.shields.io/badge/base-alpine-0d597f?logo=alpinelinux&logoColor=white) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![时区](https://img.shields.io/badge/timezone-Asia%2FShanghai-success) ![镜像大小](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_size) ![arm64 大小](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_digest_short)

自建 Alpine 基础镜像仓库。镜像由 CNB 流水线自动构建并推送到制品库，供其它项目作为基础镜像或调试容器使用。

完整文档在 [`docs/`](docs/README.md)：快速上手、Dockerfile 解析、APK 源、构建、CI 流水线、标签契约、构建元数据、安全基线、维护与排错。这里只做一页速查。

## 镜像里有什么

- 基础镜像：`alpine:${ALPINE_VERSION}`，默认 `latest`
- APK 源替换为多个国内镜像（cernet → 腾讯云 → 阿里云 → 火山 → 官方）依次回退，国内拉包不必直连 `dl-cdn.alpinelinux.org`
- 预装常用工具：`ca-certificates`（HTTPS）、`curl`（调接口）、`netcat-openbsd`（`nc -zv host port` 探端口）、`bind-tools`（`nslookup` / `dig`）、`tzdata`
- 时区固定为 `Asia/Shanghai`（`/etc/localtime` 与 `/etc/timezone` 均已写入）
- 构建末尾清理 `/var/cache/apk`、`/tmp`、`/root/.cache`，保持体积最小

Dockerfile 位于 `.cnb/docker/Dockerfile`。

## 镜像地址与标签

镜像地址：`docker.cnb.cool/dtapp/alpine`

同一份构建会产出两组标签：

- 多架构（amd64 + arm64 的 manifest list）
  - `latest`
  - `<version>` —— 仅在手动输入版本号时生成，例如 `3.20`
- 单架构（只含对应平台条目的镜像，供不便处理多架构 manifest list 的场景使用）
  - `latest-linux-amd64`、`latest-linux-arm64`
  - `<version>-linux-amd64`、`<version>-linux-arm64`

注意 `latest-linux-amd64` 这类标签只承诺**单平台**：它就是这个架构，不用挑。buildx 默认附带 attestation，所以它在制品库里仍是一个 index（只有一个平台的镜像清单，外加 attestation 条目），`docker manifest inspect` 看到索引而非单份清单属于预期行为，不影响按该标签拉取。

## 拉取与使用

```bash
# 拉取并进入容器
docker pull docker.cnb.cool/dtapp/alpine:latest
docker run --rm -it docker.cnb.cool/dtapp/alpine:latest sh

# 需要特定 Alpine 版本时
docker pull docker.cnb.cool/dtapp/alpine:3.20
```

作为其它镜像的基础镜像：

```dockerfile
FROM docker.cnb.cool/dtapp/alpine:latest
```

## 触发构建

两种方式，产物一致：

- 手动：仓库页面 → 流水线 → 点击「打包 Docker 镜像（多架构 amd64 + arm64）」按钮，`version` 可留空（按 `latest` 处理），也可填 `3.20` 这类已存在于 Docker Hub 的 alpine tag
- 定时：每天 `00:05`（Asia/Shanghai）自动构建一次 `latest`，用于跟随上游 Alpine 更新

单条流水线内用 `docker buildx` 一次构建 amd64 + arm64 并 `--push`，多架构 manifest list 由 buildx 直接产出，不存在「先构建、再等两条都完成、最后合并清单」的时序问题，因此也不需要额外的合并任务。

相关配置：

- `.cnb/workflows/build-image.yml` —— 手动按钮触发的流水线（事件名 `web_trigger_build_image`）
- `.cnb/web_trigger.yml` —— 按钮名称、权限与 `version` 输入项
- `.cnb.yml` —— `include` 列表与定时任务
- `.cnb/scripts/build-image.sh` —— 实际执行的构建与推送命令

`version` 的处理规则（见脚本开头）：去掉空白与不可打印字符，为空则回落为 `latest`。

## 构建产物元数据

构建成功后脚本会把本次产物信息写到 `.cnb/annotation.json`，再由 `cnbcool/annotations` 插件写入当前 commit 的元数据：

| key                  | 内容                                             | 来源                               |
|----------------------|--------------------------------------------------|------------------------------------|
| `image_digest`       | `sha256:...` 完整摘要                            | `docker buildx imagetools inspect` |
| `image_digest_short` | 前 12 位，供徽章展示                             | 同上                               |
| `image_size`         | amd64 单平台压缩后体积（config + 各 layer 合计） | 同上                               |
| `image_size_arm64`   | arm64 单平台压缩后体积（算法同上）               | 同上                               |
| `built_at`           | UTC 构建时间                                     | `date -u`                          |

体积按平台分别统计：多架构 manifest list 本身没有「总拉取体积」，`docker pull` 只会拉取宿主机对应架构的层，所以两个架构各记一个值才有意义。同一份 Dockerfile 下两者通常只差几个百分点，但空跑一次只查 amd64 会漏掉 arm64 基础包体积异常的情况。

读取方式：

- 页面：仓库 → Commit 列表 → 对应提交 → 元数据（只读）
- 徽章：`https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/{key}`，未写入过的 key 显示灰色 `unknown`

这样「某次提交对应哪个镜像」可反查。注意元数据只挂在 commit 上，重跑同一提交会覆盖同名 key。

## 生成 Code Wiki

文档由 `cnbcool/codewiki` 生成，产物落在 `${CNB_BUILD_WORKSPACE}/${CNB_REPO_SLUG}/codewiki` 并入库知识库。

触发方式：

- 手动：流水线 → 「生成 Code Wiki」按钮，随时可按需重建
- 打 tag（`git push --tags`）时自动触发

之所以保留手动入口：本仓库不发版、日常不打 tag，只靠 `tag_push` 等于永不生成。两段流水线内容一致（`.cnb/workflows/codewiki.yml` 里的 `web_trigger_codewiki` 与 `tag_push`），改生成参数需同步两处。

## 本地构建

```bash
# 单架构，构建完留在本地
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=3.20 -t alpine:local .

# 多架构
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .cnb/docker/Dockerfile -t alpine:local .
```

多平台产物无法 `--load` 进本地 docker，需要 `--push` 推到仓库，或用 `--output type=oci,dest=out.tar` 落成 tar。

## 改完配置后跑格式化

YAML、Markdown、Shell、Dockerfile 四类文件统一由 `make format` 处理：

```bash
make format          # 全部
make format-yaml     # 仅 YAML（.cnb 目录与 .cnb.yml）
make format-markdown # 仅 Markdown
make format-shell    # 仅 .cnb/scripts 下的 shell
make format-docker   # 仅 .cnb 下的 Dockerfile
```

需要本机已安装 `yamlfmt`、`markdownfmt`、`shfmt`、`dockerfmt`（Homebrew 或 `go install`，例如 `mvdan.cc/sh/v3/cmd/shfmt@latest`、`github.com/google/yamlfmt/cmd/yamlfmt@latest`）。

YAML 的格式化规则在 `.yamlfmt`（缩进 2 空格、保留空行、引号统一单引号），Shell 规则为 `shfmt -i 2 -ci -bn -s -ln bash`。

## 安全扫描

- `.scanignore` —— 对所有扫描能力生效的排除清单（gitignore 语义，`!` 前缀为重新纳入）。当前只排除 `.cnb/bug.png`、`.cnb/hi.gif` 两个二进制资源，其余配置与脚本刻意不排除，以便发现「误把密钥写进 `env`」这类改动。
- `.cnb/security/code_scan_config.yml` —— 通过 `ignoreFrom: .scanignore` 引用上述文件。

## 目录结构

```text
.
├── .cnb.yml                 # 流水线入口：include 各 workflow + 定时任务
├── Makefile                 # make format
├── .yamlfmt                 # yamlfmt 规则
├── .scanignore              # 安全扫描排除清单
├── LICENSE                  # MIT
├── CONTRIBUTING.md          # 贡献流程与硬性规则
├── SECURITY.md              # 漏洞报告渠道与已知取舍
├── docs/                    # 分册文档，索引见 docs/README.md
└── .cnb/
    ├── docker/Dockerfile    # 镜像定义
    ├── scripts/             # 流水线脚本
    ├── workflows/           # 各触发事件的流水线
    ├── security/            # 安全扫描配置
    ├── settings.yml         # 仓库界面（issue 按钮图等）
    └── web_trigger.yml      # 自定义按钮
```

## 常见问题

- 构建报基础镜像拉取失败：`version` 必须与 Docker Hub 上真实存在的 alpine tag 一致，例如 `3.20`、`3.21`；写成不存在的版本会在 `FROM` 阶段直接失败。
- 定时任务只产出 `latest`：它固定传 `version=latest`，不会打版本标签；需要版本标签请手动点按钮并填 `version`。
- 改完 `.cnb/workflows/**` 记得同步 `include` 与 `web_trigger.yml` 里的事件名，否则按钮可能指向一个不存在的事件。

## 许可与贡献

- 许可证：[MIT](LICENSE)
- 文档索引：[docs/README.md](docs/README.md)
- 贡献流程与硬性规则：[CONTRIBUTING.md](CONTRIBUTING.md)
- 漏洞报告渠道、已知取舍：[SECURITY.md](SECURITY.md)
