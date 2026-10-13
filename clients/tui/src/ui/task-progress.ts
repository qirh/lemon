import { extractText } from "../formatters/base.ts";
import type { AgentToolUseEvent } from "../protocol/types.ts";

/** Child progress is independent of the parent tool's already-completed launch receipt. */
export function taskProgressEvent(event: AgentToolUseEvent): AgentToolUseEvent | undefined {
	const detail = event.action?.detail;
	if (event.phase !== "updated" || (detail?.name !== "task" && detail?.name !== "agent")) {
		return undefined;
	}
	const partial = record(detail.partial_result);
	const details = record(partial?.details);
	const taskId = details?.task_id;
	if (!details || typeof taskId !== "string" || taskId.length === 0) return undefined;
	const status = details.status;
	const failed = status === "error" || status === "aborted" || status === "cancelled";
	const completed = status === "completed" || failed;
	const description = typeof details.description === "string" ? details.description : taskId;
	return {
		...event,
		phase: completed ? "completed" : "updated",
		ok: completed ? !failed : undefined,
		action: {
			id: `${event.action.id ?? "task"}:child:${taskId}`,
			kind: "subagent",
			title: description,
			detail: {
				name: detail.name,
				args: { task_id: taskId },
				partial_result: partial,
				details,
				result: extractText(partial),
			},
		},
	};
}

function record(value: unknown): Record<string, unknown> | undefined {
	return value !== null && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}
