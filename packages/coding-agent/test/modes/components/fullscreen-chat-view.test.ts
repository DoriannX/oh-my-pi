import { describe, expect, it } from "bun:test";
import { FullscreenChatView } from "@oh-my-pi/pi-coding-agent/modes/components/fullscreen-chat-view";
import { type Component, Container } from "@oh-my-pi/pi-tui";

class LinesComponent implements Component {
	constructor(private readonly lines: readonly string[]) {}

	render(): readonly string[] {
		return this.lines;
	}
}

class WrappingComponent implements Component {
	constructor(private readonly text: string) {}

	render(width: number): readonly string[] {
		const lineWidth = Math.max(1, width);
		const lines: string[] = [];
		for (let index = 0; index < this.text.length; index += lineWidth) {
			lines.push(this.text.slice(index, index + lineWidth));
		}
		return lines;
	}
}

describe("FullscreenChatView", () => {
	it("keeps the editor dock visible while history scrolls independently", () => {
		const transcript = new LinesComponent(Array.from({ length: 10 }, (_, index) => `message-${index + 1}`));
		const status = new LinesComponent(["status"]);
		const editor = new LinesComponent(["editor"]);
		const editorContainer = new Container();
		editorContainer.addChild(editor);
		const view = new FullscreenChatView([transcript], [status, editorContainer], editorContainer, () => 6);

		const initial = view.render(12);
		expect(initial[0]).toContain("message-7");
		expect(initial.slice(-2)).toEqual(["status", "editor"]);
		expect(view.ownsOverlayFocusTarget(editor)).toBe(true);
		expect(view.ownsOverlayFocusTarget(transcript)).toBe(false);
		expect(view.handleViewportInput("\x1b[A")).toBe(false);

		expect(view.handleViewportInput("\x1b[5~")).toBe(true);
		const pageUp = view.render(12);
		expect(pageUp[0]).toContain("message-4");
		expect(pageUp.slice(-2)).toEqual(["status", "editor"]);

		// Click the top of the scrollbar. The visible transcript jumps back to
		// the beginning while the fixed dock remains in place.
		expect(view.handleViewportInput("\x1b[<0;12;1M")).toBe(true);
		const top = view.render(12);
		expect(top[0]).toContain("message-1");
		expect(top.slice(-2)).toEqual(["status", "editor"]);
	});

	it("reflows transcript lines before reserving space for the scrollbar", () => {
		const transcript = new WrappingComponent("abcdefghijklmnopqrstuvwxyz0123456789".repeat(2));
		const status = new LinesComponent(["status"]);
		const editor = new LinesComponent(["editor"]);
		const editorContainer = new Container();
		editorContainer.addChild(editor);
		const view = new FullscreenChatView([transcript], [status, editorContainer], editorContainer, () => 6);

		const rendered = view.render(12);
		expect(rendered.slice(0, 4).some(line => line.includes("…"))).toBe(false);
	});

	it("consumes mouse releases that do not end a scrollbar drag", () => {
		const transcript = new LinesComponent(["message"]);
		const editor = new LinesComponent(["editor"]);
		const editorContainer = new Container();
		editorContainer.addChild(editor);
		const view = new FullscreenChatView([transcript], [editorContainer], editorContainer, () => 6);

		view.render(12);
		// A press away from the scrollbar is ignored by navigation but remains
		// consumed. Its matching release must not leak an SGR sequence to the editor.
		expect(view.handleViewportInput("\x1b[<0;1;1M")).toBe(true);
		expect(view.handleViewportInput("\x1b[<0;1;1m")).toBe(true);
	});

	it("moves the configured number of transcript lines per wheel notch", () => {
		const transcript = new LinesComponent(Array.from({ length: 30 }, (_, index) => `line-${index + 1}`));
		const editor = new LinesComponent(["editor"]);
		const editorContainer = new Container();
		editorContainer.addChild(editor);
		let linesPerNotch = 1;
		const view = new FullscreenChatView(
			[transcript],
			[editorContainer],
			editorContainer,
			() => 6,
			() => linesPerNotch,
		);

		// Viewport shows 5 transcript rows above the 1-row dock, tail-anchored on
		// line-30, so the top row is line-26 before any scrolling.
		expect(view.render(12)[0]).toContain("line-26");

		// Wheel-up notch (SGR button 64) at one line per notch.
		expect(view.handleViewportInput("\x1b[<64;1;1M")).toBe(true);
		expect(view.render(12)[0]).toContain("line-25");

		linesPerNotch = 5;
		expect(view.handleViewportInput("\x1b[<64;1;1M")).toBe(true);
		expect(view.render(12)[0]).toContain("line-20");

		// Wheel-down (button 65) uses the same multiplier in the other direction.
		expect(view.handleViewportInput("\x1b[<65;1;1M")).toBe(true);
		expect(view.render(12)[0]).toContain("line-25");
	});
});
