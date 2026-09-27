/**
 * Tests for the task/agent formatter.
 */

import { describe, expect, it } from "bun:test";
import { taskFormatter } from "../../src/formatters/task.js";

describe("taskFormatter.formatArgs", () => {
	it("shows action with prompt preview in summary", () => {
		const result = taskFormatter.formatArgs({
			action: "run",
			prompt: "Analyze the codebase and find all security vulnerabilities",
		});

		expect(result.summary).toBe("run: Analyze the codebase and find all security vulnerabilities");
	});

	it("truncates long prompts in summary", () => {
		const longPrompt =
			"This is a very long prompt that exceeds the maximum length for display in the summary line and should be truncated with an ellipsis";
		const result = taskFormatter.formatArgs({
			action: "run",
			prompt: longPrompt,
		});

		expect(result.summary.length).toBeLessThanOrEqual(70);
		expect(result.summary).toContain("...");
	});

	it("uses description when prompt is not provided", () => {
		const result = taskFormatter.formatArgs({
			action: "run",
			description: "Run integration tests",
		});

		expect(result.summary).toBe("run: Run integration tests");
	});

	it("defaults action to run when not provided", () => {
		const result = taskFormatter.formatArgs({});

		expect(result.summary).toBe("run");
		expect(result.details).toContain("action: run");
	});

	it("collapses whitespace in prompt preview", () => {
		const result = taskFormatter.formatArgs({
			action: "run",
			prompt: "Multiple\n\n\nline   breaks   and    spaces",
		});

		expect(result.summary).toBe("run: Multiple line breaks and spaces");
	});

	it("names the target agent for agent runs", () => {
		const result = taskFormatter.formatArgs({
			agent_id: "reviewer",
			prompt: "Review the diff",
			async: true,
		});

		expect(result.summary).toBe("run reviewer: Review the diff");
		expect(result.details).toContain("agent_id: reviewer");
		expect(result.details).toContain("async: true");
	});

	it("addresses a task id for poll/get", () => {
		const result = taskFormatter.formatArgs({ action: "poll", task_id: "task-123-abc" });

		expect(result.summary).toBe("poll task-123-abc");
		expect(result.details).toContain("task_id: task-123-abc");
	});

	it("counts task ids for join", () => {
		const result = taskFormatter.formatArgs({
			action: "join",
			task_ids: ["t1", "t2", "t3"],
			mode: "wait_any",
		});

		expect(result.summary).toBe("join 3 tasks");
		expect(result.details).toContain("task_ids: t1, t2, t3");
		expect(result.details).toContain("mode: wait_any");
	});

	it("shows just the action when nothing is addressed", () => {
		expect(taskFormatter.formatArgs({ action: "poll" }).summary).toBe("poll");
	});

	it("truncates prompt lines in details", () => {
		const manyLines = Array.from({ length: 20 }, (_, i) => `Line ${i + 1}`).join("\n");
		const result = taskFormatter.formatArgs({
			action: "run",
			prompt: manyLines,
		});

		expect(result.details.length).toBeLessThanOrEqual(16);
	});
});

describe("taskFormatter.formatResult", () => {
	it("summarizes a queued async launch", () => {
		const result = taskFormatter.formatResult({
			content: [{ type: "text", text: "Task queued: task-1" }],
			details: { task_id: "task-1", status: "queued", description: "Audit auth", run_id: "r1" },
			is_error: false,
		});

		expect(result.summary).toBe("queued: Audit auth");
		expect(result.details).toContain("status: queued");
		expect(result.details).toContain("task_id: task-1");
		expect(result.details).toContain("Task queued: task-1");
		expect(result.isError).toBe(false);
	});

	it("shows the answer text of a completed run", () => {
		const result = taskFormatter.formatResult({
			content: [{ type: "text", text: "Found 3 issues\n1. SQL injection" }],
			details: { status: "completed", description: "Audit auth" },
			is_error: false,
		});

		expect(result.summary).toBe("completed: Audit auth");
		expect(result.details).toContain("Found 3 issues");
		expect(result.details).toContain("1. SQL injection");
	});

	it("names the agent of a completed agent run", () => {
		const result = taskFormatter.formatResult({
			content: [{ type: "text", text: "LGTM" }],
			details: { status: "completed", run_id: "r1", agent_id: "reviewer" },
			is_error: false,
		});

		expect(result.summary).toBe("completed: reviewer");
	});

	it("lists joined tasks", () => {
		const result = taskFormatter.formatResult({
			content: [{ type: "text", text: "Joined 2 delegated task(s)." }],
			details: {
				status: "completed",
				mode: "wait_all",
				task_ids: ["t1", "t2"],
				tasks: [
					{ task_id: "t1", status: "completed", description: "lint" },
					{ task_id: "t2", status: "error", error: "boom" },
				],
			},
			is_error: false,
		});

		expect(result.summary).toBe("completed: 2 tasks");
		expect(result.details).toContain("t1: completed (lint)");
		expect(result.details).toContain("t2: error");
	});

	it("marks error status and tool errors", () => {
		const errored = taskFormatter.formatResult({
			content: [{ type: "text", text: "Delegated run failed: timeout" }],
			details: { task_id: "t1", status: "error", error: "timeout" },
			is_error: false,
		});
		expect(errored.isError).toBe(true);
		expect(errored.details).toContain("error: timeout");

		const failed = taskFormatter.formatResult({
			content: [{ type: "text", text: "Prompt is required" }],
			details: {},
			is_error: true,
		});
		expect(failed.isError).toBe(true);
		expect(failed.summary).toBe("Prompt is required");
	});

	it("falls back to completed for an empty result", () => {
		const result = taskFormatter.formatResult({});

		expect(result.summary).toBe("completed");
		expect(result.details).toEqual([]);
	});
});

describe("taskFormatter.formatPartial", () => {
	it("shows the running subagent's current action", () => {
		const result = taskFormatter.formatPartial!({
			content: [],
			details: {
				description: "Audit auth",
				status: "running",
				current_action: { title: "Reading lib/auth.ex", kind: "tool", phase: "started" },
			},
		});

		expect(result.summary).toBe("running: Reading lib/auth.ex");
		expect(result.details).toContain("▶ Reading lib/auth.ex...");
	});

	it("marks a completed action without an ellipsis", () => {
		const result = taskFormatter.formatPartial!({
			details: {
				status: "running",
				current_action: { title: "Tests passed", phase: "completed" },
			},
		});

		expect(result.details).toContain("✓ Tests passed");
	});

	it("falls back to the action kind when there is no title", () => {
		const result = taskFormatter.formatPartial!({
			details: { status: "running", current_action: { kind: "thinking", phase: "started" } },
		});

		expect(result.summary).toBe("running: thinking");
	});
});
