# 构建元数据与徽章

> 每次构建把版本名、两层 digest（本镜像与基座）、APK 索引指纹、两个平台的体积、两个时间戳写成当前 commit 的元数据，README 徽章从这批 key 取值；这里讲生成链路、十二个 key 的语义，以及 `unknown` 是怎么出现的。

## 链路

```text
build-alpine.sh
  ├─ 解析基座                      一次性容器读 /etc/alpine-release → ALPINE_REAL（如 3.25.1）
  ├─ 记录基座 digest               imagetools inspect alpine:latest → BASE_DIGEST
  ├─ 构建 + 派生 + 冒烟 + 提升     产出 ${STAMP}（版本标签）、-linux-{amd64,arm64}、latest、${MINOR}
  ├─ docker buildx imagetools inspect  取 ${STAMP} 的 digest
  ├─ 逐平台取镜像清单 --raw        取 layers（+ config）体积
  └─ heredoc 写 .cnb/annotation.json
          │
          ▼
stages 第二步：image: cnbcool/annotations:latest
  settings: type: ADD / fromJsonFile: .cnb/annotation.json
          │
          ▼
当前 commit 的元数据  ←  /-/badge/annotation/commit/latest/{key}
```

元数据挂在 commit 而不是 tag：本仓库不发版、日常不打 tag，构建只由 push 与定时任务产生，commit 是唯一稳定的关联点。这样「某次提交对应哪个镜像」可以直接反查。

基座刻意浮动（`FROM alpine:latest`），所以元数据里必须同时记下「解析出的版本」与「当时的基座 digest」：前者给人看（`3.25.1`），后者给机器用（`sha256:...`，可以反查是 Docker Hub 上的哪一份）。只记其中一个，几个月后都没法回答「这次构建到底吃了什么」。

`base_digest` 与 `version` 的关系值得先说清：`version` 只有 `latest` / `3.25` / `3.25.1` / `3.25.1@sha256:<64hex>` 四种取值，所以 `base_digest` 既可能是「当天 latest 的 digest」（前三种），也可能**正好等于传进来的那个 digest**（第四种，`docker run` 与 `FROM` 拉的是同一份）。后者是预期，不是重复记录。

## cnbcool/annotations 的两行设置

```yaml
- name: 写入镜像元数据
  image: cnbcool/annotations:latest
  settings:
    type: ADD
    fromJsonFile: .cnb/annotation.json
```

`type: ADD` 表示新增或覆盖 key，`fromJsonFile` 指向脚本写出的扁平 JSON。插件对输入有限制：key 只允许 `0-9a-zA-Z_-`，value 不允许含换行，所以脚本只输出一层、单行的值。

## 生成的 JSON

```json
{
  "image_digest": "sha256:...",
  "image_digest_short": "前 12 位",
  "image_version": "3.25.1",
  "alpine_version": "3.25.1",
  "base_image": "alpine:latest",
  "base_digest": "sha256:...",
  "apk_index_digest": "9f2c…",
  "cache": "on",
  "image_size": "12.3MB",
  "image_size_arm64": "12.1MB",
  "built_at": "2026-10-30T08:53:44Z",
  "source_date": "2026-10-30T16:12:00+08:00"
}
```

| key                  | 语义                                  | 来源                                                                      |
|----------------------|---------------------------------------|---------------------------------------------------------------------------|
| `image_digest`       | 本次构建的 index 摘要                 | `imagetools inspect ${IMAGE}:${STAMP} --format '{{.Manifest.Digest}}'`    |
| `image_digest_short` | 去掉 `sha256:` 后的前 12 位           | 上面的 digest，只用于徽章                                                 |
| `image_version`      | 本次构建的版本标签名                  | 解析出的 `ALPINE_REAL`，如 `3.25.1`                                       |
| `alpine_version`     | 解析出的基座实际版本（不是 `latest`） | 一次性容器里 `cat /etc/alpine-release`，去掉 `-rN` 后缀                   |
| `base_image`         | 构建时用的基座引用                    | `FROM` 用的那个值，`alpine:${ALPINE_REF}`，默认即 `alpine:latest`         |
| `base_digest`        | 当时基座引用的 index digest           | `imagetools inspect alpine:${ALPINE_REF} --format '{{.Manifest.Digest}}'` |
| `apk_index_digest`   | APK 仓库索引的 sha256，装包层的击穿点 | 一次性容器里 `apk update` 后对 `/var/cache/apk/APKINDEX.*` 求 `sha256`    |
| `cache`              | 本次是否使用 registry 缓存            | `on` / `off`；索引解析失败时脚本会自动降级成 `off`                        |
| `image_size`         | amd64 单平台压缩体积                  | 该平台镜像清单里各 layer 之和加 config 的 `size`                          |
| `image_size_arm64`   | arm64 单平台压缩体积                  | 同上                                                                      |
| `built_at`           | 本次**实际构建时刻**（UTC）           | `date -u +%Y-%m-%dT%H:%M:%SZ`                                             |
| `source_date`        | git 提交时间，进镜像的 `created` 标签 | `git log -1 --format=%cI`，取不到回落 `1970-01-01T00:00:00Z`              |

体积值是格式化后的人类可读串（`image_size_mb` 输出 `%.1fMB`），保留一位小数；`image_digest_short` 用 `cut -c1-12` 截断，因此只能用于人工核对，不能用于 `docker pull`。

`image_version` 与 `alpine_version` 现在恒等（标签名就是解析出来的基座版本），两个都留着是因为语义不同：前者是「这次推上去的标签」，后者是「基座是谁」。哪天给标签加了后缀（例如带上构建源），前者会变、后者不变，下游解析固定用哪个字段就有明确答案，不必临时改口径。

两个时间戳分工不同，别混着用：

- `source_date` 来自 `git log -1 --format=%cI`，同时作为 `BUILD_DATE` 传进 Dockerfile，落成 OCI `org.opencontainers.image.created` 标签。同一份源码重复构建，这个值不变；但 `base.digest` 会随基座变动，所以「config 逐字节相同」只在基座 digest 也相同时成立。
- `built_at` 是本次运行的真实时刻，只写进 commit 元数据、不进镜像。它是「这次构建是什么时候跑的」的唯一记录；为了可复现而把它也算成提交时间，等于把运行时间这条信息永久丢掉。

## 一个基座，两层摘要：可复现到底靠什么

基座是浮动的最新稳定版，标签又每天被同名覆盖，所以「同一份源码 → 逐字节相同的镜像」这件事**不成立，也不打算成立**：今天和明天的 `alpine:latest` 不是同一个东西。可复现改由四样东西保证：

1. **`image_digest`**：这次构建产出的 index digest，是唯一能拿回「这一份产物」的引用——`docker pull <镜像>@sha256:<digest>`。它只在元数据里留最近一次，要长期保存必须自己另存。
2. **`built_at`**：这次构建发生在什么时候。标签不带日期，`built_at` 因此是**唯一的时间记录**，也是判断「这份元数据是不是今天这次构建」的依据。
3. **`alpine_version`**：从 `/etc/alpine-release` 解析出的基座版本号，例如 `3.25.1`，它同时也是版本标签名。
4. **`base_digest`**：当时 `alpine:latest` 的 index digest。`alpine:latest` 早已前移，能与历史对上的只有这个值。

把这四条写清楚之后，结论就一句话：**标签不承诺稳定，digest 才承诺**。想复现「某一天那次构建」，不要指望 `3.25.1` 这个标签还在原处（它已经被覆盖了），要用当时记下的 `image_digest`；想解释「那次为什么长这样」，看 `alpine_version` 与 `base_digest`。

`source_date` 仍然有用，但用途不同：它是提交时间，也是镜像 OCI `created` 标签的取值，回答的是「这份产物对应哪次代码改动」。判断「什么时候构建的」必须用 `built_at`——两者混用会把「今天重跑了两天前的提交」误读成「两天前构建的」。

## 为什么体积要按平台分别统计

三件事叠在一起，决定了脚本里那段看起来绕的体积算法：

1. manifest list 没有「总拉取体积」。用户 `docker pull` 时只会拉自己平台的那几层，把 amd64 与 arm64 相加是个虚构数字。
2. 不能对 index 的条目直接求和。index 里每个条目的 `size` 是清单 JSON 自身的一两 KB，不是层体积；求和会得到几 KB 的假值。
3. 只有真正的镜像清单才含 `layers` 字段。index 没有，所以求和无意义。

脚本的处理顺序是：先按 `Platform.Architecture` 从版本标签的 index 里挑出该平台的镜像清单 digest（有 `jq` 用 `jq` 解 JSON，没有 `jq` 退回 Go 模板），再 `imagetools inspect "${IMAGE}@${digest}" --raw` 取清单原文。拿到原文后先确认含 `"layers"`，才求和：有 `jq` 时 `([.layers[].size] | add) + (.config.size)` 精确相加，没有 `jq` 时用 `grep -o` 扫全文求和，两条路径都只在平台镜像清单上工作。清单 digest 都取不到时直接记 `unknown`，不再退到某个单平台标签上碰运气——宁可显示 `unknown`，也不要写一个看起来合理但错的体积。

两个架构都记，是因为只查 amd64 会漏掉 arm64 基础包体积异常的情况：同一份 Dockerfile 下两者通常只差几个百分点，一旦拉开差距就说明该平台的包解析出了问题。

## -1 与 unknown 的含义

```bash
# 三种失败路径都输出 -1：清单 digest 取不到、原文不含 layers、求和结果小于 1 MiB
if [ "${bytes:-0}" -lt "${MIN_IMAGE_BYTES}" ]; then printf '%s\n' "-1"; fi

# -1 经 image_size_mb 变成 unknown
awk -v b=-1 'BEGIN{ if (b < 0) print "unknown"; else printf "%.1fMB", b/1048576 }'
```

- 取不到平台清单 digest、拿到的不是镜像清单（无 `layers`）、或求和结果小于 1 MiB，都输出 `-1`，同时往 stderr 打一行警告说明是哪一种；`-1` 再变成 `unknown`。正常 alpine 镜像不可能小于 1 MB，这个阈值是经验下界。
- `INDEX_DIGEST` 取不到时写 `unknown`（`image_digest`），前 12 位同理；`BASE_DIGEST` 取不到也写 `unknown`，但它不影响构建——只是这一次没法回查基座 digest。`APK_INDEX_DIGEST` 解析失败时记为 `unknown`，同时把本次的 `cache` 降级成 `off`（全量重建），不会带着空键去读旧缓存。
- 徽章上的灰色 `unknown` 因此有两种成因：这次构建没取到值，或这个 key 从未被写入过。它不代表 0，也不代表体积很小。

## 徽章地址

```text
https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/{key}
```

README 用了其中四个：`image_size`、`image_size_arm64`、`image_digest_short`、`image_version`；`image_digest`、`alpine_version`、`base_image`、`base_digest`、`apk_index_digest`、`cache`、`built_at`、`source_date` 用同一条路径也能读到，只是没放进徽章行。路径里的 `commit/latest` 指最新提交这一维度，与镜像标签 `latest` 同名但无关。

徽章显示 `unknown` 时的排查顺序：

1. 这次构建是否成功，`cnbcool/annotations` 那一步有没有跑；
2. Commit → 元数据页面里这批 key 是否存在；
3. 构建日志里有没有「体积解析失败」或「取到的不是镜像清单」那一行，它带着清单片段，能直接看出取到的是 index 还是镜像清单。

## 重跑同一 commit

`type: ADD` 对同一 commit 是覆盖语义：同名 key 换成新值，只保留最后一次构建的结果。标签那边也一样——同名版本标签每天被覆盖。两处都不做归档，所以「长期锁定某个产物」只有一条路：把 `image_digest` 记下来，按 digest 拉取。上游发新 patch 时，`image_version` 会跟着变（`3.25.1` → `3.25.2`），旧的那份只留在别人的记录里。

## 本地复现查询

不依赖流水线，用同一组命令核对元数据：

```bash
IMAGE=docker.cnb.cool/dtapp/alpine
STAMP=3.25.1

# 1. 版本标签（多架构 index）的 digest
docker buildx imagetools inspect "${IMAGE}:${STAMP}" --format '{{.Manifest.Digest}}'

# 2. 该平台镜像清单的 digest（示例 amd64，换 arm64 只改 Architecture）
PLATFORM_DIGEST=$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" --format \
  '{{range .Manifest.Manifests}}{{if and (eq .Platform.OS "linux") (eq .Platform.Architecture "amd64")}}{{.Digest}}{{end}}{{end}}')

# 3. 该镜像清单里的层体积合计（字节）
BYTES=$(docker buildx imagetools inspect "${IMAGE}@${PLATFORM_DIGEST}" --raw \
  | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' | awk '{s+=$1} END{print s+0}')

# 4. 换算成 MB，与徽章值对照
awk -v b="${BYTES}" 'BEGIN{printf "%.1fMB\n", b/1048576}'

# 5. 回查「当时吃的是哪份基座」：与元数据里的 base_digest 对照
docker buildx imagetools inspect alpine:latest --format '{{.Manifest.Digest}}'
```

第 3 步必须用第 2 步得到的平台清单 digest；把 index 本身丢进 `--raw` 没有 `layers`，求和只有几 KB，不能当体积用。第 5 步只在「想确认某次构建用了哪个基座」时有意义：`alpine:latest` 早已前移，能与历史对上的只有元数据里的 `base_digest`，不是现在这个命令的输出。

## 相关文档

- [CI 流水线](ci-pipeline.md)
- [镜像与标签](images-and-tags.md)
- [故障排查](troubleshooting.md)
- [维护手册](maintenance.md)
