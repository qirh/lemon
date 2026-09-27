/**
 * Formatter for subagent tools: task and agent.
 *
 * Both take an `action` (run, poll, join; task also has get). `run` launches a
 * subagent from a prompt (agent targets a named `agent_id`); the others address
 * earlier launches by `task_id`/`task_ids`. Results and streaming updates report
 * a `status`, the subagent's `current_action`, and its output text.
 */

import { extractText, truncateLines, truncateText } from "./base.js";
import type { FormattedOutput, ToolFormatter } from "./types.js";

/** Maximum length for prompt preview in summary */
const PROMPT_SUMMARY_MAX_LENGTH = 60;

/** Maximum length for a subject or output line in a result summary */
const RESULT_SUMMARY_MAX_LENGTH = 80;

/** Maximum lines of details to show */
const DETAILS_MAX_LINES = 15;

/** Maximum lines of output text to show in result details */
const OUTPUT_MAX_LINES = 5;

/**
 * Returns the value when it is a non-empty string.
 *
 * @param value - The value to check
 * @returns The string, or undefined
 */
function nonEmptyString(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

/**
 * Keeps the string entries of an array value.
 *
 * @param value - Candidate array
 * @returns String entries, or an empty array
 */
function stringList(value: unknown): string[] {
	return Array.isArray(value)
		? value.filter((item): item is string => typeof item === "string")
		: [];
}

/**
 * Formats the subagent's current action with a phase indicator.
 *
 * @param action - The `current_action` details entry
 * @returns Formatted action line, or undefined when it has no title or kind
 */
function formatCurrentAction(action: Record<string, unknown>): string | undefined {
	const title = nonEmptyString(action.title) ?? nonEmptyString(action.kind);
	if (!title) {
		return undefined;
	}
	return action.phase === "completed" ? `✓ ${title}` : `▶ ${title}...`;
}

/**
 * Formats a task/agent result or streaming update.
 *
 * @param result - The raw result
 * @returns Formatted output
 */
function formatTaskResult(result: unknown): FormattedOutput {
	const obj: Record<string, unknown> =
		result && typeof result === "object" ? (result as Record<string, unknown>) : {};
	const details: Record<string, unknown> =
		obj.details && typeof obj.details === "object"
			? (obj.details as Record<string, unknown>)
			: {};

	const status = nonEmptyString(details.status);
	const currentAction =
		details.current_action && typeof details.current_action === "object"
			? (details.current_action as Record<string, unknown>)
			: undefined;
	const taskIds = stringList(details.task_ids);
	const joinedTasks = Array.isArray(details.tasks) ? details.tasks : [];
	const outputLines = extractText(result)
		.split(/\r?\n/)
		.filter((line) => line.trim().length > 0);

	const subject =
		nonEmptyString(currentAction?.title) ??
		nonEmptyString(currentAction?.kind) ??
		nonEmptyString(details.description) ??
		nonEmptyString(details.agent_id) ??
		(taskIds.length > 0 ? `${taskIds.length} task${taskIds.length === 1 ? "" : "s"}` : undefined) ??
		nonEmptyString(details.task_id);

	let summary: string;
	if (status && subject) {
		summary = `${status}: ${truncateText(subject, RESULT_SUMMARY_MAX_LENGTH)}`;
	} else if (status || subject) {
		summary = truncateText((status ?? subject) as string, RESULT_SUMMARY_MAX_LENGTH);
	} else if (outputLines.length > 0) {
		summary = truncateText(outputLines[0].trim(), RESULT_SUMMARY_MAX_LENGTH);
	} else {
		summary = "completed";
	}

	const lines: string[] = [];
	if (status) {
		lines.push(`status: ${status}`);
	}
	for (const key of ["task_id", "agent_id", "role"]) {
		const value = nonEmptyString(details[key]);
		if (value) {
			lines.push(`${key}: ${value}`);
		}
	}
	const actionLine = currentAction ? formatCurrentAction(currentAction) : undefined;
	if (actionLine) {
		lines.push(actionLine);
	}
	for (const entry of joinedTasks) {
		if (!entry || typeof entry !== "object") {
			continue;
		}
		const task = entry as Record<string, unknown>;
		const id = nonEmptyString(task.task_id) ?? "?";
		const taskStatus = nonEmptyString(task.status) ?? "unknown";
		const description = nonEmptyString(task.description);
		lines.push(description ? `${id}: ${taskStatus} (${description})` : `${id}: ${taskStatus}`);
	}
	const error = nonEmptyString(details.error);
	if (error) {
		lines.push(`error: ${error}`);
	}
	if (outputLines.length > 0) {
		if (lines.length > 0) {
			lines.push("");
		}
		lines.push(...truncateLines(outputLines, OUTPUT_MAX_LINES));
	}

	return {
		summary,
		details: truncateLines(lines, DETAILS_MAX_LINES),
		isError: obj.is_error === true || status === "error",
	};
}

/**
 * Formatter for the task and agent tools.
 */
export const taskFormatter: ToolFormatter = {
	tools: ["task", "agent"],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const action = nonEmptyString(args.action) ?? "run";
		const agentId = nonEmptyString(args.agent_id);
		const taskId = nonEmptyString(args.task_id);
		const taskIds = stringList(args.task_ids);

		const promptText = nonEmptyString(args.prompt) ?? nonEmptyString(args.description) ?? "";
		const promptPreview = promptText
			? truncateText(promptText.replace(/\s+/g, " ").trim(), PROMPT_SUMMARY_MAX_LENGTH)
			: "";

		// Summary: what the call addresses — a prompt for run, task ids otherwise.
		let summary: string;
		if (action === "run") {
			const head = agentId ? `run ${agentId}` : "run";
			summary = promptPreview ? `${head}: ${promptPreview}` : head;
		} else if (taskIds.length > 1) {
			summary = `${action} ${taskIds.length} tasks`;
		} else {
			const target = taskIds[0] ?? taskId;
			summary = target ? `${action} ${target}` : action;
		}

		const details: string[] = [`action: ${action}`];
		for (const key of ["agent_id", "role", "model", "task_id", "mode", "node", "cwd"]) {
			const value = nonEmptyString(args[key]);
			if (value) {
				details.push(`${key}: ${value}`);
			}
		}
		if (taskIds.length > 0) {
			details.push(`task_ids: ${taskIds.join(", ")}`);
		}
		if (typeof args.async === "boolean") {
			details.push(`async: ${args.async}`);
		}

		if (promptText) {
			details.push("");
			details.push(...truncateLines(promptText.split(/\r?\n/), 10));
		}

		return {
			summary,
			details: truncateLines(details, DETAILS_MAX_LINES),
		};
	},

	formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
		return formatTaskResult(result);
	},

	formatPartial(partial: unknown, _args?: Record<string, unknown>): FormattedOutput {
		// Streaming updates carry the same status/current_action details.
		return formatTaskResult(partial);
	},
};

export default taskFormatter;
