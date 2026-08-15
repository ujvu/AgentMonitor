# AgentMonitor — Deployment Storage

本目录用于存放 [AgentMonitor](https://github.com/ujvu/AgentMonitor) 运行所产生的素材与配置说明，
数据存储在 NAS 上，不占用本地磁盘。

> 本文档为通用部署说明，存放在 `docs/deployment-storage/`，与 AgentMonitor 主仓库 (Swift 源码) 并列维护。

## 目录结构

- `OCR/` — AgentMonitor 屏幕 OCR 识别产生的截图（每 3 秒一张，量大）
  - 由本机 `~/Library/Application Support/AgentMonitor/OCR` 软链接指向
  - 每天 03:00 由定时任务自动清理超过 24 小时的截图（LaunchAgent: `com.cuishiming.agentmonitor-cleanup`）

## 部署说明

- 数据建议放在 NAS，并通过本机软链接接入 AgentMonitor 数据目录
- 清理脚本：`~/bin/agentmonitor_cleanup.sh`
- 定时任务：`~/Library/LaunchAgents/com.cuishiming.agentmonitor-cleanup.plist`

## 设计动机

原本地 OCR 缓存容易膨胀至数十 GB，因此迁移到 NAS，并加自动清理任务。本目录作为该方案的
通用部署模板与说明。

## 维护

- 修改本目录后，提交到 GitHub：
  ```bash
  git add docs/deployment-storage/
  git commit -m "docs(deployment-storage): update storage notes"
  git push
  ```
- OCR 目录请保持为空目录占位（`.gitkeep`），不要上传真实截图
