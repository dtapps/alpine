# 排错手册

> 按症状查：先在总表里定位到主题与对应文档，再跳到本册对应小节复制命令；每条都给出原因、可执行处置和延伸阅读。

## 症状总表

| 症状                               | 可能原因                                          | 处置                                   | 对应文档                             |
|------------------------------------|---------------------------------------------------|----------------------------------------|--------------------------------------|
| `FROM` 阶段拉不到基础镜像          | `version` 填了不存在的 tag、或到上游网络不通      | 换真实存在的 tag，用 `latest` 对照网络 | [构建](build.md)                     |
| `apk update` 超时或 404            | 新 minor 的 `vX.Y` 路径镜像站未同步、源站故障     | 确认路径推导值，等同步或退回官方源     | [APK 源与网络](mirrors.md)           |
| buildx 报 bootstrap 失败           | 自建了 `docker-container` builder                 | 删掉自建 builder，用 CNB 内置 builder  | [构建](build.md)                     |
| push 返回 401 / 403                | token 缺失或过期 / 无该仓库写权限                 | 核对 `imports` 与 registry 地址        | [CI 流水线](ci-pipeline.md)          |
| 元数据里 digest 是 `unknown`       | 取不到 manifest digest，或元数据步骤没跑          | 手动 `imagetools inspect` 复核         | [构建元数据](metadata-and-badges.md) |
| 徽章灰色或显示 `unknown`           | key 拼错、annotation 未写入、看错 commit          | 对照五个 key 与写入步骤                | [构建元数据](metadata-and-badges.md) |
| 体积显示 `unknown`                 | 取到的清单里没有 `layers` 字段（拿到的是 index）  | 先按平台清单 digest 再取 `--raw`       | [构建元数据](metadata-and-badges.md) |
| 单平台标签里也有 index             | 预期行为：buildx 默认附带 attestation             | 无需处理，别按 index 直接求体积        | [镜像与标签](images-and-tags.md)     |
| 容器内时间是 UTC                   | 时区未生效，`/etc/localtime` 被覆盖或删了 tzdata  | 检查时区文件与 `TZ` 变量               | [Dockerfile 解析](dockerfile.md)     |
| `make format` 报 command not found | 本机缺四个格式化工具之一                          | 按工具链文档安装                       | [格式化](formatting.md)              |
| 页面没有构建按钮 / 点了不触发      | 按钮 `event` 与 workflow 触发键不一致或未 include | 三处事件名对齐                         | [CI 流水线](ci-pipeline.md)          |
| PR 被 SCA 拦住                     | `failOnSeverity: high` 命中 high 及以上漏洞       | 升级包或确认误报，不要关掉门禁         | [安全基线](security-baseline.md)     |

## 构建阶段

### `FROM` 拉取失败

原因只有两类：`version` 不是 Docker Hub 上真实存在的 alpine tag；或 Runner 到 Docker Hub 的网络不通。先区分：

```bash
# 1) 目标 tag 是否存在
docker buildx imagetools inspect alpine:3.20
# 2) 用 latest 对照：latest 也失败说明是网络问题
docker buildx imagetools inspect alpine:latest
```

处置：`version` 填 `3.20`、`3.21`、`3.20.3` 这类真实标签，不要写成 `v3.20`。定时任务的 `latest` 固定从 `FROM alpine:latest` 取，若它连续失败而手动构建成功，问题在 Runner 出网而不是版本号。

### `apk update` 超时或 404

源路径不是手写的，而是从镜像内 `/etc/alpine-release` 推导出的 `vX.Y`：

```bash
docker run --rm alpine:3.21 sh -c 'cat /etc/alpine-release; cat /etc/apk/repositories'
```

看到 `vX.Y` 与报错 URL 里的路径不一致，说明基础镜像的版本与源路径推导对不上（例如手动改了 `repositories`）。只剩 404 而路径一致，是镜像站尚未同步该 minor：`apk update` 会按 cernet → 腾讯云 → 阿里云 → 火山 → 官方 的顺序继续尝试，最后两行就是官方源兜底。处置是等镜像站同步，不要为了绕开 404 把源顺序改成「官方优先」——那会把国内构建速度一起赔进去。

### buildx bootstrap 失败

不要自建 builder。CNB 的 `services: docker` 默认已内置可做多架构的 buildx builder：

```bash
docker buildx version
docker buildx ls
docker buildx inspect
```

`build-image.sh` 在三次构建之前就跑这三条自检。若在受限容器里执行过 `docker buildx create --driver docker-container`，会因拉不起嵌套 buildkitd 而 bootstrap 失败：删掉该 builder，回到内置的实例，同时确认 workflow 里声明了 `services: docker`。

## 推送与制品库

### push 401 / 403

401 是认证失败，403 是认证通过但没有目标仓库的写权限。

```bash
# 变量是否注入（imports 引入的环境变量）
printf '%s\n' "${CNB_DOCKER_REGISTRY}" "${CNB_TOKEN_USER_NAME}"
# 手动复现登录（本地复现请换自己 fork 的地址）
docker login -u "${CNB_TOKEN_USER_NAME}" -p "${CNB_TOKEN}" "${CNB_DOCKER_REGISTRY}"
```

凭证来自 `imports` 里引入的组织密钥仓库，仓库内没有任何字面量。缺变量通常是 `imports` 那一行被删或路径写错；能登录但 403 则是账号对该仓库没有推送权限。不要拿线上路径 `docker.cnb.cool/dtapp/alpine` 做实验性推送。

### manifest list 与单平台标签的误解

| 标签                                          | 承诺的平台范围 | `docker manifest inspect` 看到的内容     |
|-----------------------------------------------|----------------|------------------------------------------|
| `latest`、`<version>`                         | amd64 + arm64  | 含两个平台条目的 manifest list           |
| `latest-linux-amd64`、`<version>-linux-arm64` | 单一平台       | 仍是 index，但里面只有一个平台的镜像清单 |

```bash
docker manifest inspect docker.cnb.cool/dtapp/alpine:latest | head -20
docker manifest inspect docker.cnb.cool/dtapp/alpine:latest-linux-amd64 | head -20
```

第二行输出的同样是索引：buildx 默认附带 attestation，单平台推送出来的对象里只有一个平台的镜像清单加一个 attestation 条目，不会有 amd64 / arm64 两个平台。这是设计预期，不是「多架构合并失败」——把它当故障排查是常见误判；真正要小心的是按这个 index 直接求体积，会得到几 KB 的假值（见下文「体积显示 `unknown`」）。

### digest 缺失

构建成功但元数据里 `image_digest` 是 `unknown`：脚本先取 `imagetools inspect` 文本输出里的 `Digest:` 行，取不到再退回 `--format` 模板，两者都空才写 `unknown`。

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest --format '{{.Manifest.Digest}}'
```

无输出的常见原因是推送步骤并未真正完成（前面的 `buildx build --push` 非零退出但后续步骤仍在跑），或者该 tag 在制品库里尚未可读。先确认三步构建的退出码，再重复上面的命令。

## 元数据与徽章

### 徽章灰色或 `unknown`

三个原因按概率排：

1. annotation 步骤没执行。构建在某一步 `exit 1`，写入元数据的 `cnbcool/annotations` 阶段根本没跑。
2. key 拼写不一致。可写入的 key 只有 `image_digest`、`image_digest_short`、`image_size`、`image_size_arm64`、`built_at`。
3. 看的是另一条 commit。徽章里的 `latest` 指默认分支最近一次构建，不是「最近一次手动构建」。

```bash
# 核对脚本真正写出的 key
grep -n 'image_\|built_at' .cnb/scripts/build-image.sh | tail -8
```

### 体积显示 `unknown`

体积是按单平台镜像清单里的层求和，多架构 index 没有可加总的「总拉取体积」。脚本内部若取到的不是镜像清单，会返回 `-1` 并打一行警告，写成元数据时回落成 `unknown`。

先确认取到的是什么。直接对单平台标签取 `--raw`，通常拿到的是 index（没有 `layers` 字段）：

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest-linux-amd64 --raw | head -5
```

正确做法是从多架构 index 里取出该平台镜像清单的 digest，再对 digest 取原文：

```bash
PLATFORM_DIGEST=$(docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest --format \
  '{{range .Manifest.Manifests}}{{if and (eq .Platform.OS "linux") (eq .Platform.Architecture "amd64")}}{{.Digest}}{{end}}{{end}}')
docker buildx imagetools inspect "docker.cnb.cool/dtapp/alpine@${PLATFORM_DIGEST}" --raw | head -5
```

输出里有 `layers` 就说明取对了；没有、或求和小于 1MB（正常 Alpine 镜像不可能这么小），再去检查单平台标签是否推送成功。

## 容器内

### 时区不对

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest sh -c 'date; cat /etc/timezone; ls -l /etc/localtime'
```

期望 `date` 显示 `CST`、`/etc/timezone` 为 `Asia/Shanghai`、`/etc/localtime` 指向 `/usr/share/zoneinfo/Asia/Shanghai`。派生镜像里常见三种破坏方式：删了 `tzdata`、覆盖了 `/etc/localtime`、在 `docker run` 时传了别的 `TZ`。基础镜像本身没问题的话，先查派生镜像的清理步骤。

### 格式化工具缺失

```bash
command -v yamlfmt markdownfmt shfmt dockerfmt
brew install shfmt yamlfmt markdownfmt dockerfmt
```

缺哪个装哪个；`shfmt` 与 `yamlfmt` 也可以 `go install`，具体来源见 [格式化](formatting.md)。注意 `markdownfmt` 与 `dockerfmt` 没有 `--version` 参数，用 `command -v` 判断是否存在即可。

## 按钮与事件

### 按钮不存在或点了没反应

按钮定义与流水线监听是两处配置，靠事件名逐字对上：

```bash
grep -n 'event:' .cnb/web_trigger.yml
grep -rn 'web_trigger_' .cnb/workflows/ .cnb.yml
```

当前可用的事件名是 `web_trigger_build_image` 与 `web_trigger_codewiki`。三处必须联动：workflow 里的触发键、`.cnb/web_trigger.yml` 的 `event`、`.cnb.yml` 的 `include` 列表。漏掉 `include` 时按钮存在但没人监听，表现为点下去没有任何构建记录。

## PR 门禁

### PR 被 SCA 拦住

`.cnb/workflows/sca.yml` 的 `pull_request.target` 给漏洞扫描与 License 扫描都设了 `failOnSeverity: high`，high 及以上即让流水线失败。这是唯一的硬门禁，先确认拦你的是哪一类：

```bash
# 本次改动是否碰了包的声明
git diff --stat -- .cnb/docker/Dockerfile
```

处置分三种：升级到已修复版本（换包或换基础 `version`）；确认是上游尚未修复的 CVE，那它不该在这个 PR 里解决，按 [安全基线](security-baseline.md) 的链条等上游；确认是误报后再动扫描配置。不要为了过门禁注释掉 `failOnSeverity`——push 侧的全量报告会失去对照基线。

### AI 评审只评论不阻断

`fail_on_critical: false` 是刻意设置：评审输出建议，阻断权在 SCA。想让它更安静就调 `exclude_categories` 或 `min_severity`，不要靠忽略评论来「通过」检查。

## 相关文档

- [CI 流水线](ci-pipeline.md)
- [构建](build.md)
- [构建元数据](metadata-and-badges.md)
- [维护手册](maintenance.md)
