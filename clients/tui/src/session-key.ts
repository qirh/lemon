/** A canonical channel-peer key, not a subagent or a shared main session. */
export function newSessionKey(): string {
	return `agent:default:tui:local:dm:${crypto.randomUUID()}`;
}
