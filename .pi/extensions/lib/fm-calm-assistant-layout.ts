// Verified against Pi 0.81.1 and 0.82.0, which export AssistantMessageComponent with an
// updateContent method and InteractiveMode with an addMessageToChat method. Turn
// tracking needs both, so installCalmAssistantLayout() probes both exact methods before
// patching either and throws if one is missing; fm-calm.ts catches that and skips only
// this adapter with a diagnostic instead of blocking Calm or Pi.
// This layout removes collapsed thinking and the mid-turn assistant text blocks
// classified as "assistant-working-note" from a shallow presentation copy. The message
// itself, model context, session storage, and export rendering are never touched.
// A working note is hidden only when a later same-turn assistant message has real
// visible text; replay, lifecycle, incomplete, empty, and tools-only rows do not
// count, so the last recap stays visible. Every user message opens a new turn except a
// turn-end-guard follow-up, which finishes the turn it interrupted.
// ./fm-calm-visibility.ts owns which classes Calm hides.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { classifyFirstmateCurrentOperationalText } from "./fm-operational-input.ts";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];
type AssistantContent = AssistantMessage["content"][number];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

type TrackedAssistantRow = {
  component: object;
  message: AssistantMessage;
  turnId: number;
};

type UserMessageLike = {
  role?: string;
  content?: unknown;
};

type InteractiveModePrototype = {
  addMessageToChat(message: UserMessageLike, options?: unknown): unknown;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
  turnId: number;
  rows: TrackedAssistantRow[];
};

// A mid-turn assistant message is one the model did not end its response with: Pi's
// agent loop runs its tool calls and then issues another assistant message. stopReason
// is intrinsic to each message and is already set while the message streams, so this
// layout never has to ask whether the turn ended. It stays "pending" until the tool
// call materializes, which is why a working note is briefly visible before it
// collapses; suppressing pending text would also stop a genuine reply from streaming.
function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall")
  );
}

function contentText(block: AssistantContent): string {
  if (block.type !== "text") return "";
  return block.text.trim();
}

function lineIsReplayLifecycleOrIncomplete(line: string): boolean {
  const text = line.trim();
  if (!text) return true;
  if (/^cursor-replay-\S+$/i.test(text)) return true;
  if (/^Cursor (shell|edit|activity) did not complete\.?$/i.test(text)) return true;
  if (/^missing completion$/i.test(text)) return true;
  if (/^Tool (call|result|error) \(Cursor\b/i.test(text)) return true;
  return false;
}

function textIsReplayLifecycleOrIncomplete(text: string): boolean {
  return text.split(/\r?\n/).every(lineIsReplayLifecycleOrIncomplete);
}

function hasRealVisibleText(message: AssistantMessage): boolean {
  const texts = message.content.map(contentText).filter((text) => text.length > 0);
  if (texts.length === 0) return false;
  return texts.some((text) => !textIsReplayLifecycleOrIncomplete(text));
}

function userMessageText(message: UserMessageLike): string {
  const content = message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => {
      if (typeof block === "string") return block;
      if (
        typeof block === "object" &&
        block !== null &&
        (block as { type?: unknown }).type === "text" &&
        typeof (block as { text?: unknown }).text === "string"
      ) {
        return (block as { text: string }).text;
      }
      return "";
    })
    .join("");
}

// Firstmate's operational inputs arrive as ordinary user messages, and all but one open
// a new logical turn: a watcher wake, an away-supervisor escalation, and a
// from-firstmate message each drive a fresh captain response, so the recap that ended
// the previous turn has to survive the reply to them. turn-end-guard is the exception,
// sent from agent_settled to finish the turn that just tried to end, so its reply
// belongs to that same turn. Ordinary captain text carries no operational marker and
// never pays for the classifier.
const TURN_CONTINUING_OPERATIONAL_KIND = "turn-end-guard";

function continuesCurrentTurn(text: string): boolean {
  if (!text.includes("\u2063")) return false;
  return classifyFirstmateCurrentOperationalText(text) === TURN_CONTINUING_OPERATIONAL_KIND;
}

function isUserTurnBoundary(message: UserMessageLike): boolean {
  if (message.role !== "user") return false;
  return !continuesCurrentTurn(userMessageText(message));
}

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);

// ./fm-calm-operational-user-layout.ts renders Firstmate's operational rows itself and
// never forwards them to the addMessageToChat wrapper below, so it reports their turn
// boundary here. Without an installed layout there is no turn to advance.
export function noteCalmUserTurnBoundary(text: string): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const patch = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (!patch || continuesCurrentTurn(text)) return;
  patch.turnId += 1;
}

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean => calmPresentationHides("assistant-working-note");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    return;
  }

  const patch: CalmAssistantLayoutPatch = {
    hidesThinking,
    hidesWorkingNote,
    turnId: 0,
    rows: [],
  };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const interactivePrototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = interactivePrototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addMessageToChat");
  }

  let applying = false;

  const laterSameTurnHasRealVisibleText = (component: object): boolean => {
    const index = patch.rows.findIndex((row) => row.component === component);
    if (index < 0) return false;
    const turnId = patch.rows[index].turnId;
    for (let later = index + 1; later < patch.rows.length; later += 1) {
      const row = patch.rows[later];
      if (row.turnId !== turnId) break;
      if (hasRealVisibleText(row.message)) return true;
    }
    return false;
  };

  const trackRow = (component: object, message: AssistantMessage): void => {
    const existing = patch.rows.find((row) => row.component === component);
    if (existing) {
      existing.message = message;
      return;
    }
    patch.rows.push({ component, message, turnId: patch.turnId });
  };

  const presentationFor = (
    state: AssistantMessagePresentationState,
    message: AssistantMessage,
    component: object,
  ): AssistantMessage => {
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() &&
      isMidTurnAssistantMessage(message) &&
      laterSameTurnHasRealVisibleText(component);
    if (!hideThinking && !hideWorkingNote) return message;
    return {
      ...message,
      content: message.content.filter(
        (block) =>
          !(hideThinking && block.type === "thinking") &&
          !(hideWorkingNote && block.type === "text"),
      ),
    };
  };

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
    isStreaming?: boolean,
  ): void {
    const component = this as object;
    const state = this as unknown as AssistantMessagePresentationState;
    trackRow(component, message);
    const presentationMessage = presentationFor(state, message, component);
    if (isStreaming === undefined) {
      originalUpdateContent.call(this, presentationMessage);
    } else {
      originalUpdateContent.call(this, presentationMessage, isStreaming);
    }
    if (presentationMessage !== message) state.lastMessage = message;

    if (applying) return;
    applying = true;
    try {
      const index = patch.rows.findIndex((row) => row.component === component);
      const turnId = index < 0 ? patch.turnId : patch.rows[index].turnId;
      for (let earlier = 0; earlier < index; earlier += 1) {
        const row = patch.rows[earlier];
        if (row.turnId !== turnId) continue;
        if (!isMidTurnAssistantMessage(row.message)) continue;
        AssistantMessageComponent.prototype.updateContent.call(row.component, row.message);
      }
    } finally {
      applying = false;
    }
  };

  interactivePrototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: unknown,
  ) {
    if (isUserTurnBoundary(message)) patch.turnId += 1;
    return originalAddMessageToChat.call(this, message, options);
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
