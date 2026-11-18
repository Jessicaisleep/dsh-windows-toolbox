# tools/legacy — 生成器的输入，不是运行时依赖

`client.js` 与 `tests/fixtures.json` 都是**生成文件**，由 `tools/merge-client.mjs` 和
`tools/merge-render-fixtures.mjs` 产出。这两个脚本需要一个「两半各自的原始源码」作为输入。
本目录就是那份输入，作用是让**生成过程自包含**：本插件不再依赖磁盘上另外两个目录是否存在。

| 文件 | 来源 | 被谁读 |
| --- | --- | --- |
| `manage-client.js` | 原 `dsh-windows-plugin-manager/client.js`（旧插件，已从 profile 摘除） | `merge-client.mjs` |
| `toolbox-client.js` | 原 `dsh-360-toolbox/client.js`（同上） | `merge-client.mjs` |
| `manage-render.mjs` | 原 `dsh-windows-plugin-manager/tests/render.mjs` | `merge-render-fixtures.mjs` |
| `toolbox-render.mjs` | 原 `dsh-360-toolbox/tests/render.mjs` | `merge-render-fixtures.mjs` |

## 规则

- **运行时不读这里的任何文件。** 宿主只加载 `index.js`、`client.js`、`lib/`、`locales`。
- **不要手改。** 它们是历史快照；要改行为就改 `client.js` 的上游（即本目录的副本）+ 重跑生成器，
  或者直接把最终改动写进生成后的 `client.js` 并在 `merge-client.mjs` 里同步。
- 生成器带 `--check`：`node tools/merge-client.mjs --check` 会在产物与「用本目录重算的结果」
  不一致时报错退出 1，用来抓「手改了 `client.js` 但没同步生成器」。

## 为什么保留而不是删掉

删掉这四个文件，`client.js` 就变成一份**不可复现**的 3700 行文件——出问题时无法用脚本重算、
无法 diff 出「哪一半改了什么」。旧目录可以从磁盘上移除，但这两份源码是生成链的一部分，必须留在插件内。
