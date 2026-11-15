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
