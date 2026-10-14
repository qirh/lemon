/**
 * Formatter for the browser tools (browser_*).
 *
 * Arguments summarize by each tool's key argument (url, selector, key, tab id,
 * expression...). Results carry the browser payload in `details` (the
 * text content is the same payload as JSON) and summarize by what the call
 * produced: page title/url, saved artifact path, tab/event/cookie counts, or
 * page text.
 */

import { extractText, formatBytes, safeStringify, truncateLines, truncateText } from "./base.js";
import type { FormattedOutput, ToolFormatter } from "./types.js";
import { shortenUrl } from "./web.js";

/** Maximum length for a value preview in a summary */
const SUMMARY_VALUE_MAX_LENGTH = 60;

/** Maximum length for a detail line */
const DETAIL_LINE_MAX_LENGTH = 120;

/** Maximum lines of page text to show in details */
const TEXT_MAX_LINES = 8;

/** Argument keys shown as `key: value` detail lines, in display order */
const ARG_DETAIL_KEYS = [
	"url",
	"targetId",
	"selector",
	"key",
	"text",
	"value",
	"path",
	"expression",
	"prompt",
	"route",
	"timeoutMs",
];

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
 * Collapses whitespace and truncates a value for a one-line preview.
 *
 * @param value - The text to preview
 * @param maxLength - Maximum preview length
 * @returns Single-line preview
 */
function preview(value: string, maxLength = SUMMARY_VALUE_MAX_LENGTH): string {
	return truncateText(value.replace(/\s+/g, " ").trim(), maxLength);
}

/**
 * Builds the one-line argument summary from the tool's key argument.
 *
 * @param args - The tool arguments
 * @returns Summary text (empty for argument-less tools)
 */
function summarizeArgs(args: Record<string, unknown>): string {
	const url = nonEmptyString(args.url);
	if (url) {
		return shortenUrl(url);
	}

	const selector = nonEmptyString(args.selector);
	const key = nonEmptyString(args.key);
	if (key) {
		return selector ? `${key} on ${preview(selector)}` : key;
	}

	if (selector) {
		const text = typeof args.text === "string" ? args.text : undefined;
		if (text !== undefined) {
			return `${preview(selector, 40)} ← "${preview(text, 40)}"`;
		}
		const values = Array.isArray(args.values)
			? args.values.filter((value): value is string => typeof value === "string")
			: [];
		const value = nonEmptyString(args.value) ?? (values.length > 0 ? values.join(", ") : undefined);
		if (value) {
			return `${preview(selector, 40)} = ${preview(value, 40)}`;
		}
		const paths = Array.isArray(args.paths)
			? args.paths.filter((path): path is string => typeof path === "string")
			: [];
		const path = nonEmptyString(args.path) ?? (paths.length > 0 ? paths.join(", ") : undefined);
		if (path) {
			return `${preview(selector, 40)} ← ${preview(path, 40)}`;
		}
		return preview(selector);
	}

	const expression = nonEmptyString(args.expression);
	if (expression) {
		return preview(expression);
	}

	const targetId = nonEmptyString(args.targetId);
	if (targetId) {
		return `tab ${targetId}`;
	}

	if (Array.isArray(args.cookies)) {
		const count = args.cookies.length;
		return `${count} cookie${count === 1 ? "" : "s"}`;
	}

	const path = nonEmptyString(args.path);
	if (path) {
		return path;
	}

	const prompt = nonEmptyString(args.prompt);
	if (prompt) {
		return preview(prompt);
	}

	const scroll = ["x", "y", "deltaX", "deltaY"]
		.filter((axis) => typeof args[axis] === "number")
		.map((axis) => `${axis}=${args[axis]}`);
	return scroll.join(" ");
}

/**
 * Reads the browser payload from a result: `details`, else the JSON text.
 *
 * @param result - The raw tool result
 * @returns The payload object, or an empty object
 */
function resultPayload(result: unknown): Record<string, unknown> {
	if (result && typeof result === "object") {
		const details = (result as { details?: unknown }).details;
		if (details && typeof details === "object" && !Array.isArray(details)) {
			return details as Record<string, unknown>;
		}
	}

	try {
		const parsed: unknown = JSON.parse(extractText(result));
		if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
			return parsed as Record<string, unknown>;
		}
	} catch {
		// Not JSON (e.g. an error message or a truncated preview)
	}
	return {};
}

/**
 * Counts an array-valued payload key.
 *
 * @param payload - The browser payload
 * @param key - The key holding the array
 * @returns The array length, or undefined when the key is not an array
 */
function listCount(payload: Record<string, unknown>, key: string): number | undefined {
	const value = payload[key];
	return Array.isArray(value) ? value.length : undefined;
}

/**
 * Formatter for every browser tool.
 */
export const browserFormatter: ToolFormatter = {
	tools: [
		"browser_navigate",
		"browser_tabs",
		"browser_tab_open",
		"browser_tab_activate",
		"browser_tab_close",
		"browser_snapshot",
		"browser_get_content",
		"browser_click",
		"browser_type",
		"browser_hover",
		"browser_select_option",
		"browser_upload_file",
		"browser_download",
		"browser_press",
		"browser_scroll",
		"browser_back",
		"browser_wait_for_selector",
		"browser_evaluate",
		"browser_events",
		"browser_get_cookies",
		"browser_set_cookies",
		"browser_clear_state",
		"browser_screenshot",
		"browser_analyze",
	],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const details: string[] = [];
		for (const key of ARG_DETAIL_KEYS) {
			const value = args[key];
			if (typeof value === "string" || typeof value === "number") {
				details.push(truncateText(`${key}: ${value}`, DETAIL_LINE_MAX_LENGTH));
			}
		}

		return {
			summary: summarizeArgs(args),
			details,
		};
	},

	formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
		const payload = resultPayload(result);
		const toolError =
			!!result &&
			typeof result === "object" &&
			(result as { is_error?: unknown }).is_error === true;
		const details: string[] = [];

		if (toolError) {
			const lines = extractText(result)
				.split(/\r?\n/)
				.filter((line) => line.trim().length > 0);
			return {
				summary: lines.length > 0 ? preview(lines[0], 80) : "failed",
				details: truncateLines(lines, TEXT_MAX_LINES),
				isError: true,
			};
		}

		const parts: string[] = [];
		const title = nonEmptyString(payload.title);
		const url = nonEmptyString(payload.url);
		if (title) {
			parts.push(preview(title, 50));
		}
		if (url) {
			parts.push(shortenUrl(url));
			details.push(truncateText(`url: ${url}`, DETAIL_LINE_MAX_LENGTH));
		}

		// Screenshot/download artifacts; browser_analyze nests the screenshot.
		const screenshot =
			payload.screenshot && typeof payload.screenshot === "object"
				? (payload.screenshot as Record<string, unknown>)
				: payload;
		const path = nonEmptyString(screenshot.path);
		if (path) {
			const bytes =
				typeof screenshot.bytes === "number" ? ` (${formatBytes(screenshot.bytes)})` : "";
			parts.push(`saved ${path}${bytes}`);
			details.push(`path: ${path}`);
		}

		const targetId = nonEmptyString(payload.targetId);
		if (targetId) {
			details.push(`targetId: ${targetId}`);
			if (parts.length === 0) {
				parts.push(`tab ${targetId}`);
			}
		}

		const counted: Array<[string, string]> = [
			["tabs", "tab"],
			["events", "event"],
			["cookies", "cookie"],
		];
		for (const [key, noun] of counted) {
			const count = listCount(payload, key) ?? (key === "events" ? payload.count : undefined);
			if (typeof count === "number") {
				parts.push(`${count} ${noun}${count === 1 ? "" : "s"}`);
			}
		}

		if ("result" in payload && payload.result !== undefined) {
			const value =
				typeof payload.result === "string" ? payload.result : safeStringify(payload.result);
			details.push(truncateText(`result: ${value}`, DETAIL_LINE_MAX_LENGTH));
			if (parts.length === 0) {
				parts.push(preview(value));
			}
		}

		// Page text from snapshot/get_content.
		const pageText = nonEmptyString(payload.text) ?? nonEmptyString(payload.snapshot);
		if (pageText) {
			const lines = pageText.split(/\r?\n/).filter((line) => line.trim().length > 0);
			details.push(
				...truncateLines(
					lines.map((line) => truncateText(line, DETAIL_LINE_MAX_LENGTH)),
					TEXT_MAX_LINES,
				),
			);
			if (parts.length === 0 && lines.length > 0) {
				parts.push(preview(lines[0]));
			}
		}

		const error = nonEmptyString(payload.error);
		if (error) {
			details.push(`error: ${truncateText(error, DETAIL_LINE_MAX_LENGTH)}`);
		}
		const isError = payload.ok === false || error !== undefined;

		let summary = parts.join(" · ");
		if (error) {
			summary = summary ? `${summary} · ${preview(error)}` : preview(error);
		} else if (!summary) {
			summary = isError ? "failed" : "done";
		}

		return { summary, details, isError };
	},

	formatPartial(partial: unknown, _args?: Record<string, unknown>): FormattedOutput {
		// Progress updates: {tool, method, phase, current_action: {title, phase}}.
		const payload = resultPayload(partial);
		const action =
			payload.current_action && typeof payload.current_action === "object"
				? (payload.current_action as Record<string, unknown>)
				: {};
		const title = nonEmptyString(action.title) ?? nonEmptyString(payload.method) ?? "browser";
		const phase = nonEmptyString(action.phase) ?? nonEmptyString(payload.phase);

		return {
			summary: phase ? `${title} (${phase})` : title,
			details: [],
			isError: phase === "failed",
		};
	},
};

export default browserFormatter;
