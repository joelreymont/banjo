---
title: Send available models per engine
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-12T10:57:26.923785+02:00\""
closed-at: "2026-01-12T11:08:58.137495+02:00"
---

Backend sends models in state msg based on engine. nvim stores state.available_models. Commands/completions use dynamic list. Files: src/acp/agent.zig, src/nvim/handler.zig, nvim/lua/banjo/bridge.lua, nvim/lua/banjo/commands.lua, nvim/lua/banjo/panel.lua
