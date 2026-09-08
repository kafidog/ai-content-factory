# Repository agent instructions

## Product boundary

- Current status: public OSS release v0.1.0 on GitHub.
- Keep the default Python 3.11 runtime standard-library-only and offline.
- Preserve unrelated worktree changes. Never reset, clean, stash, or overwrite
  another contributor's work.
- Do not perform live API calls, remote publishing, browser automation,
  credential setup, payment, deployment, or release publication without a
  separate explicit authorization.
- The v0.1.0 release is already public; future releases and public publication
  actions still require separate explicit authorization.
- Never add real secrets, private paths, private assets, personal data, account
  identifiers, or private brand names to tracked files.

## Architecture

- Core code owns generic contracts, orchestration, integrity, QA, and local
  packages. Vendor behavior belongs behind provider/publisher interfaces.
- The fixture registry is the default. Optional adapters must be explicitly
  selected and may not become hidden fallbacks.
- Product-native tools, model runtimes, and local media tools are optional
  adapters. The base demo cannot depend on them.
- Brand assets and production configuration belong in an external private
  layer and must not be copied into this repository.

## Media boundary

- Call still-image transforms `MOTION_RENDER`; do not claim synthesized subject
  motion.
- Imported media requires explicit provenance and rights status. Unknown rights
  block materialization into a review package.
- Model weights, caches, browser state, and private media never belong in the
  source release candidate.

## Security and provenance

- Keep scanner output redacted. Store private brand denylist entries only as
  SHA-256 fingerprints.
- Record non-trivial source, dependency, and design decisions in
  `PROVENANCE_LEDGER.md`.
- A local scan or fixture test is evidence for that boundary only, not proof of
  live provider, rights, quality, or public-release approval.
- Build public candidates only with `public_release_manifest.json` and
  `scripts/build_release_candidate.py`; never copy the whole worktree.

## Verification

```text
python -B -m unittest discover -s tests -p "test_*.py"
python -B scripts/public_ci.py
python -B scripts/security_scan.py --root . --brand-hash-file scripts/public_brand_hashes.sha256
python -B -m ai_content_factory demo --output output
python -B -m ai_content_factory inspect --output output
python -B -m ai_content_factory validate --output output
```

Apache-2.0 covers project code only. External adapters, tools, models, fonts,
and user assets retain their own terms and must be documented separately.

## Cross-project delivery governance

本節只統一 AI/Codex 執行流程；上面的 OSS、offline、security、provenance、license、release 與 adapter 邊界全部保留，且任何更嚴格限制優先。

### Astra Era
- `Astra Medium`：新 Phase、重大方向改變、重複失敗或 Final Review 才進場；負責全局理解、架構、P0/P1/P2、Delivery Issue、依賴、Gate 與風險。
- `Sol High`：執行期 Supervisor / Reviewer / Final Gate；負責範圍、Git、測試、Evidence、provenance 與最終判定。
- `Luna MAX`：主要 Executor；負責 implementation、research、tests、fixes、documentation、evidence。
- 升級順序：`Luna MAX → Sol High → Astra Medium → Astra High → Astra XHigh`；High/XHigh 僅真正僵局、重大架構衝突、反覆失敗或高風險不可逆決策。

### Goal → Delivery Issue → Codex/Luna → Evidence → Sol Gate
- 一個 Delivery Issue = 一條可由實際使用者驗收、可獨立交付的完整流程，不拆成微型 Issue 海。
- 正常執行只讀永久規則、唯一最新 handoff（若存在）與當前最高優先且已解除阻塞的 Delivery Issue。
- 同一時間只執行一個 Delivery Issue；小型已定位修復可直接最小修改、驗證、提交。
- 不重做已驗收內容，不用 fixture、包裝或報告成功代替產品成功。

### 交付優先與失敗處理
- 產品修改先跑最小相關測試，交付前一次必要整體驗證；純文件/治理修改不重跑完整產品測試。
- 同一失敗假設最多兩次無進展嘗試；分類只用 `PRODUCT`、`VALIDATION`、`EXTERNAL`、`HUMAN_AUTH`、`EVIDENCE_INSUFFICIENT`。
- 只有登入、OAuth、2FA、CAPTCHA、條款、人工授權、目前環境無法控制的實體裝置或真正外部事件才算 HUMAN_AUTH/EXTERNAL。
- 外部等待只留下恢復條件，不建 AI 值班、輪詢或監控平台。
- 保留既有 worktree、資料、授權與未知修改；不得為了乾淨 reset/clean/stash/覆蓋他人成果。

### 共享能力
從產品缺口依序查 Registry `technical_stable` → `experimental` → 專案既有能力 → 官方能力/工具 → 成熟 OSS → 最後才新增工具。安裝、Registry 登記、技能數、provider 接上、包裝成功或測試 PASS 都不等於產品改善；只有「實際套入產品 → 可見/可測改善 → 無明顯回歸 → Sol 接受」才算落地。專案專用 adapter/邏輯不要為了共享而過早抽象化。

### 驗證、證據與 Git
- 原有 Verification 指令依變更範圍執行；fixture/offline 測試只能證明對應 boundary，不能冒充 live provider、rights、quality、remote publishing 或 release approval。
- 歷史 evidence 不得冒充本輪驗證；驗證工具失敗與產品失敗分開。
- 證據少而有效，不按代理角色複製大量報告或 ZIP。
- 只修改當前 Delivery Issue 最小必要範圍；禁止 `git reset --hard`、`git clean -fd`、force push、改寫已發布歷史或刪除未知資料。
- 只有 P0/P1=0、scope drift=0、必要驗證完成且 Sol Gate 通過，才可宣稱該 Delivery Issue PASS；公開 release 仍需原有 separate explicit authorization。
