/**
 * Contract of the alt-screen painter's repaint decision.
 *
 * `#emitAltFrame` used to rewrite every row of the viewport on any frame that
 * was not byte-identical, and it treated a caret move as a reason to do so. Two
 * separate costs came out of that on a 60 fps fullscreen surface:
 *   - a caret moving inside unchanged text pushed a whole viewport (~24 KB at a
 *     maximised window) to say what a ~10-byte CUP already says;
 *   - a streaming transcript that changes two rows out of ~50 still pushed all
 *     ~50, measured at ~1.4 MB/s per painting agent.
 *
 * The painter now has three frame shapes. Contract defended here:
 * 1. Nothing changed -> nothing written.
 * 2. Caret moved, rows byte-identical -> cursor placement only, no row rewrite.
 * 3. Rows changed against a comparable previous frame -> only those rows, each
 *    homed with its own CUP (the normal-screen diffable idiom).
 * 4. Forced repaint -> every row, so a redraw gesture still repairs corruption.
 * 5. Only a genuine full rewrite counts as a full redraw.
 */
import { describe, expect, it } from "bun:test";
import { type Component, CURSOR_MARKER, type OverlayFocusOwner, type RenderTimer, TUI } from "@oh-my-pi/pi-tui";
import type { Terminal, TerminalAppearance } from "@oh-my-pi/pi-tui/terminal";

/** Records raw bytes; the kitty-backed VirtualTerminal consumes them into a grid instead. */
class RecordingTerminal implements Terminal {
	columns = 80;
	rows = 24;
	kittyProtocolActive = false;
	kittyEnableSequence: string | null = null;
	keyboardEnhancementEnterSequence: string | null = null;
	keyboardEnhancementExitSequence: string | null = null;
	appearance: TerminalAppearance | undefined;
	output = "";

	start(_onInput: (data: string) => void, _onResize: () => void): void {}
	stop(): void {}
	async drainInput(_maxMs?: number, _idleMs?: number): Promise<void> {}

	write(data: string): void {
		this.output += data;
	}

	moveBy(_lines: number): void {}
	hideCursor(): void {}
	showCursor(): void {}
	clearLine(): void {}
	clearFromCursor(): void {}
	clearScreen(): void {}
	setTitle(_title: string): void {}
	setProgress(_active: boolean): void {}
	onAppearanceChange(_callback: (appearance: TerminalAppearance) => void): void {}
}

/** Lets the test drive frames one at a time. */
class DeferredRenderScheduler {
	nowMs = 0;
	readonly immediates: Array<() => void> = [];
	readonly timers: Array<{ callback: () => void; canceled: boolean; delayMs: number }> = [];

	now(): number {
		return this.nowMs;
	}

	scheduleImmediate(callback: () => void): void {
		this.immediates.push(callback);
	}

	scheduleRender(callback: () => void, delayMs: number): RenderTimer {
		const timer = { callback, canceled: false, delayMs };
		this.timers.push(timer);
		return {
			cancel: () => {
				timer.canceled = true;
			},
		};
	}
}

function stepRender(scheduler: DeferredRenderScheduler): void {
	while (scheduler.immediates.length > 0) scheduler.immediates.shift()!();
	const timer = scheduler.timers.shift();
	if (!timer || timer.canceled) return;
	scheduler.nowMs += timer.delayMs;
	timer.callback();
}

/** 20 body rows plus a CURSOR_MARKER the test moves around, like the fullscreen chat view. */
class CaretSurface implements Component, OverlayFocusOwner {
	caretRow = 0;
	caretCol = 3;
	body = "alpha";

	ownsOverlayFocusTarget(_component: Component): boolean {
		return false;
	}

	invalidate(): void {}

	render(_width: number): string[] {
		const rows: string[] = [];
		for (let r = 0; r < 20; r++) {
			const text = r === 0 ? this.body : `row-${r}-${"x".repeat(40)}`;
			if (r !== this.caretRow) {
				rows.push(text);
				continue;
			}
			rows.push(text.slice(0, this.caretCol) + CURSOR_MARKER + text.slice(this.caretCol));
		}
		return rows;
	}
}

interface Harness {
	tui: TUI;
	surface: CaretSurface;
	/** Bytes written by exactly one ordinary frame. */
	frame(): string;
	/** Bytes written by one forced frame (redraw gesture). */
	forcedFrame(): string;
}

/** Started TUI with a settled fullscreen base surface, so frames are ordinary, not forced. */
function harness(): Harness {
	const term = new RecordingTerminal();
	const scheduler = new DeferredRenderScheduler();
	const tui = new TUI(term, undefined, { renderScheduler: scheduler });
	const surface = new CaretSurface();
	tui.start();
	tui.showOverlay(surface, { fullscreen: true, base: true });
	stepRender(scheduler);
	const frame = (): string => {
		const before = term.output.length;
		tui.requestRender();
		stepRender(scheduler);
		return term.output.slice(before);
	};
	const forcedFrame = (): string => {
		const before = term.output.length;
		tui.requestRender(true);
		stepRender(scheduler);
		return term.output.slice(before);
	};
	frame();
	return { tui, surface, frame, forcedFrame };
}

describe("alt-screen painter", () => {
	it("writes nothing when neither the rows nor the caret moved", () => {
		const h = harness();
		try {
			expect(h.frame()).toBe("");
		} finally {
			h.tui.stop();
		}
	});

	it("emits the cursor placement alone when the caret moves inside unchanged text", () => {
		const h = harness();
		try {
			h.surface.caretRow = 2;
			h.surface.caretCol = 4;
			const caretOnly = h.frame();

			// Exactly one cursor placement, at the caret's column. The row depends on
			// where the surface composites into the viewport, so it is asserted
			// relatively below rather than pinned to today's layout.
			expect(caretOnly.match(/\x1b\[\d+;\d+H/g) ?? []).toHaveLength(1);
			const first = /\x1b\[(\d+);(\d+)H/.exec(caretOnly);
			expect(first).not.toBeNull();
			expect(Number(first![2])).toBe(h.surface.caretCol + 1);
			// No row content, and not the full path's bare home.
			expect(caretOnly).not.toContain("\x1b[H");
			expect(caretOnly).not.toContain("row-1");
			expect(caretOnly).not.toContain("alpha");
			expect(caretOnly.length).toBeLessThan(64);

			// One row down moves the placement by exactly one row, still caret-only.
			h.surface.caretRow = 3;
			const movedDown = h.frame();
			const second = /\x1b\[(\d+);(\d+)H/.exec(movedDown);
			expect(second).not.toBeNull();
			expect(Number(second![1])).toBe(Number(first![1]) + 1);
			expect(movedDown.length).toBeLessThan(64);
		} finally {
			h.tui.stop();
		}
	});

	it("rewrites only the rows that changed", () => {
		const h = harness();
		try {
			h.surface.body = "omega";
			const diffed = h.frame();

			expect(diffed).toContain("omega");
			// The changed row is homed with its own CUP, and the full path's bare
			// home is absent.
			expect(diffed).not.toContain("\x1b[H");
			// Untouched rows stay untouched.
			expect(diffed).not.toContain("row-7");
			expect(diffed).not.toContain("row-19");

			// Same content, forced: every row goes out. That is the volume the diff
			// avoids on a streaming surface.
			const full = h.forcedFrame();
			expect(full).toContain("\x1b[H");
			expect(full).toContain("row-19");
			expect(diffed.length * 8).toBeLessThan(full.length);
		} finally {
			h.tui.stop();
		}
	});

	it("counts only genuine full rewrites as full redraws", () => {
		const h = harness();
		try {
			const before = h.tui.fullRedraws;

			h.surface.caretRow = 3;
			h.frame();
			expect(h.tui.fullRedraws).toBe(before);

			h.surface.body = "changed";
			h.frame();
			expect(h.tui.fullRedraws).toBe(before);

			h.forcedFrame();
			expect(h.tui.fullRedraws).toBe(before + 1);
		} finally {
			h.tui.stop();
		}
	});
});
