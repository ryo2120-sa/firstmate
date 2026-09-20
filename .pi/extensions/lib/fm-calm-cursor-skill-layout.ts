// Verified against Pi 0.81.1 and 0.82.0, which export ToolExecutionComponent with a
// render method. installCalmCursorSkillLayout() probes that exact method and throws
// if it is missing; fm-calm.ts catches that and skips only this adapter with a diagnostic
// instead of blocking Calm or Pi.
// This layout hides the Cursor skill-load tool row from live transcript presentation.
// It never replaces that tool's execute path, never registers a same-name override, and
// never touches model context, session storage, or export rendering.
// ./fm-calm-visibility.ts owns which tool names this adapter may hide.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmHidesNamedToolRow } from "./fm-calm-visibility.ts";

type ToolExecutionLike = {
  toolName?: unknown;
  render(width: number): string[];
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_CURSOR_SKILL_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-cursor-skill-layout:pi-0.81.1",
);

export function installCalmCursorSkillLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: true | undefined;
  };
  if (registry[CALM_CURSOR_SKILL_LAYOUT_PATCH]) return;

  const ToolExecutionComponent = PiCodingAgent.ToolExecutionComponent;
  if (typeof ToolExecutionComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent");
  }
  const originalRender = ToolExecutionComponent.prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.render");
  }

  ToolExecutionComponent.prototype.render = function (
    this: ToolExecutionLike,
    width: number,
  ): string[] {
    const toolName = this.toolName;
    if (typeof toolName === "string" && calmHidesNamedToolRow(toolName)) {
      return [];
    }
    return originalRender.call(this, width);
  };

  registry[CALM_CURSOR_SKILL_LAYOUT_PATCH] = true;
}
