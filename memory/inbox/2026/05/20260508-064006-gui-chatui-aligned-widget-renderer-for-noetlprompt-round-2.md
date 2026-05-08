# GUI: chatui-aligned widget renderer for NoetlPrompt (round 2)
- Timestamp: 2026-05-08T06:40:06Z
- Author: unknown
- Tags: gui,widgets,chatui-reference,noetl-as-ai-os,round-2,prompt,markdown,iframe

## Summary
Built repos/gui/src/components/widgets/ — discriminated WidgetContent union plus 35 components (every chatui app:* widget + AppCode/AppIframe/AppLink NoETL extensions). WidgetRenderer.tsx dispatches by chatui's '{type, args}' convention; class ErrorBoundary catches throws (no react-error-boundary dep). AppMarkdown ships a tiny dependency-free markdown subset (no react-markdown dep). NoetlPrompt's PromptEntry gains render?: WidgetContent; the 'report' command extracts {render: {type, args}} from execution result/events via new extractAgentRender helper in services/agentResult.ts. handleWidgetEvent bridges chatui WidgetMessageEvent into prompt actions: key=='command' invokes runCommand(value), key=='navigate' navigates. references/chatui submodule is read-only per AGENTS.md. Documented in repos/docs/docs/gui/widgets.md with full per-kind contract table. tsc --noEmit passes clean. NO noetl python changes.

## Actions
-

## Repos
-

## Related
-
