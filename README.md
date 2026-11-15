# ARC cache smoke test

Public test fixture for the IaC ARC runner, Docker DinD and persistent BuildKit/pnpm cache. Workflows run only with workflow_dispatch on repository-scoped self-hosted runners. No untrusted PR-triggered workflows.

# ARC runner 実検証 (2026-11-15)

検証先: `kubectl --context cilium-cluster`。
テスト repo: <https://github.com/sugaf1204/arc-cache-smoke-20261115>。
既存の local-path-provisioner → ARC controller → runner / BuildKit の順に kubectl で適用した。
Argo CD での main 反映・Sync はこの検証に含めない。

GitHub の repository-scoped scale set `arc-docker` で、以下の 5 ジョブが成功した。
すべて別の runner Pod を使い、Node `v24.22.3` / pnpm `12.21.0` 入りの独自 runner image を実行した。
base image もこの検証で publish したものを Dockerfile の FROM に指定した。

| ケース | 実行結果 | app build + load 秒数 | Actions run |
| --- | --- | --- | --- |
| 冷間 pnpm cache | reused 0 / downloaded 1。install と app build を実行 | 10 | [cold](https://github.com/sugaf1204/arc-cache-smoke-20261115/actions/runs/43698841678) |
| 同一 commit を別 runner で再実行 | install / app build とも CACHED | 9 | [warm](https://github.com/sugaf1204/arc-cache-smoke-20261115/actions/runs/43699169331) |
| ソース変更 | install は CACHED、app build を実行。出力が source-v2 に更新 | 9 | [source-change](https://github.com/sugaf1204/arc-cache-smoke-20261115/actions/runs/43699307488) |
| package.json / lockfile 変更 | frozen install 成功。reused 1 / downloaded 1、計 2 依存 | 10 | [dependency-change](https://github.com/sugaf1204/arc-cache-smoke-20261115/actions/runs/43699400764) |
| BuildKit Pod 削除・再作成後 | 同一 commit の install / app build とも CACHED | 8 | [after-builder-restart](https://github.com/sugaf1204/arc-cache-smoke-20261115/actions/runs/43699503984) |

秒数は workflow 内の `APP_BUILD_SECONDS`。runner 起動・checkout・docker run などは含まない。
ベースイメージを事前に publish した後の小さな JS fixture の単発測定であり、全イメージが空の状態との比較や、
実アプリの改善率を示すベンチマークではない。初回 10 秒から再実行 9 秒の違いより、
install を省けることと、lockfile 更新時に既存 package を再ダウンロードしないことが主な確認事項。
各回の時間は主に fresh DinD への image の転送・展開で占められた。
ビルド後にローカル実行しない用途は `--push` とし、`--load` を省ける。

各ジョブで追加確認したこと:

- hook が mTLS で persistent remote builder を bootstrap できる。
- `docker buildx build --load` の成果物を DinD の `docker run --rm` で実行し、repo の期待値と `cmp` で一致する。
- 通常の `docker build` も `BUILDX_BUILDER=persistent` で同じ builder を使用し、CACHED の結果を DinD で実行できる。
- custom runner の `node --version` / `pnpm --version` が実行できる。
- 最終 2 回では Node 24 対応の `actions/checkout@v7.0.1` も実行できる。

BuildKit の再起動前後で確認したもの:

- Pod UID は変更された。
- PVC UID は `70979857-8a40-4967-8943-4b9b3766cb5d` のまま。
- PV は `pvc-70979857-8a40-4967-8943-4b9b3766cb5d` のまま。
- `buildctl du --filter 'type==exec.cachemount'` の cache mount 2 件の ID / サイズは変更なし。

## 実ビルドで見つけて修正した点

[bootstrap run](https://github.com/sugaf1204/arc-cache-smoke-20261115/actions/runs/43698383516) では
独自 base / runner image の build と GHCR push は成功したが、DinD で実行すると
`failed to convert whiteout file ... operation not permitted` になった。
DinD のデータが CRI-O の container overlay 上にある状態だった。

同じ Docker 29 と同じ base image で比較し、`/var/lib/docker` と `/var/lib/containerd` を
専用 emptyDir に分離すると、既定の containerd image store のまま pull / run が成功した。
その設定を runner template に反映し、上記 5 ケースを完了した。

## 残したリソース

- 公開のテスト repo、GHCR の base / runner image。
- `arc-systems` の controller / listener、`arc-runners` の scale set / BuildKit / PVC。
- GitHub 認証・GHCR pull 認証・BuildKit mTLS は Kubernetes Secret にのみ保存。
- runner image は IaC repository の values.yaml で digest 固定。
- `minRunners: 0` のため idle runner Pod は残らない。診断用の `arc-dind-diagnostic` Pod は削除した。

最終確認で controller / listener / BuildKit は Ready、scale set は Running、PVC は Bound。
ビルドキャッシュの冗長化、ノード喪失時の復旧、実アプリでの性能は未検証。

## 0〜4 台の autoscale と並列キャッシュ (2026-11-15)

`maxRunners: 4` を cilium-cluster に適用した。
BuildKit は単一 daemon / PVC を維持し、`worker.oci.max-parallelism = 2` を設定。
runner ごとに独立した DinD とデータ用 emptyDir を使う。

検証 workflow はテスト repo の `.github/workflows/parallel.yaml` / `Dockerfile.parallel`。
以下の 4 matrix jobs を同時に投入し、[初回](https://github.com/sugaf1204/arc-cache-smoke-20261115/actions/runs/43709069979)、
[再実行](https://github.com/sugaf1204/arc-cache-smoke-20261115/actions/runs/43709431719)とも全件成功した。

| case | store scope | is-number の期待バージョン |
| --- | --- | --- |
| a | shared | 7.0.0 |
| b | shared | 6.0.0 |
| c | isolated-c | 7.0.0 |
| d | isolated-d | 6.0.0 |

scope の実際の prefix は `repo-1458627243-parallel-`、suffix は platform / toolchain。
scope の異なる cache mount 内で marker が混ざらないことと、同一 scope の同時書き込みがないことを検査した。
同一の RUN を BuildKit がまとめて処理しないよう case ID / 実行 nonce を RUN に渡し、
実行キャッシュを使わず mount のロックと pnpm store の再利用を実際に通した。
nonce は cache mount ID には含めていない。

再実行ログの cache mount 保持区間 (a の開始を 0 秒とした相対時間):

| case | 開始〜終了 (秒) |
| --- | --- |
| a | 0.00〜15.12 |
| b | 15.85〜30.96 |
| d | 29.99〜45.20 |
| c | 31.79〜46.91 |

b は a の開始から 0.14 秒後に build を要求していたが、同じ store の mount を使う RUN は
a の終了後まで開始しなかった。異なる store の c / d は約 13.42 秒重なって実行できた。
cache 内の atomic mkdir による同時アクセス検査も全件成功した。
15 秒の保持はロック検証用に加えたもので、実アプリの install 時間ではない。
再実行の全 4 件が `reused 2, downloaded 0` となった。

runner / DinD の分離と autoscale:

- 0 台から 4 台へ増え、4 ノードに 1 台ずつ Ready になった状態を観測した。
- 4 件の Docker daemon ID はすべて異なり、同じ `ci:latest` tag / `ci-common` container 名を同時に使えた。
- 各 build 内で dependency の実バージョンを検査し、DinD の実行出力も a:7.0.0 / b:6.0.0 / c:7.0.0 / d:6.0.0 と一致した。
- 終了後は runner Pod が 0 台に戻った。
- 同じ PVC / PV を維持し、変更後 BuildKit Pod の restart count は 0、最終状態は Ready。

実アプリの重いビルドを 4 件同時に処理する容量検証は含まない。
4 台は CI runner の上限で、BuildKit の重い worker step は同時 2 件まで。
共有 store の install には排他待ちが発生するが、別 scope の CI を全体で直列化する構成ではない。
