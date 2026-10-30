# Alpine 基础镜像

[![定时构建](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab)](https://cnb.cool/dtapp/alpine/-/pipeline) [![流水线配置](https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/pipeline-as-code)](https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml) [![漏洞扫描](https://cnb.cool/dtapp/alpine/-/badge/security/vulnerability/full/latest)](https://cnb.cool/dtapp/alpine/-/security) ![基础镜像](https://img.shields.io/badge/base-alpine-0d597f?logo=alpinelinux&logoColor=white) ![架构](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-informational) ![时区](https://img.shields.io/badge/timezone-Asia%2FShanghai-success) ![镜像大小](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_size) ![arm64 大小](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_size_arm64) ![镜像摘要](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_digest_short) ![镜像版本](https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_version)

自建 Alpine 基础镜像仓库。镜像由 CNB 流水线自动构建并推送到制品库，供其它项目作为基础镜像或调试容器使用。

完整文档在 [`docs/`](docs/README.md)：快速上手、Dockerfile 解析、APK 源、构建、CI 流水线、标签契约、构建元数据、安全基线、维护与排错。这里只做一页速查。

## 镜像里有什么

- 基础镜像：`alpine:latest`。基座刻意跟随上游最新稳定版，定时任务每天重建就自动带上新补丁甚至新小版本；具体是哪个版本由流水线解析后写进标签与元数据（如 `3.25.1`），所以「跟随最新」与「事后可追溯」可以同时成立（追溯靠元数据里的 digest，不靠标签留档）
- APK 源替换为四个镜像（cernet → 腾讯云 → 阿里云 → 官方）依次回退，且只保留 `main`：本层所有包都在 `main`， `community` 索引约 2.4 MiB，默认白拉
- 预装工具：`ca-certificates`（HTTPS 校验）、`curl`（调接口）、`drill`（`dig` 的轻量替代，做 DNS 排查）、 `netcat-openbsd`（`nc -zv host port` 探端口）、`tzdata`
- 时区与本地化：`ENV TZ=Asia/Shanghai`、`LANG`/`LC_ALL=C.UTF-8`，同时落盘 `/etc/localtime` 与 `/etc/timezone`。 只设 `TZ` 不够，musl 的时区解析仍依赖 `tzdata` 提供的 zoneinfo
- 单层 `RUN` 完成「换源 → 装包 → 写时区 → 清缓存」：清理必须与安装同层，跨层 `rm` 只产生 whiteout， 旧层数据照样随镜像分发
- 九个 OCI 标签：`source`、`url`（本镜像所在的 CNB 仓库）、`revision`、`created`、`version`、`description`、 `licenses`、`base.name`、`base.digest`。注意 `base.name` 按 OCI 规范指**基座镜像**（`alpine:latest`）， 本镜像自己的存放位置是 `source`/`url`，不是 Docker Hub
- 不设 `ENTRYPOINT`/`CMD`/`WORKDIR`：基础镜像设了会被所有下游继承，等于替下游做决定

Dockerfile 位于 `.cnb/docker/Dockerfile`。

## 镜像地址与标签

镜像地址：`docker.cnb.cool/dtapp/alpine`

标签分三层：只有版本标签是构建产物，其余都由它派生或提升，因此同一批标签的 digest 天然一致。**标签就是 alpine 的版本号，不带日期。**

| 标签                 | 何时产生                              | 内容                                               |
|----------------------|---------------------------------------|----------------------------------------------------|
| `3.25.1`             | 每次构建只推这一个                    | amd64 + arm64 的 manifest list，同名标签每天被覆盖 |
| `3.25.1-linux-amd64` | 构建成功后由 `imagetools create` 派生 | amd64 单平台内容，digest 与 index 条目相同         |
| `3.25.1-linux-arm64` | 同上                                  | arm64 单平台内容，digest 与 index 条目相同         |
| `3.25`               | 冒烟测试通过后提升                    | 滚动 minor，指向最近一次成功的 `3.25.x` 构建       |
| `latest`             | 冒烟测试通过后最后提升                | 指向最近一次成功的构建                             |

版本标签的名字就是解析出来的 `ALPINE_REAL`，即构建时从 `/etc/alpine-release` 读到的实际版本（如 `3.25.1`）。几个关键点：

- `latest` 只会出现在拉取侧与 `FROM` 里，**永远不会进入标签名**：版本号解析失败时构建直接中止，不会带着不知道版本的基座继续
- **同名标签每天被覆盖是刻意的**：alpine 的版本号就是产品的版本号，再叠日期只会让下游不知道该固定哪一个。代价是「昨天那份」没有标签可指，要固定某一次构建只能按 digest 拉取
- `3.25.1-linux-*` 同样每天被覆盖，它只解决「只认单平台标签的工具」，不承担留档职责
- `-linux-*`、`latest`、`3.25` 都不是「再构建一次」：脚本用 `docker buildx imagetools create` 把已有清单挂到新名字上，digest 完全相同，不存在「同名标签内容差一点」的可能
- `latest` 与 `3.25` 只在冒烟测试通过后提升。六项断言覆盖：`/etc/alpine-release` 前缀等于解析出的版本、`/etc/timezone` 为 `Asia/Shanghai`、`date +%z` 为 `+0800`、`/etc/apk/repositories` 恰好 4 行、`curl`/`drill`/`nc`/`nslookup` 四个命令可执行、OCI 标签 `version` 等于本次版本标签名。任一项失败脚本 `exit 1`，`3.25` 与 `latest` 停在原地（版本标签此时已指向那份坏产物，但按这两个标签拉的人不受影响）
- `latest` 与 `3.25` 是「最近一次成功构建」的指针，会被覆盖；要锁死某个产物只能按 digest 拉取，细节见 [镜像与标签](docs/images-and-tags.md)

## 拉取与使用

```bash
# 拉取并进入容器
docker pull docker.cnb.cool/dtapp/alpine:latest
docker run --rm -it docker.cnb.cool/dtapp/alpine:latest sh

# 需要可复现：按 digest 拉「那一次构建」的那一份（digest 取自 commit 元数据）
docker pull docker.cnb.cool/dtapp/alpine@sha256:<image_digest>

# 只需要某个 minor 的最近一次成功构建
docker pull docker.cnb.cool/dtapp/alpine:3.25
```

作为其它镜像的基础镜像：

```dockerfile
FROM docker.cnb.cool/dtapp/alpine:latest
```

## 触发构建

两种方式，产物一致：

- 手动：仓库页面 → 流水线 → 点击「打包 Docker 镜像（多架构 amd64 + arm64）」按钮。`version` 可留空（等价于 `latest`，跟随上游），也可填 `3.25`、`3.25.1` 或 `3.25.1@sha256:<64 位 hex>`
- 定时：每天 `00:05`（Asia/Shanghai）不传 `version`，走 `Dockerfile` 默认的 `alpine:latest`，自动跟随上游补丁与小版本

一次 `docker buildx build --platform linux/amd64,linux/arm64 --push` 直接产出多架构 manifest list， 单平台标签与 `latest` 都是在这之后用 `imagetools create` 从版本标签派生的，不存在「先构建、再等两条都完成、 最后合并清单」的时序问题，也不需要额外的合并任务。构建刻意不带 registry 缓存：镜像只有一层，缓存一旦命中 就不会再执行 `apk add`，每天的重建也就装不到新包了；每次多跑几秒「4 个索引 + 5 个包」，换来的是「重建 = 刷新依赖」。

相关配置：

- `.cnb/workflows/build-image.yml` —— 手动按钮触发的流水线（事件名 `web_trigger_build_image`）
- `.cnb/web_trigger.yml` —— 按钮名称、权限与 `version` 输入项
- `.cnb.yml` —— `include` 列表与定时任务
- `.cnb/scripts/build-image.sh` —— 实际执行的构建、派生、冒烟与提升逻辑

`version` 的处理规则（见脚本开头）：留空或 `latest` = 跟随上游；`3.25` = 跟随该分支补丁；`3.25.1` = 钉死 patch；`3.25.1@sha256:<64 位 hex>` = 位级复现。其它输入（`v3.25`、`3.25/`、超长串等）一律打印原因并 `exit 1`。白名单比「清洗掉危险字符」可靠：它同时保证 `FROM` 引用不被注入，并把「跟随最新 / 跟随分支 / 钉死 / 位级复现」变成四种显式输入。

## 构建产物元数据

构建成功后脚本会把本次产物信息写到 `.cnb/annotation.json`，再由 `cnbcool/annotations` 插件写入当前 commit 的元数据：

| key                  | 内容                                             | 来源                                      |
|----------------------|--------------------------------------------------|-------------------------------------------|
| `image_version`      | 本次版本标签名，如 `3.25.1`                      | 解析出的 `ALPINE_REAL`                    |
| `alpine_version`     | 解析出的基座实际版本，如 `3.25.1`                | 一次性容器里 `cat /etc/alpine-release`    |
| `base_image`         | 构建时用的基座引用，默认 `alpine:latest`         | `FROM` 用的那个值，`alpine:${ALPINE_REF}` |
| `base_digest`        | 当时 `alpine:latest` 的 index digest             | `imagetools inspect alpine:${ALPINE_REF}` |
| `image_digest`       | `sha256:...` 完整摘要（本次构建的 index）        | `docker buildx imagetools inspect`        |
| `image_digest_short` | 前 12 位，供徽章展示                             | 同上                                      |
| `image_size`         | amd64 单平台压缩后体积（config + 各 layer 合计） | 同上                                      |
| `image_size_arm64`   | arm64 单平台压缩后体积（算法同上）               | 同上                                      |
| `built_at`           | 本次实际构建时刻（UTC）                          | `date -u +%Y-%m-%dT%H:%M:%SZ`             |
| `source_date`        | git 提交时间，用于镜像的 `created` 标签          | `git log -1 --format=%cI`                 |

体积按平台分别统计：多架构 manifest list 本身没有「总拉取体积」，`docker pull` 只会拉取宿主机对应架构的层， 所以两个架构各记一个值才有意义。同一份 Dockerfile 下两者通常只差几个百分点，但空跑一次只查 amd64 会漏掉 arm64 基础包体积异常的情况。

`built_at` 只是「本次运行发生在什么时候」，写进镜像的 OCI `created` 标签用的是 `source_date`（提交时间）；两者分开记，才不会为了可复现把「这次构建是什么时候跑的」这条信息丢掉。基座是浮动的最新稳定版、标签又每天被覆盖，所以可复现的唯一落点是 `image_digest`：`docker pull <镜像>@sha256:<digest>`。`built_at` 记录这次构建发生在什么时候，`alpine_version` 与 `base_digest` 记录它当时吃的是哪个基座。

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
# 单架构，构建完留在本地；不传 build-arg 时基座就是 alpine:latest
docker build -f .cnb/docker/Dockerfile -t alpine:local .

# 钉死某个基座版本（排查「是不是上游换版本引起的」）
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=3.25.1 -t alpine:local .

# 跟随 3.25 分支的补丁（同一个 tag 的产出会随上游漂移）
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=3.25 -t alpine:local .

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
├── .dockerignore            # 构建上下文排除清单（.git、docs、*.md 等）
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

- 构建报基础镜像拉取失败：`version` 必须是 Docker Hub 上真实存在的 alpine tag，例如 `latest`、`3.25`、`3.25.1`；写成不存在的版本会在 `FROM` 阶段直接失败。格式不对（`v3.25`、`3.25/`）会更早一步被脚本的白名单拦下。
- 「解析不到基座版本」：脚本会起一次性容器读 `/etc/alpine-release`，读不到通常是 Runner 拉不到 `alpine:latest` 或网络有问题，先按[故障排查](docs/troubleshooting.md)确认出网。
- 定时任务产出当次版本标签（如 `3.25.1`）与提升后的 `latest`/`3.25`：它不传 `version`，走 `Dockerfile` 默认的 `alpine:latest`，所以上游发新 patch 时标签版本号会跟着变。
- 标签不带日期、同名会被覆盖，所以没有「保留窗口」要维护；要留档就把 `image_digest` 记进发布记录，见[维护手册](docs/maintenance.md)。
- 改完 `.cnb/workflows/**` 记得同步 `include` 与 `web_trigger.yml` 里的事件名，否则按钮可能指向一个不存在的事件。

## 许可与贡献

- 许可证：[MIT](LICENSE)
- 文档索引：[docs/README.md](docs/README.md)
- 贡献流程与硬性规则：[CONTRIBUTING.md](CONTRIBUTING.md)
- 漏洞报告渠道、已知取舍：[SECURITY.md](SECURITY.md)
