# APK 源与网络策略

> 换掉 `dl-cdn.alpinelinux.org` 是为了让构建在国内不卡在第一步：四个源按可用性排序、官方源兜底，且只开 `main` 一行一源；索引与包的签名仍由 Alpine 官方公钥校验。

## 为什么换源

- 官方源 `dl-cdn.alpinelinux.org` 在国内解析与下载都不稳定。`apk add` 卡在这里，表现为流水线超时，失败点却不在代码上，排查成本高。
- 换源只改 `/etc/apk/repositories` 这一个文本文件，不改变包的来源身份：包仍由 Alpine 官方构建并签名，镜像站只承担分发。
- 收益是构建速度与稳定性，代价是信任面变大——这件事在 [SECURITY](../../SECURITY.md) 里被列为已知取舍，最后一节展开。

## 仓库路径怎么推导

```dockerfile
alpine_ver="$(cut -d. -f1,2 /etc/alpine-release)"
```

- `/etc/alpine-release` 的内容形如 `3.25.1`（major.minor.patch），而 APK 仓库路径只到 `major.minor`，即 `v3.25`，所以取前两段再拼 `v`。
- 在容器内读文件推导，而不是从 `ARG ALPINE_VERSION` 截取：那个 ARG 的默认值是 `latest`（拼不出仓库 URL），另外三种写法（`3.25`、`3.25.1`、`3.25.1@sha256:...`）截取时又要额外处理「只有两段」和「带 digest 后缀」；读 `/etc/alpine-release` 永远拿到当前实际运行版本的规范形式，一次都不用处理。
- 在容器内读还能自动对齐：基座默认跟随 `latest`，上游从 `3.24.x` 走到 `3.25.x` 时，仓库路径自动从 `v3.24` 变成 `v3.25`，源这一段的代码一行都不用改。这也是「只写一行 `main`、用 `printf` 一次生成」的前提——路径是算出来的，不是抄出来的。
- 前提是 `FROM` 用的是真实存在的标签；ARG 传错在 `FROM` 阶段就失败，不会走到这里。

## 四行源与顺序

| 顺序 | 源     | URL 前缀                            | 角色             |
|------|--------|-------------------------------------|------------------|
| 1    | cernet | `https://mirrors.cernet.edu.cn`     | 教育网与公网都快 |
| 2    | 腾讯云 | `https://mirrors.cloud.tencent.com` | 云上网络稳定     |
| 3    | 阿里云 | `https://mirrors.aliyun.com`        | 覆盖面广         |
| 4    | 官方   | `https://dl-cdn.alpinelinux.org`    | 原始出处，兜底   |

一个源写一行，只写 `main`，共四行，用一次 `printf` 写入 `/etc/apk/repositories`：

```dockerfile
printf '%s\n' \
    "https://mirrors.cernet.edu.cn/alpine/v${alpine_ver}/main" \
    "https://mirrors.cloud.tencent.com/alpine/v${alpine_ver}/main" \
    "https://mirrors.aliyun.com/alpine/v${alpine_ver}/main" \
    "https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/main" \
    >/etc/apk/repositories
```

顺序的两层含义：先被尝试的源决定速度，版本相同时先列出的源决定取哪一份。调整顺序属于对外行为变更，[CONTRIBUTING](../../CONTRIBUTING.md) 要求说明理由。

容器里看实际生成的内容：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest cat /etc/apk/repositories
```

```text
https://mirrors.cernet.edu.cn/alpine/v3.25/main
https://mirrors.cloud.tencent.com/alpine/v3.25/main
https://mirrors.aliyun.com/alpine/v3.25/main
https://dl-cdn.alpinelinux.org/alpine/v3.25/main
```

## 为什么只开 main

旧版本每个源写 `main` 和 `community` 两行、五个源共十行。现在一个源只写 `main` 一行，理由是「装了什么都用不上」：

- 本镜像预装的五个包（`ca-certificates`、`curl`、`drill`、`netcat-openbsd`、`tzdata`）全在 `main`。`community` 里的包一个都没装，那份索引是纯粹的下载开销——它约 2.4 MiB，`apk` 每次取索引都要下、都要解压、都要合并进包视图，而它对当前这条 `RUN` 的贡献是零。
- 十行降到四行，也少了大半「哪个源的哪一行写错了」的可能。四行只差主机名，肉眼就能对齐。
- `community` 不是被删掉，是被挪出了默认路径：真需要时在 `/etc/apk/repositories` 追加一行即可，写法见下一个节。

反过来，如果需要 `community` 里的包，正确做法是把它加回来并接受多一份索引，而不是「先加上、装完再删」——删掉 `/etc/apk/repositories` 里的一行不会让已经装上的包变成非法，但会让 `apk policy`、`apk upgrade` 之类的后续诊断失去上下文。

## 可选源池

以下内容不在默认配置里，需要时手动加。它们和上面四行是同一套语义（同一行序即回退序），加不加只影响可用性余量，不影响包的真实性。

| 可选项         | 什么时候加                                     |
|----------------|------------------------------------------------|
| 火山引擎       | 前面某个云厂商源在你所在网络里变慢时，作为补充 |
| `community` 行 | 需要在 Dockerfile 里装 community 的包时        |

```text
https://mirrors.volces.com/alpine/v${alpine_ver}/main
https://mirrors.aliyun.com/alpine/v${alpine_ver}/community
```

加 `community` 时把四行一起换成对应站点的 `community` 行没有必要：只需要一个能取到 community 索引的源，多开几份只是重复下载。通常的做法是挑当前最快的那一站，紧跟它的 `main` 行后面追加一行。

## apk 的仓库尝试语义

- apk 没有优先级字段，`/etc/apk/repositories` 的**行序就是回退序**；每一行是一个独立仓库，`main` 与 `community` 各算一份索引。
- 每次 `apk add`，apk 为每个仓库取一份 `APKINDEX`，把多份索引合并成一张包视图。仓库越少，这一步越快。
- 单个源不可达只会打印 `WARNING` 并继续，用其余源照常解析；只有当所有源都取不到索引，或者所有源都没有目标包时，命令才失败。
- 同一个包在多个源里都有、版本相同时，先列出的源胜出；版本不同时取版本更高的那一份。所以「换源」不会让包悄悄降级。
- 因此实际生效的是「可用源的并集」，而不是「第一个源的镜像」：前面的源挂了，构建仍能继续，只是多了几行 `WARNING` 和等待超时的几秒。

## 验证某个源现在可用

索引 URL 形如 `https://<mirror>/alpine/v3.25/main/<arch>/APKINDEX.tar.gz`，`<arch>` 是 `x86_64` 或 `aarch64`。用镜像内的版本号替换示例里的 `3.25`：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest cat /etc/alpine-release
```

```bash
VER=3.25
for host in mirrors.cernet.edu.cn mirrors.cloud.tencent.com mirrors.aliyun.com dl-cdn.alpinelinux.org; do
  printf '%-32s ' "$host"
  curl -sSI -o /dev/null -w '%{http_code} %{time_total}s\n' \
    "https://${host}/alpine/v${VER}/main/x86_64/APKINDEX.tar.gz"
done
```

`200` 表示索引可取，耗时那一列可以直接看出哪条线路慢；`403` / `404` 多为路径或版本号写错；连不上或超时则是网络问题。要连可选源池里的站一起测，把它追加到 `for` 的列表里即可。

容器内验证走的正是镜像里的源配置，比在宿主机上测更贴近真实构建：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest sh -c 'apk update'
```

输出里每个 `fetch` 对应一个源，出现 `WARNING` 的那几行就是当前不可用的源。注意镜像本身构建时并不跑 `apk update`（`apk add --no-cache` 自带索引拉取），这条命令只是诊断手段，它写下的索引落在容器内、容器退出即消失。

## 源挂掉时怎么改

1. 先用上一节的 `curl` 循环区分「某个源挂了」和「整条网络不通」。
2. 只动 `.cnb/docker/Dockerfile.alpine` 里 `printf` 那段对应的一行：调整顺序就是整行搬位置，弃用就是整行删掉；不要为了一个源改动 `printf` 的结构。
3. 保持四行同构（只差主机名）。写成 `>` 和 `>>` 混用是旧写法，现在一次 `printf` 写完整个文件，不存在「某一行误写成 `>` 冲掉前面所有行」的可能——这条历史坑不值得保留第二次。
4. 本地验证：`docker build -f .cnb/docker/Dockerfile.alpine -t alpine:local .`（默认跟随上游 `latest`；想固定基座再加 `--build-arg ALPINE_VERSION=3.25.1`），再在容器里跑一次 `apk update` 确认没有新的 `WARNING`。
5. 跑 `make format-docker` 让 `dockerfmt` 统一格式，提交时在 PR 里写明「哪个源、什么症状、什么时候观测到」。
6. 不要因为某个国内站出问题就顺手删掉官方源：删掉等于把「几个镜像站同时故障」变成构建彻底失败。

## 供应链信任面

- 信任面 = 上游 Alpine + 这四个分发站，已在 [SECURITY](../../SECURITY.md) 的「已知取舍」里写明。
- 镜像站能做的：返回索引与包、拒绝服务、返回旧快照（构建拿到的是过期版本的包）。
- 镜像站无法悄悄塞进一个恶意包：apk 用 `/etc/apk/keys/` 里的 Alpine 官方公钥校验仓库索引与每个 `.apk` 包的签名，签名不符直接拒绝安装。
- 因此换源主要影响**可用性**与**时效性**，不影响包内容的真实性；剩下的风险是构建指纹（源站能看到你请求了哪些包与版本）和「被喂旧索引导致镜像停留在旧包上」。
- 后一条正是「每天 00:05 重建一次」的意义之一：基座默认跟随 `latest`，定时任务每天重新解析并装包，上游的新补丁、新小版本当天就能进镜像；即便某个源短暂返回旧索引，被拖住的也只是一天，详见 [维护手册](maintenance.md)。
- 不要在源 URL 里放任何凭证：本仓库只引用公开镜像站，不存在私有源与鉴权参数。

## 为什么保留官方源兜底

- 三个国内站都是镜像，同步有延迟；官方源是包的原始出处，缺包与缺索引的概率最低。
- 放在最后不影响速度：只有前面全部连不上，或全都没有目标包时才会走到它，正常构建根本碰不到。
- 成本只有一行文本和一次尝试；收益是「国内站同时故障」时构建仍能完成。
- 它同时是判断基准：国内站行为异常时，把官方源临时挪到第一位，就能确认是镜像站的问题还是包本身的问题。

## 相关文档

- [文档索引](index.md)
- [Dockerfile 解析](dockerfile.md)
- [安全基线](security-baseline.md)
- [排错手册](troubleshooting.md)
