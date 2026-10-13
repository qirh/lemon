import { ansi, node } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import type { ToolBlock } from "../store/transcript-model.ts";
import { renderDiff } from "../ui/components/diff.ts";
import { type ToolCardState, type ToolView, toolArgs } from "../ui/tool-view.ts";
import { fileTarget } from "./links.ts";

const STATUS = {
	streaming: "pending",
	running: "running",
	success: "done",
	error: "error",
} as const satisfies Record<ToolCardState, string>;

/** Keep native calls semantic so Tern can render and Carly can read their metadata. */
export function nativeTool(
	block: ToolBlock,
	view: ToolView,
	collapsed: boolean,
	elapsed: number,
): NativeNode {
	const args = toolArgs(block);
	const command = typeof args.command === "string" ? args.command : undefined;
	const path = typeof args.path === "string" ? args.path : undefined;
	const pattern = typeof args.pattern === "string" ? args.pattern : undefined;
	const query = typeof args.query === "string" ? args.query : undefined;
	const target = command ?? path ?? pattern ?? query;
	const targetKind = command
		? "command"
		: path
			? "path"
			: pattern
				? "pattern"
				: query
					? "query"
					: undefined;
	const body = view.diff
		? renderDiff(view.diff.text, { path: view.diff.path }).join("\n")
		: view.body.join("\n");
	return node(
		"tool",
		{
			name: view.toolName ?? view.kind,
			title: view.title,
			target,
			targetKind,
			href: path ? fileTarget(path) : undefined,
			meta: view.summary ? [view.summary] : undefined,
			status: STATUS[view.state],
			...(block.phase === "completed" ? { took: elapsed } : { age: elapsed }),
			collapsible: body.length > 0,
			collapsed,
			frame: "inline",
		},
		body ? [ansi(body)] : [],
	);
}
