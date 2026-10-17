# Local agent runtime: kind: agent, credential store, agent-playbooks
- Timestamp: 2026-10-17T05:14:36Z
- Author: kadyapam
- Tags: agent,cli,tools,credentials,gmail,pypi

## Summary
kind: agent is back in Rust for --runtime local (noetl-tools 4.1.0/4.2.0, CLI 5.1.0-5.3.0, executor 0.11-0.13, PyPI wrapper 5.2.0/5.3.0). Frameworks: claude (Messages API; AgentSession is turn-by-turn so the CLI runs each tool as a sub-playbook between turns) and claude-code (headless claude -p on a Claude subscription; ANTHROPIC_API_KEY/AUTH_TOKEN stripped). Local credential store: alias X from NOETL_CREDENTIAL_X or ~/.config/noetl/credentials/X (mode 600 enforced); http auth bearer/api_key/google_oauth; noetl credential set|google|list|path (installed-app OAuth + PKCE). Live: four Gmail inboxes triaged read-only at ~2-3c/run on Haiku (thinking: disabled, Primary tab, rhai-compacted tool output, prompt caching) vs $0.35 on Sonnet. Defects found: max_tokens with only a thinking block reported as success (fixed tools 4.2.0); render_template re-expanded substituted values (cli#98 open; defang_template_markers is the stopgap). Server still rejects agent (local only). Showcase: github.com/noetl/agent-playbooks. Tracks noetl/ai-meta#474.

## Actions
-

## Repos
-

## Related
-
