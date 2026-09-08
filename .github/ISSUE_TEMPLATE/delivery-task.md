---
name: Delivery Task
description: 一條可直接交給 Codex/Luna 執行並由 Sol Gate 驗收的完整交付流程
title: "[P0][DELIVERY] "
labels: []
assignees: []
---

## GOAL
一句話描述使用者完成後能得到什麼實際結果，不要只寫 provider、fixture、package 或測試動作。

## CURRENT BASELINE
先讀 `AGENTS.md` 及相關 architecture/security/provenance 文件，記錄 branch / HEAD / dirty state、唯一最新 handoff（若存在）與本 Issue 相關成果/限制。禁止 reset/clean/stash/覆蓋既有成果。

## SCOPE
完成一條完整可驗收流程，以及必要最小程式、provider/publisher、資料、測試與文件修改。

## NOT TO DO
不開第二條大型功能線、不重做已驗收內容、不讓 optional adapter 變成 hidden fallback、不破壞 offline/std-lib-only base、不執行未授權 live API/remote publish/release、不重構無關模組、不建不必要平台/監控/大量報告。

## DEPENDENCIES
真正阻塞的前置 Issue、外部事件、授權或人工 Gate；沒有寫 `None`。

## SHARED CAPABILITY CHECK
Registry technical_stable → experimental → 專案既有 → 官方 → 成熟 OSS → 最後才新增。只有實際改善產品結果才採用。

## IMPLEMENTATION
Codex/Luna 自行完成最小必要修改；維持 provider/publisher 邊界、provenance、rights 與 public/private separation。

## VALIDATION
依變更範圍執行既有 Verification。Fixture/offline PASS 只證明對應 boundary，不可冒充 live provider、rights、quality、remote publish 或 release approval；文件/治理修改不跑無關完整測試。

## EVIDENCE
只保留足以讓 Sol 判斷成功/失敗的本輪證據；歷史 evidence 不得冒充本輪驗證。

## FAILURE POLICY
同一失敗假設最多兩次無進展嘗試；分類：`PRODUCT` / `VALIDATION` / `EXTERNAL` / `HUMAN_AUTH` / `EVIDENCE_INSUFFICIENT`。

## ACCEPTANCE
- [ ] 使用者流程完整
- [ ] P0/P1=0 或狀態正確保持 PARTIAL/FAIL
- [ ] scope drift=0
- [ ] 必要 verification 通過
- [ ] offline/security/provenance/license 邊界未破壞
- [ ] 有本輪產品證據
- [ ] 無明顯回歸
- [ ] Git 可回退
- [ ] Sol Gate 完成

## GIT
只提交本 Issue 可分離且已驗證修改，不夾帶未知 dirty work。公開 release 仍需另行明確授權。

## REPORT
只回填：`RESULT`、`FILES_CHANGED`、`USER_VISIBLE_RESULT`、`VALIDATION`、`EVIDENCE`、`PROVENANCE/RIGHTS`（若適用）、`KNOWN_ISSUES`、`SCOPE_DRIFT`、`COMMIT`、`NEXT_SINGLE_ACTION`。
