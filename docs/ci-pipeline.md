# CI 流水线

> `.cnb.yml` 只负责 `include` 与定时任务，每个事件的具体步骤分散在 `.cnb/workflows/*.yml`；这里讲清这套组织方式、事件与 workflow 的逐条对应、以及改动流水线时必须同步的位置。

## 为什么拆成 include

一条流水线要同时承载构建、扫描、评审、文档生成、知识库同步五类互不相关的事情。全塞进 `.cnb.yml` 会得到一份几百行、谁都不敢动的文件，所以按「一个事件一组职责」拆成 7 个文件，`.cnb.yml` 只保留两件事：`include` 列表和 `main` 上的定时任务。改 SCA 阈值不会碰到构建脚本，改构建不会误删评审配置。

代价是触发关系不再集中在一处：某个事件到底跑哪些步骤，需要跨文件看。下表就是用来补这个信息。

## 配置的三层结构

```yaml
include:
  - .cnb/workflows/build-image.yml
  # ... 共 7 个文件

main:
  'crontab: 5 0 * * *':
    - name: build-image
      stages:
        - name: 构建并推送多架构镜像
          script: |
            source .cnb/scripts/build-image.sh
```

两层键决定「什么时候跑」：

- 顶层键是分支过滤器。`.cnb.yml` 里定时任务挂在 `main` 下，只对默认分支生效；7 个 workflow 文件统一用 `'**'`，对所有分支生效。
- 事件名在过滤器下一层，值是流水线数组。`push`、`pull_request`、`tag_push`、`issue.open`、`web_trigger_build_image` 都是同级事件键；定时事件把 cron 表达式写进键名并加引号（`'crontab: 5 0 * * *'`），因为键值里有空格和 `*`。

## 事件与 workflow 对应表

| 事件                           | 定义位置                                                                   | 产物                                                                                              |
|--------------------------------|----------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| `web_trigger_build_image`      | `workflows/build-image.yml`                                                | 3 次 `buildx build --push`：多架构 manifest list + amd64/arm64 单平台镜像；`.cnb/annotation.json` |
| `'crontab: 5 0 * * *'`         | `.cnb.yml` 的 `main`                                                       | 同上，但 `version` 恒为 `latest`，不产生版本标签                                                  |
| `tag_push`                     | `workflows/codewiki.yml`                                                   | `${CNB_BUILD_WORKSPACE}/${CNB_REPO_SLUG}/codewiki` 下的 Code Wiki                                 |
| `web_trigger_codewiki`         | `workflows/codewiki.yml`                                                   | 同上                                                                                              |
| `push`                         | `workflows/sca.yml`、`workflows/knowledge-base.yml`                        | SCA 全量报告附件、知识库索引                                                                      |
| `pull_request`                 | `workflows/code-review.yml`、`cnb-sechook.yml`、`code-security-config.yml` | PR 评论、扫描与敏感信息统计、配置校验结果                                                         |
| `pull_request.target`          | `workflows/sca.yml`                                                        | 增量扫描，`failOnSeverity: high` 时门禁失败                                                       |
| `issue.open` / `issue.comment` | `workflows/knowledge-base.yml`                                             | 知识库同步                                                                                        |

`push` 在两个文件里各声明一次，一次 push 会同时拉起 SCA 全量扫描与知识库构建，两段互不依赖；`tag_push` 与 `web_trigger_codewiki` 在 `codewiki.yml` 里是两份内容相同的流水线，改生成参数必须同步两处。

## imports 与 source

构建相关的两段流水线（手动按钮、定时任务）使用同一组 `imports`：

```yaml
imports:
  - https://cnb.cool/dtapp/envs/-/blob/main/docker.yml
  - .cnb/scripts/build-image.sh
```

第一项来自组织 `envs` 仓库，提供构建所需的环境变量；凭证只以 `${CNB_TOKEN}`、`${CNB_TOKEN_USER_NAME}` 的形式出现在脚本里，真实值不进本仓库（见 [CONTRIBUTING](../CONTRIBUTING.md)）。第二项声明脚本依赖，脚本本身也在仓库内。

真正执行发生在 stages 里，且必须用 `source`：

```bash
source .cnb/scripts/build-image.sh   # 正确：变量与输出留在当前 shell
sh .cnb/scripts/build-image.sh       # 错误：set-output 与 export 都随子进程消失
```

原因写在脚本头部：它要 `echo "##[set-output interior_version=$version]"` 把清洗后的版本号交给 CNB 采集，再 `export INTERIOR_VERSION` 给同一步里的 `buildx` 用。换成 `sh` 执行，这两件事都发生在子进程里，外层拿不到。

## runner tags 与 docker 服务

```yaml
runner:
  tags: cnb:arch:amd64
services:
  - docker
```

`tags` 是调度条件：任务只会落到带 `cnb:arch:amd64` 标签的 Runner。arm64 产物也在这台 amd64 Runner 上产出，靠 CNB `services: docker` 内置的多架构 buildx 完成跨架构构建，所以不需要单独找 arm64 机器。

`services: docker` 同时提供 docker daemon 与现成的 builder。脚本里的 `docker buildx version`、`ls`、`inspect` 三段自检就是确认这一点。不要在脚本里 `docker buildx create --driver docker-container`：受限容器拉不起嵌套 buildkitd，会以 bootstrap 失败告终。

## stages 与 set-output

一次 stage 一个 `name`，两种形态：

- `script:` 内联 shell，构建步骤用它；
- `image:` 指定容器镜像加 `settings:`，插件步骤用它。

`##[set-output key=value]` 是 CNB 的 stage 输出语法，写出的值进入 stage 结果，供后续步骤和流水线界面读取。脚本只输出一个 `interior_version`，紧接着用同名大写的环境变量给后续命令用，两者职责不同，不要混用。

## 插件职责

| 插件镜像                           | 出现位置                             | 职责与关键参数                                                                 |
|------------------------------------|--------------------------------------|--------------------------------------------------------------------------------|
| `cnbcool/annotations:latest`       | `build-image.yml`、`.cnb.yml` `main` | `type: ADD` + `fromJsonFile: .cnb/annotation.json`，写 commit 元数据           |
| `cnbcool/codewiki:latest`          | `codewiki.yml`                       | 生成 Code Wiki，`git_doc_dir` 指定落盘目录，`timeout: 3h`                      |
| `cnbcool/knowledge-base`           | `knowledge-base.yml`                 | `include: '**/**.md'`、`issueSyncEnabled: true`、`ignoreProcessFailures: true` |
| `cnbcool/sca-vulnerability:latest` | `sca.yml`                            | 组件漏洞扫描，`scanMode: full/diff`、`publish: true`、`failOnSeverity: high`   |
| `cnbcool/sca-license:latest`       | `sca.yml`                            | License 扫描，参数同上                                                         |
| `cnbcool/sca-sbom:latest`          | `sca.yml`                            | SBOM，`format: spdx`                                                           |
| `cnbcool/code-review:latest`       | `code-review.yml`                    | PR 上的 AI 评审，`comment`、`min_severity`、`exclude_categories`、`model` 等   |
| `cnbcool/cnb-sechook`              | `cnb-sechook.yml`                    | 汇总扫描结果与敏感信息统计，`max_display_authors: 5`                           |
| `cnbcool/code-security-config`     | `code-security-config.yml`           | `args: [validate]`，校验扫描配置本身合法                                       |

扫描策略与忽略规则见[安全基线](security-baseline.md)，插件参数排错见[故障排查](troubleshooting.md)。

## web_trigger.yml：按钮与权限

按钮定义在 `branch.buttons` 下，字段固定为 `name`、`description`、`event`、`permissions.roles`，可选 `inputs`：

| 按钮                                     | event                     | 权限                       | 输入                                            |
|------------------------------------------|---------------------------|----------------------------|-------------------------------------------------|
| 打包 Docker 镜像（多架构 amd64 + arm64） | `web_trigger_build_image` | owner / master / developer | `version`，`required: false`，`default: latest` |
| 生成 Code Wiki                           | `web_trigger_codewiki`    | owner / master / developer | 无                                              |

`event` 与 workflow 文件里的事件键是同一个字符串：两边字面量不一致，按钮点下去就不会产生流水线。`inputs` 里的 key 直接变成脚本读到的小写变量 `version`。

## 新增或修改流水线

1. 改 `.cnb/workflows/` 下的文件，根键 `'**'`，事件名下一层放流水线数组；
2. 新增文件必须加进 `.cnb.yml` 的 `include`，忘记就等于没写；改已有文件不需要动 `include`；
3. 需要手动入口时在 `.cnb/web_trigger.yml` 加按钮，`event` 与 workflow 事件键逐字一致，权限只给需要的角色；
4. 改事件名要同时改 `web_trigger.yml`、`include` 引用与文档，改 inputs 要同时改脚本里读变量的地方；
5. 推送逻辑改动落在 `.cnb/scripts/build-image.sh`，失败必须显式 `exit 1`；提交前跑 `make format`。

## 典型失败与排查入口

| 症状                      | 常见原因                                                                               | 先看哪里                       |
|---------------------------|----------------------------------------------------------------------------------------|--------------------------------|
| 点按钮没有任何流水线产生  | `web_trigger.yml` 的 `event` 与 workflow 事件键不一致，或该 workflow 不在 `include` 里 | 按钮定义、`include` 列表       |
| `FROM` 阶段拉不到基础镜像 | `version` 不是 Docker Hub 上真实存在的 alpine tag                                      | 构建步骤日志、`version` 输入值 |
| buildx bootstrap 失败     | 脚本里自建了 docker-container builder                                                  | 脚本的 buildx 自检段输出       |
| 徽章显示 `unknown`        | 元数据解析失败（体积记 `-1`）或 digest 未取到                                          | 日志里的「体积解析失败」行     |
| 定时任务不生效            | 定时任务只在 `main` 顶层键下声明，改在其它分支上不会生效                               | `.cnb.yml`、默认分支内容       |

排查入口：

```text
流水线运行记录   https://cnb.cool/dtapp/alpine/-/pipeline
定时任务状态     https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab
本次流水线配置   https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml
commit 元数据    https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_digest
```

## 相关文档

- [仓库架构](architecture.md)
- [镜像与标签](images-and-tags.md)
- [构建元数据与徽章](metadata-and-badges.md)
- [安全基线](security-baseline.md)
