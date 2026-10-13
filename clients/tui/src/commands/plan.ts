import { ControlPlaneError, NotConnectedError } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type { SessionsPlanResult } from "../protocol/types.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

const USAGE = [
	"/plan [status|show] — show mode, status and the current Markdown artifact",
	"/plan enter [request…] — enter read-only planning; optionally send a planning request",
	"/plan approve — review the current artifact and explicitly confirm its exact revision",
	"/plan discard — leave planning without approving the artifact",
];

export const planCommand: SlashCommand = {
	name: "plan",
	summary: "inspect, enter, review or discard native session planning",
	usage: "[status|show|enter [request…]|approve|discard]",
	group: "sessions",
	methods: [METHOD.sessionsPlan],
	async run(ctx, argv) {
		const action = argv[0] ?? "status";
		if (action === "help") {
			ctx.ui.noticeBlock(USAGE);
			return;
		}
		if (
			!["status", "show", "enter", "approve", "discard"].includes(action) ||
			(action !== "enter" && argv.length > 1)
		) {
			ctx.ui.noticeBlock(USAGE, "warning");
			return;
		}
		if (!["status", "show"].includes(action) && ctx.session.busy) {
			ctx.ui.notice("stop the current run before changing planning mode", "warning");
			return;
		}
		const target = { sessionKey: ctx.session.key, cwd: ctx.cwd ?? process.cwd() };
		const request = action === "enter" ? ctx.rest.replace(/^\s*enter\b\s*/, "").trim() : "";
		if (request && !ctx.ui.deliverPrompt) {
			ctx.ui.notice(
				"this build cannot send a planning request; use /plan enter then send a prompt",
				"warning",
			);
			return;
		}
		try {
			const result = await ctx.methods.sessionsPlan({
				...target,
				action: action === "enter" || action === "discard" ? action : "status",
			});
			assertPlan(result, target.sessionKey);
			if (ctx.store.focusedKey !== target.sessionKey) return;
			showPlan(ctx, result);
			if (action === "approve") {
				if (
					result.plan.status !== "pending" ||
					!result.plan.revision ||
					!result.plan.path ||
					!result.plan.content?.trim()
				) {
					ctx.ui.notice(
						"only a completed pending artifact can be approved; finish planning first",
						"warning",
					);
					return;
				}
				const revision = result.plan.revision;
				let settled = false;
				ctx.ui.openPicker({
					title: "approve this reviewed plan?",
					detail: [
						`Revision: ${revision}`,
						`Artifact: ${result.plan.path}`,
						"Full Markdown is in the transcript. Cancel to read it before approving.",
						"Approval permits code mode; it does not start execution.",
					],
					items: [
						{ value: "cancel", label: "Cancel — read the artifact or keep planning" },
						{
							value: "approve",
							label: "I reviewed this revision — approve",
							description: revision,
						},
					],
					footer: "cancel is selected by default · approve only the revision you reviewed",
					onCancel: () => {
						settled = true;
					},
					onSelect: async (choice) => {
						if (settled) return;
						settled = true;
						if (choice.value !== "approve") return;
						if (ctx.store.focusedKey !== target.sessionKey || ctx.session.busy) {
							ctx.ui.notice(
								"plan approval canceled because the focused session or run changed",
								"warning",
							);
							return;
						}
						try {
							const approved = await ctx.methods.sessionsPlan({
								...target,
								action: "approve",
								revision,
							});
							assertPlan(approved, target.sessionKey);
							if (
								approved.plan.status !== "approved" ||
								approved.plan.mode !== "code" ||
								approved.plan.revision !== revision
							) {
								throw new Error("unexpected approval receipt");
							}
							if (ctx.store.focusedKey !== target.sessionKey) return;
							ctx.ui.notice(
								"plan approved; nothing was executed. Send a prompt such as ‘Execute the approved plan’ when ready.",
							);
						} catch (error) {
							failure(ctx, error);
						}
					},
				});
			} else if (action === "enter") {
				if (result.plan.mode !== "plan") throw new Error("planning mode was not entered");
				ctx.ui.notice(
					"read-only planning is active; completed plans need explicit /plan approve before execution",
				);
				if (request) await ctx.ui.deliverPrompt!(request, "queue");
			} else if (action === "discard") {
				if (result.plan.mode !== "code" || result.plan.status !== "none")
					throw new Error("plan discard was not confirmed");
				ctx.ui.notice("planning discarded without approval; nothing was executed");
			} else {
				ctx.ui.noticeBlock(USAGE);
			}
		} catch (error) {
			failure(ctx, error);
		}
	},
};

function showPlan(ctx: CommandContext, result: SessionsPlanResult): void {
	const { plan } = result;
	ctx.ui.noticeBlock([
		`plan · mode: ${plan.mode} · status: ${plan.status}`,
		...(plan.revision ? [`revision: ${plan.revision}`] : []),
		...(plan.path ? [`artifact: ${plan.path}`] : []),
		...(plan.content !== null ? [plan.content] : ["no completed Markdown artifact"]),
	]);
}

function assertPlan(result: SessionsPlanResult, sessionKey: string): void {
	const plan = result?.plan;
	if (
		result?.sessionKey !== sessionKey ||
		!plan ||
		!["code", "plan"].includes(plan.mode) ||
		!["none", "draft", "pending", "approved"].includes(plan.status) ||
		![plan.revision, plan.path, plan.content].every(
			(value) => value === null || typeof value === "string",
		)
	)
		throw new Error("invalid plan receipt");
}

function failure(ctx: CommandContext, error: unknown): void {
	const code =
		error instanceof ControlPlaneError || error instanceof NotConnectedError
			? error.code
			: "OUTCOME_UNKNOWN";
	ctx.ui.notice(
		`plan operation did not complete (${code}); use /plan to review current state before retrying. No execution prompt was sent.`,
		"error",
	);
}
