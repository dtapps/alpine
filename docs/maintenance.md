# 维护手册

> 补丁节奏等于上游 Alpine 的节奏：定时构建负责「跟随」，手动按钮负责「定点」，需要人判断的只有升级大版本、同步文档和清理标签。

## 谁在什么时候动这个镜像

| 触发方式                           | 频率                          | `version` 取值                  | 产物                                |
|------------------------------------|-------------------------------|---------------------------------|-------------------------------------|
| 定时构建 `crontab: 5 0 * * *`      | 每天 `00:05`（Asia/Shanghai） | 固定 `latest`                   | `latest` 与两个单平台标签           |
| 手动按钮 `web_trigger_build_image` | 按需                          | 留空按 `latest`，可填 `3.20` 等 | 上述三个标签，外加 `<version>` 系列 |

定时任务刻意不打版本标签：版本号应由人决定，否则每天一次的构建会不断覆盖历史版本标签。定时任务与手动按钮跑的是同一份 `.cnb/scripts/build-image.sh`，差别只在 `version`。

## 日常补丁节奏

`Dockerfile` 不锁包版本，每次构建都重新 `apk update` 拉索引，所以上游 Alpine 发补丁后，第二天 `00:05` 的 `latest` 自动带上。

```bash
# 有 docker CLI 的机器上确认当前 latest 指向的 digest
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest --format '{{.Manifest.Digest}}'
```

判断「这次构建是否真的产出了新镜像」看 commit 元数据：`built_at` 应更新，`image_digest_short` 通常会变化。若连续两天没变，说明上游没有更新，或构建在更早阶段失败了。

## 手动重建版本标签

先确认 Alpine 上存在要填的 tag，有 Manifest 输出即存在：

```bash
docker buildx imagetools inspect alpine:3.20
```

然后在仓库页面 → 流水线 → 点击「打包 Docker 镜像（多架构 amd64 + arm64）」，`version` 填 `3.20`。这一次构建做三件事：清理 `version`（去掉空白与不可打印字符，空值回落为 `latest`）；非 `latest` 时在三个恒定标签之外追加 `<version>`、`<version>-linux-amd64`、`<version>-linux-arm64`；把同名 tag 指向新 digest，按 tag 拉取的下游自动拿到新镜像。

必须知道的副作用：`MULTI_TAGS` 恒定包含 `latest`，所以任何一次手动构建都会把 `latest` 一起移到本次版本上。用 `3.20` 手动重建后，`latest` 也会变成基于 `alpine:3.20` 的镜像；第二天 `00:05` 的定时构建会把它拉回上游最新（定时任务传 `version=latest`，即 `FROM alpine:latest`）。要长期停留在某个 minor，就别依赖 `latest`，让下游按版本标签或 digest 拉。

## 升级 Alpine 版本

### 小版本升级（3.20.x → 3.20.y）

不需要改任何文件。`Dockerfile` 用 `cat /etc/alpine-release | cut -d'.' -f1,2` 推导源路径，新补丁版本自带同样的 `v3.20` 路径，源列表不用动。动作只有一次重建：`latest` 等定时构建，版本标签手动点按钮。

### 大版本升级（3.20 → 3.21）

按顺序走完七步，任何一步失败就停下，不要带着半套改动提交。

**第一步：确认 Docker Hub 上的 tag 存在。** 不存在会在 `FROM` 阶段失败，报拉不到 `alpine:3.21`。

```bash
docker buildx imagetools inspect alpine:3.21
```

**第二步：确认新版本的源路径可用。** Dockerfile 把 `major.minor` 拼成 `vX.Y` 写进 `/etc/apk/repositories`，镜像站同步滞后时 `apk update` 会 404 或超时。

**第三步：确认五个包在新版本仓库里仍然可用。** `netcat-openbsd`、`bind-tools` 在大版本间移动过仓库的情况要先排除：

```bash
docker run --rm alpine:3.21 sh -c \
  'apk update && apk add --no-cache ca-certificates curl netcat-openbsd bind-tools tzdata'
```

**第四步：本地构建并跑容器自检。**

```bash
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=3.21 -t alpine:local .
docker run --rm alpine:local sh -c 'cat /etc/alpine-release; date; cat /etc/timezone; cat /etc/apk/repositories; command -v curl nc dig nslookup'
```

**第五步：逐项核对验证清单。**

| 检查项   | 命令                                                               | 期望                                                             |
|----------|--------------------------------------------------------------------|------------------------------------------------------------------|
| 基础版本 | `cat /etc/alpine-release`                                          | 新版本号，与 `version` 入参一致                                  |
| 时区     | `date`、`cat /etc/timezone`                                        | 显示 `CST`，时区文件为 `Asia/Shanghai`                           |
| 源路径   | `cat /etc/apk/repositories`                                        | 十行全部是 `vX.Y`，顺序为 cernet → 腾讯云 → 阿里云 → 火山 → 官方 |
| 包策略   | `apk policy ca-certificates curl netcat-openbsd bind-tools tzdata` | 每个包都有版本与来源仓库，无 `unavailable`                       |
| 工具自检 | `command -v curl nc dig nslookup`                                  | 四个路径都有输出                                                 |
| 时区链接 | `ls -l /etc/localtime`                                             | 指向 `/usr/share/zoneinfo/Asia/Shanghai`                         |

**第六步：同步文档。** `README.md` 里以 `3.20` 为例的拉取与构建示例、`SECURITY.md` 的支持范围、`docs/` 里出现版本号的示例，都要跟着改。文档落后于镜像比没有文档更容易误导。

**第七步：触发正式构建。** 按需选定时或按钮；用按钮时 `version` 填新版本号，会同时产出 `latest` 与 `<version>` 系列。

## 何时必须重建

| 场景                                          | 是否重建 | 说明                                   |
|-----------------------------------------------|----------|----------------------------------------|
| 上游 Alpine 发布新补丁                        | 是       | `latest` 次日自动跟随；版本标签手动    |
| SCA 报出 high / critical 且上游已修复         | 是       | 重建后 digest 变化即代表修复进入镜像   |
| 改了 `Dockerfile`、`build-image.sh`、workflow | 是       | 构建内容或构建逻辑变了，产物必须重出   |
| 只改文档、只改 `.scanignore`                  | 否       | 不影响镜像内容，扫描与知识库各自会重跑 |

## 历史镜像不回溯

旧 digest 不会被补丁：上游修了也只作用于之后的新构建。因此下游不要长期钉住某个 digest，而是把它当「我知道自己在用哪一份」的凭据。

不回溯的理由很实际：回溯要给历史 commit 逐个重跑构建并重新推同名 tag，等于把已经前移的 `latest` 语义再改一次，而遗留的旧产物又没有人拉。收益与成本不成比例，所以明确写成「用完即弃」。

## 周期性检查清单

| 频率         | 检查什么                                         | 位置 / 命令                          |
|--------------|--------------------------------------------------|--------------------------------------|
| 每周         | 定时构建是否连续成功，`built_at` 是否在更新      | 流水线记录、`built_at` 徽章          |
| 每周         | SCA 报告里 high / critical 是否指向上游已修的包  | 安全页的漏洞扫描报告                 |
| 每月         | 版本标签数量是否超出实际仍在使用的 minor         | 制品库 tag 列表                      |
| 每月         | `.scanignore` 两条排除是否仍然必要               | 扫描结果对两张图片无报错即可考虑删除 |
| 每次上游发版 | `latest` 是否已带上新补丁，`apk policy` 是否正常 | 上面的验证清单                       |

## 制品库与标签膨胀

一次带版本的手动构建固定产出六个标签位：多架构的 `latest`、`<version>`，加单平台的 `latest-linux-amd64`、`latest-linux-arm64`、`<version>-linux-amd64`、`<version>-linux-arm64`。定时构建只覆盖其中三个 `latest*` 标签，所以**膨胀只来自手动输入的版本号**，每多一个版本就多三个 tag。

- 保留窗口按实际仍在使用的 minor 定，更早的版本标签在确认无下游引用后删除。
- 删除时三个标签一起删。只删多架构那只会在制品库里留下无法解释的单平台残留，反查时更容易误判。
- `latest` 与两个 `latest-linux-*` 不要删：删掉后到下一次构建之前下游拉不到镜像。
- 删除操作在制品库页面按 tag 进行。删 tag 不等于立刻释放空间，旧 digest 的 blob 由制品库自行回收。

## 已知待办

| 待办               | 现状                                | 影响                                            |
|--------------------|-------------------------------------|-------------------------------------------------|
| 未接入镜像层扫描   | 只有 SCA 扫 `Dockerfile` 的依赖声明 | 层内二进制的 CVE 不会被发现，需要下游自己加扫描 |
| 镜像未签名         | 制品库不校验来源真实性              | 强校验只能按 digest 固定拉取                    |
| 版本标签不自动跟随 | 仅手动触发                          | 落后 `latest` 的幅度取决于巡检频率              |

## 相关文档

- [镜像与标签](images-and-tags.md)
- [CI 流水线](ci-pipeline.md)
- [安全基线](security-baseline.md)
- [SECURITY](../SECURITY.md)
