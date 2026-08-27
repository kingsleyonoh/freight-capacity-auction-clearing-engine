import { renderShell } from "./shell.js";

renderShell();

export const loadClearingChart = () => import("./chart.js");
export const loadReplayFrontier = () => import("./frontier.js");
