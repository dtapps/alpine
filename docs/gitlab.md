# GitLab CI 与 Container Registry

> 三个平台各自维护一份 Dockerfile 与构建脚本（有意复制，不互相引用）：CNB 推 `docker.cnb.cool`，GitHub Actions 推 `ghcr.io`，GitLab CI 推 `registry.gitlab.com/dtapps/alpine`。本篇讲 GitLab 侧的目录、触发方式、镜像地址、变量契约与已知差异；另两个平台的平台层说明见 [CNB 流水线](cnb.md) 与 [GitHub Actions 与 GHCR](github.md)，镜像自己的标签规则见 [Alpine 镜像与标签](alpine/images-and-tags.md)、[Chromium 镜像与标签](chromium/images-and-tags.md)。

## 设计前提：三份副本，各自演进

GitLab 侧不 `source` 另两个平台的脚本，也不共用 Dockerfile。三个平台各有一份完整实现：

| 职责       | CNB                                               | GitHub                                              | GitLab                                             |
|------------|---------------------------------------------------|-----------------------------------------------------|----------------------------------------------------|
| Dockerfile | `.cnb/docker/`                                    | `.github/docker/`                                   | `.gitlab/docker/`                                  |
| 构建脚本   | `.cnb/scripts/build-*.sh`                         | `.github/scripts/build-*.sh`                        | `.gitlab/scripts/build-*.sh`                       |
| 流水线     | `.cnb.yml` + `.cnb/workflows/`                    | `.github/workflows/`                                | `.gitlab-ci.yml` + `.gitlab/workflows/`            |
| 元数据     | `.cnb/annotation.json` → commit annotation → 徽章 | `.github/annotation.json` → Step Summary + artifact | `.gitlab/annotation.json` → artifact + dotenv 报告 |

复制而不是共用的原因与 GitHub 侧相同：标签规则、冒烟断言是同构的，但**平台胶水不同**——GitLab 读 `CI_*` 预定义变量、用临时 job token 登录、在 dind 里自建 buildx builder、把元数据交给 job artifact。代价只有一条，且是硬性规则：**改镜像内容、标签规则、冒烟断言时三份都要改**（见 [CONTRIBUTING](../CONTRIBUTING.md) 硬性规则）；改平台胶水只改自己那一份。

复制来的发布流水线（Go / pnpm / deb / fpk / Release）与本仓库无关，已整体替换为镜像构建流水线。

## 镜像地址

| 镜像                             | GitLab Container Registry 地址 | 对应 GitHub 地址                 |
|----------------------------------|--------------------------------|----------------------------------|
| Alpine 基础镜像                  | `$CI_REGISTRY_IMAGE`           | `ghcr.io/dtapps/alpine`          |
| Alpine + Chromium 无头浏览器镜像 | `$CI_REGISTRY_IMAGE/chromium`  | `ghcr.io/dtapps/alpine/chromium` |

脚本里没有写死 `registry.gitlab.com/dtapps/alpine`，全部从 GitLab 预定义变量派生（本仓库项目地址 [gitlab.com/dtapps/alpine](https://gitlab.com/dtapps/alpine)）：

| 变量            | 来源                                                   | 作用                  |
|-----------------|--------------------------------------------------------|-----------------------|
| `IMAGE`         | `CI_REGISTRY_IMAGE`（转小写）；chromium 加 `/chromium` | 目标镜像全名          |
| `REGISTRY_USER` | `CI_REGISTRY_USER`                                     | `docker login` 用户名 |
| `REVISION`      | `CI_COMMIT_SHA`                                        | OCI `revision`        |
| `IMAGE_SOURCE`  | `CI_PROJECT_URL`                                       | OCI `source` / `url`  |

所以 fork、换 namespace、仓库改名都不用改代码；`CI_REGISTRY_IMAGE` 天然是小写。`chromium` 挂在子路径下，与基础镜像的标签空间互不覆盖——GitLab Container Registry 支持这种嵌套仓库名（最多三层）。三个平台各推各的 registry，**digest 不通用**，不要跨平台比对；Chromium 只解析自己 registry 里的基座。

```bash
# 本仓库（gitlab.com/dtapps/alpine）的实际路径
docker run --rm -it registry.gitlab.com/dtapps/alpine:latest sh
docker run --rm registry.gitlab.com/dtapps/alpine/chromium:latest chromium --version
```

标签契约与另两个平台完全一致：`<alpine 版本>`、`<major.minor>`、`latest`，加上 `<alpine 版本>-linux-{amd64,arm64}` 派生形式。`-cjk` / `-headless` 不再发布，需要时用 `WITH_CJK=1` / `.gitlab/docker/Dockerfile.headless` 自行派生。

## 触发矩阵

流水线创建与否只由根 `.gitlab-ci.yml` 的 `workflow:rules` 决定；job 是否进入流水线由各自 `rules` 决定。两层分开，避免「有流水线但没有可见 job」的配置错误。

| 事件                                 | build-alpine               | build-chromium           | 行为                                                  |
|--------------------------------------|----------------------------|--------------------------|-------------------------------------------------------|
| `schedule`（默认分支）               | `BUILD_TARGET != chromium` | `BUILD_TARGET != alpine` | 每天跟上游重建；两个 job 串在同一条流水线里           |
| `web`（Run pipeline）                | 同上                       | 同上                     | 手动构建；`BUILD_TARGET` 选择跑哪个镜像               |
| `push` / `merge_request` / tag / api | 不创建流水线               | 不创建流水线             | 与 GitHub 侧「只有 schedule + workflow_dispatch」等价 |

`BUILD_TARGET` 默认为 `both`：两个 job 都在；填 `alpine` 只跑基座；填 `chromium` 跳过基座，直接消费已有标签（适合 Chromium 断言失败后重跑）。定时任务在 **CI/CD → Schedules** 网页里建，一条就够，建议 `35 18 * * *`（按 GitLab 实例时区解析，GitLab.com 是 UTC），比 GitHub 的 `17:35 UTC` 晚一小时错开上游镜像源。

### 顺序与串行

- **顺序**：`stage: alpine` → `stage: chromium`，且 `build-chromium` 有 `needs: build-alpine`。`optional: true` 保证「只跑 chromium」时上游 job 不存在也不会报配置错误；`artifacts: false` 防止把 alpine 的 `annotation.json` 当成自己的产物上传（两个 job 写的是同一个文件名）。
- **不需要错峰 1 小时**：GitHub 侧两条独立 cron 只能靠时间差保证基座先就绪；GitLab 一条 schedule 天然把依赖表达成 `needs`。
- **串行**：两个 job 共用 `resource_group: alpine-image-build`，对应 GitHub 的 `concurrency.group`；`default.interruptible: false` 对应 `cancel-in-progress: false`——推 manifest 的 job 被打断会留下半套标签。跨流水线、定时与手动都进同一条队列。
- 镜像名不含 ref：从不同分支手动触发仍会覆盖同一批标签，试推请在项目级 CI/CD 变量里覆盖 `IMAGE`（chromium job 的值必须以 `/chromium` 结尾），不要把 `BUILD_TARGET=both` 和自定义 `IMAGE` 混用。

## 构建现场

两个 job 都 `extends: .docker-build`（定义在根 `.gitlab-ci.yml`），公共 `before_script` 依次做：

1. 预建空的 `.gitlab/build.env`（放在第一步，后面任何一步失败时 dotenv 报告也不缺文件）；
2. `apk add --no-cache git jq`、`git config --global --add safe.directory "$CI_PROJECT_DIR"`（`BUILD_DATE` 取 `git log -1 --format=%cI`）；
3. 等 dind 服务就绪（`docker info` 重试 30 次）；
4. `docker run --rm --privileged "$QEMU_BINFMT_IMAGE" --install arm64` 注册 binfmt，等价于 GitHub 侧 `setup-qemu-action`；缺了会在 arm64 的 `apk add` 报 `exec format error`。GitLab.com SaaS runner 的宿主内核通常已注册 QEMU，输出 `qemu-aarch64 already registered` 属正常；
5. `docker context create alpine-builder-context --docker "host=...,ca=...,cert=...,key=..."`：把 dind 的 endpoint 与 TLS 证书固化进一个 docker context；
6. `docker buildx create --name alpine-builder --driver docker-container --bootstrap --use alpine-builder-context` + `docker buildx inspect --bootstrap`：只有 docker-container driver 能一次产出多架构 manifest list 并 `--push`。

`docker:28-cli` + `docker:28-dind` 走 TLS（`DOCKER_TLS_CERTDIR=/certs`），这几个 `DOCKER_*` 变量必须写在**全局** `variables` 里，service 容器也要读到，runner 据此在 job 与 dind 之间共享 `/certs` 卷。

> **为什么多一步 `docker context create`**：`DOCKER_HOST` / `DOCKER_TLS_VERIFY` / `DOCKER_CERT_PATH` 这组环境变量能直接给 docker CLI 用，但 buildx 创建 docker-container builder 时要启动 buildkit 容器，无法把「从环境变量读到的 TLS 数据」写进 builder endpoint，会直接报 `could not create a builder instance with TLS data loaded from environment. Please use docker context create ...`。把证书路径写进 context，再把这个 context 名作为 `docker buildx create` 的最后一个位置参数即可；脚本里的 `docker run` / `docker pull` / 冒烟测试仍走 default context 的环境变量，两者互不干扰。

- **privileged 是硬前提**：dind 与 binfmt 容器都要 privileged。GitLab.com 的 SaaS runner 支持该模式；自托管 runner 需要 `[runners.docker] privileged = true`，否则第 2/3 步直接失败。若环境不允许 privileged，官方替代是 rootless BuildKit / Buildah，但本仓库脚本依赖 `docker buildx imagetools` 与 `docker run` 冒烟，换方案等于重写三份脚本，不能只改镜像名。
- **磁盘**：Chromium 多架构会吃掉 dind 的 `/var/lib/docker` 数 GiB。GitLab.com SaaS runner 实测是 `overlay2`；自托管 `docker:dind` 默认可能是 `vfs`（每层复制一份，更吃盘）。遇到 `no space left on device` 时，先换大磁盘 runner，再考虑在项目级变量里设 `DOCKER_DRIVER=overlay2`（要求宿主内核 ≥ 4.2 且加载 `overlay` 模块）；匿名拉 `alpine:latest` / binfmt 镜像碰到 Docker Hub 限流时，可给 dind 服务配 registry mirror。

> job 里若再写 `before_script`，会**整体替换**这段（GitLab 的 `extends` 是深合并）。新增步骤请改 `.docker-build` 一处。

## 变量契约

脚本不读 `CNB_*` / `GITHUB_*`，也不要求流水线把镜像名拼好传进来。唯一必须显式映射的是凭证：`CI_REGISTRY_PASSWORD` 只在 job 内注入，脚本认的名字是 `REGISTRY_TOKEN`。

| 变量                      | 默认来源 / 传值                                                | 作用                                                     |
|---------------------------|----------------------------------------------------------------|----------------------------------------------------------|
| `REGISTRY_TOKEN`          | job 的 script：`export REGISTRY_TOKEN="$CI_REGISTRY_PASSWORD"` | `docker login` 密码；临时 job token，仓库里不存凭证      |
| `IMAGE`                   | `CI_REGISTRY_IMAGE`（小写），chromium 加 `/chromium`           | 目标镜像全名；可覆盖                                     |
| `REGISTRY_USER`           | `CI_REGISTRY_USER`                                             | `docker login` 用户名；可覆盖                            |
| `REVISION`                | `CI_COMMIT_SHA`                                                | OCI `revision` 标签；可覆盖                              |
| `IMAGE_SOURCE`            | `CI_PROJECT_URL`                                               | OCI `source` / `url`；可覆盖                             |
| `version`                 | Run pipeline 表单                                              | Alpine 版本；chromium 用它定位 registry 里的同名基座标签 |
| `expected_chromium_major` | Run pipeline 表单                                              | Chromium 主版本断言（仅 chromium）                       |
| `CACHE`                   | 根 `variables`，默认 `on`                                      | `off` = `--no-cache` 全量重建                            |
| `BUILD_TARGET`            | 根 `variables`，默认 `both`                                    | `both` / `alpine` / `chromium`，控制哪些 job 进流水线    |
| `QEMU_BINFMT_IMAGE`       | 根 `variables`，默认 `tonistiigi/binfmt:latest`                | binfmt 注册用的镜像                                      |
| `GITLAB_DOTENV`           | 选填，默认 `.gitlab/build.env`                                 | 结果变量落盘位置（`artifacts:reports:dotenv`）           |

产物：`.gitlab/annotation.json`（artifact，留 30 天）记录 digest、体积、版本、APK 索引指纹等；`.gitlab/build.env`（dotenv 报告）写 `image_version` / `image_digest` / `alpine_version`（chromium 是 `chromium_image_version` / `chromium_version` / `chromium_image_digest`）。两个文件都在 `.gitignore` 里，也都在 `.dockerignore` 里排除，不会进镜像构建上下文。

## 与 GitHub 的实现差异

| 维度     | GitHub Actions                                      | GitLab CI                                                      |
|----------|-----------------------------------------------------|----------------------------------------------------------------|
| 地址来源 | `ghcr.io` + `GITHUB_REPOSITORY`（小写）             | `CI_REGISTRY_IMAGE`（小写）；chromium 加 `/chromium`           |
| 凭证     | `secrets.GITHUB_TOKEN` + `permissions.packages`     | `CI_REGISTRY_PASSWORD`（临时 job token），无需额外配置 secret  |
| 触发     | 两个 workflow 各一条 UTC cron + `workflow_dispatch` | 一条网页 schedule + Run pipeline，两个 job                     |
| 先后     | 16:35 → 17:35 UTC 错开 1 小时                       | 同流水线 `stage` + `needs`，天然串行                           |
| 并发     | `concurrency.group` + `queue: max`                  | `resource_group` + `default.interruptible: false`              |
| 构建现场 | hosted runner，两个 setup action 现装 QEMU/buildx   | `docker:cli` + `dind`（TLS）+ binfmt 容器 + `buildx create`    |
| arm64    | QEMU 模拟                                           | QEMU 模拟（同样要几十分钟，job 超时 2h）                       |
| 层缓存   | `<镜像>:buildcache`，按 APK 索引指纹失效            | 同左                                                           |
| 元数据   | Step Summary + artifact + `GITHUB_OUTPUT`           | artifact(JSON) + `artifacts:reports:dotenv`                    |
| 磁盘     | 构建前删预装 SDK 腾 14 GiB                          | 依赖 runner 自身磁盘，不够时换大磁盘 runner                    |
| 权限配置 | 包页面改 visibility / 组织 Packages 策略            | 项目设置开启 Container Registry；私有项目拉取需 `docker login` |

关于 registry 缓存：与另两个平台同构，`<镜像>:buildcache` 是缓存清单、不是可拉取的镜像标签。装包层的缓存键带 APK 索引指纹，机制见[缓存实现](cache-implementation.md)。GitLab SaaS runner 在境外，直连 Alpine 官方源最快，**不换源**（CNB 侧的腾讯云替换不要复制过来）。

## 首次接入

1. 项目 **Settings → General → Visibility** 打开 Container Registry；确认 `CI_REGISTRY_IMAGE` = `registry.gitlab.com/dtapps/alpine`。
2. 确认 runner 允许 privileged 容器（GitLab.com SaaS runner 已支持；自托管检查 `[runners.docker] privileged = true`），并有足够磁盘跑 Chromium 多架构。
3. **CI/CD → Schedules** 新建一条：默认分支、建议 `35 18 * * *`，变量保持 `BUILD_TARGET=both`。
4. **CI/CD → Pipelines → Run pipeline** 手动跑一次 `BUILD_TARGET=both`，确认两个 job 依次通过、registry 里出现 5 个标签 + `buildcache`。
5. 可选：`README.md` 顶部的 pipeline 徽章已按本仓库路径配好（`https://gitlab.com/dtapps/alpine/badges/main/pipeline.svg`）；默认分支不是 `main` 时把 URL 里的分支名换掉。

## 手动运行与排错

```text
CI/CD → Pipelines → Run pipeline
  BUILD_TARGET=both（默认）       两个镜像都构建
  BUILD_TARGET=alpine            只重建基座
  BUILD_TARGET=chromium          只重建 Chromium（消费已有基座标签）
  version=3.25.1                 钉版本；留空跟随上游 / 基座 latest
  expected_chromium_major=156    Chromium 主版本断言，留空不校验，any 跳过
  CACHE=off                      不用 registry 缓存，全量重建
```

| 症状                                                                        | 常见原因                                                                    | 先看哪里                                                                 |
|-----------------------------------------------------------------------------|-----------------------------------------------------------------------------|--------------------------------------------------------------------------|
| 流水线根本没创建                                                            | 不是 `schedule` / `web`，或 schedule 不在默认分支                           | `workflow:rules`、`CI_PIPELINE_SOURCE`                                   |
| `unauthorized` / `denied`                                                   | 项目没开 Container Registry、job token 权限不足、镜像路径不合法             | 项目设置、脚本日志里的 `IMAGE`                                           |
| arm64 阶段 `exec format error`                                              | binfmt 没注册成功（runner 不允许 privileged）                               | `before_script` 的 `docker run ... binfmt`                               |
| `no space left on device`                                                   | Chromium 多架构把 dind 磁盘吃满                                             | runner 磁盘；`CACHE=off` 不解决磁盘问题                                  |
| `找不到基座 ...`                                                            | alpine job 失败、或 `BUILD_TARGET=chromium` 但基座从没产过                  | 先跑 `BUILD_TARGET=alpine` 或 `both`                                     |
| `latest` 没前进                                                             | 冒烟失败（时区、源行数、命令缺失、OCI 标签），提升前已退出                  | 构建日志的「冒烟测试失败」                                               |
| chromium 构建在断言处失败                                                   | 填了 `expected_chromium_major`，但上游升了主版本                            | 用新主版本号覆盖，或填 `any`                                             |
| `toomanyrequests`                                                           | Docker Hub 匿名限流（`alpine:latest`、binfmt 镜像）                         | 配 Docker Hub 凭证或使用依赖代理                                         |
| `could not create a builder instance with TLS data loaded from environment` | buildx 不能从环境变量读 TLS 数据来创建 docker-container builder             | `before_script` 的 `docker context create` 一步                          |
| `Skipping alias "docker" ... alias is already in use`                       | GitLab.com SaaS runner 已注入同名 service 别名，job 里显式写的 alias 被跳过 | 环境噪音，`docker info` 能连上就可忽略                                   |
| `.gitlab/annotation.json: no matching files`                                | 构建在写元数据之前就失败，文件尚未生成                                      | 预期警告，先看真正的失败步骤                                             |
| `build.env` dotenv 报告缺文件                                               | `before_script` 完全没跑起来（镜像没拉到等）                                | 只是警告，不影响 job 结果                                                |
| dotenv 上传 `400 Bad Request (Invalid Format)`，job 在推送成功后失败        | `build.env` 的值里有换行（如把 `imagetools inspect` 的整段输出当 digest）   | 脚本的 `image_digest()` 已单行化；勿用 `--format '{{.Manifest.Digest}}'` |
| registry 里出现 `buildcache`                                                | 预期行为：registry 缓存清单，不是镜像标签                                   | 无需处理；不想用可传 `CACHE=off`                                         |

## 维护约定

- **三份副本要同步**：改镜像内容（`.gitlab/docker/`）或标签/冒烟/元数据（`.gitlab/scripts/`）时，必须同时改 `.cnb/` 与 `.github/` 的对应实现；只改平台胶水时各改各的。
- **不要在 job 里重写 `before_script` / `variables.DOCKER_*`**：前者会整体替换 `.docker-build`，后者是 dind TLS 与 service 容器共用的全局配置。
- 换 Docker CLI 版本要同时改 `.docker-build` 的 `image.name` 与 `services[0].name`，版本必须一致。
- 定时任务的 cron 在网页里、不在仓库里：改时间后同步更新本篇与 README 的说明；GitLab 的 cron 按实例时区解析，自托管实例先确认时区。
- 不要把标签派生、冒烟、提升顺序拆成多个 job 或换成三行式构建 action：这些契约都在 `.gitlab/scripts/` 里，拆开等于再实现一遍。
- 仓库里不存任何 PAT / deploy token；需要跨项目推镜像时，用项目级 CI/CD 变量（masked + protected）覆盖 `IMAGE` 与凭证，并在 PR 里说明。

## 相关文档

- [GitHub Actions 与 GHCR（平台层）](github.md)
- [CNB 流水线（平台层）](cnb.md)
- [Alpine 镜像与标签](alpine/images-and-tags.md)
- [Chromium 镜像与标签](chromium/images-and-tags.md)
- [缓存实现](cache-implementation.md)
- [贡献指南](../CONTRIBUTING.md)
