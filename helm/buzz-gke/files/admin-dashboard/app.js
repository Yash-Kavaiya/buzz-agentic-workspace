// Buzz admin console UI. Everything rendered from the API goes through
// textContent (see h()), because reports and feedback are untrusted user input.
// The relay's CSP also forbids inline scripts and styles.

import {
  ApiError,
  createClient,
  normalizeEventId,
  normalizePubkey,
  parseDuration,
} from "./api.js";

const root = document.getElementById("app");
const toasts = document.getElementById("toasts");

const state = { client: null, probe: null, communities: [], host: "" };

const NAV = [
  ["overview", "Overview"],
  ["reports", "Reports"],
  ["feedback", "Feedback"],
  ["members", "Members"],
  ["restrictions", "Bans & timeouts"],
  ["events", "Events"],
  ["staff", "Staff"],
];

// ── DOM helpers ──────────────────────────────────────────────────────────────

function h(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs ?? {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (key === "class") node.className = value;
    else if (key in node && key !== "list") node[key] = value;
    else node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function toast(message, kind = "ok") {
  const item = h("div", { class: `toast ${kind}` }, message);
  toasts.append(item);
  setTimeout(() => item.remove(), kind === "error" ? 9000 : 4500);
}

const shortKey = (key) => (key ? `${key.slice(0, 10)}…${key.slice(-6)}` : "—");
const when = (value) => (value ? new Date(value).toLocaleString() : "—");

function keyCell(key) {
  return h(
    "button",
    {
      class: "key",
      title: `Copy ${key}`,
      onclick: async (event) => {
        event.stopPropagation();
        try {
          await navigator.clipboard.writeText(key);
          toast("Copied");
        } catch {
          toast("Copy failed. Your browser blocked clipboard access.", "error");
        }
      },
    },
    shortKey(key),
  );
}

const badge = (text, tone = "") => h("span", { class: `badge ${tone}` }, text);

function statusBadge(status) {
  const tones = {
    open: "warn", new: "warn", processing: "info", escalated: "danger",
    resolved: "good", reviewed: "good", dismissed: "", archived: "",
  };
  return badge(status, tones[status] ?? "");
}

function table(columns, rows, { empty = "Nothing here yet.", onRow } = {}) {
  if (!rows.length) return h("p", { class: "empty" }, empty);
  return h(
    "div",
    { class: "table-wrap" },
    h(
      "table",
      {},
      h("thead", {}, h("tr", {}, columns.map(([label]) => h("th", { scope: "col" }, label)))),
      h(
        "tbody",
        {},
        rows.map((row) =>
          h(
            "tr",
            { class: onRow ? "clickable" : "", onclick: onRow ? () => onRow(row) : null },
            columns.map(([label, render]) => h("td", { "data-label": label }, render(row))),
          ),
        ),
      ),
    ),
  );
}

function describe(error) {
  if (error instanceof ApiError) {
    if (error.status === 403) return "Your key does not have permission for this action.";
    return error.message;
  }
  return error?.message ?? "Something went wrong.";
}

/** Generic modal form. Keeps the dialog open and shows the error on failure. */
function openForm({ title, intro, warning, fields = [], submit = "Save", danger, onSubmit }) {
  const inputs = {};
  const errorLine = h("p", { class: "form-error", role: "alert", hidden: true });
  const body = fields.map((field) => {
    const id = `field-${field.name}`;
    let control;
    if (field.type === "select") {
      control = h(
        "select",
        { id, name: field.name },
        field.options.map(([value, label]) =>
          h("option", { value, selected: value === field.value }, label),
        ),
      );
    } else if (field.type === "textarea") {
      control = h("textarea", { id, name: field.name, rows: 3, maxLength: field.maxLength ?? 1000 });
      control.value = field.value ?? "";
    } else {
      control = h("input", {
        id,
        name: field.name,
        type: field.type ?? "text",
        autocomplete: "off",
        spellcheck: false,
        placeholder: field.placeholder,
        readOnly: field.readOnly,
        step: field.step,
        min: field.min,
      });
      control.value = field.value ?? "";
    }
    control.required = Boolean(field.required);
    inputs[field.name] = control;
    return h(
      "div",
      { class: "field", "data-field": field.name },
      h("label", { htmlFor: id }, field.label),
      control,
      field.help ? h("small", {}, field.help) : null,
    );
  });

  const syncVisibility = () => {
    for (const field of fields) {
      if (!field.showWhen) continue;
      const visible = field.showWhen(inputs);
      inputs[field.name].closest(".field").hidden = !visible;
      inputs[field.name].required = visible && Boolean(field.required);
    }
  };
  Object.values(inputs).forEach((input) => input.addEventListener("change", syncVisibility));
  syncVisibility();

  const submitButton = h("button", { type: "submit", class: danger ? "danger" : "primary" }, submit);
  const dialog = h("dialog", { class: "modal" });
  const close = () => { dialog.close(); dialog.remove(); };
  const form = h(
    "form",
    {
      onsubmit: async (event) => {
        event.preventDefault();
        errorLine.hidden = true;
        submitButton.disabled = true;
        try {
          const values = Object.fromEntries(
            Object.entries(inputs).map(([name, input]) => [name, input.value.trim()]),
          );
          await onSubmit(values);
          close();
        } catch (error) {
          errorLine.textContent = describe(error);
          errorLine.hidden = false;
        } finally {
          submitButton.disabled = false;
        }
      },
    },
    h("h2", {}, title),
    intro ? h("p", { class: "muted" }, intro) : null,
    warning ? h("p", { class: "callout" }, warning) : null,
    body,
    errorLine,
    h(
      "div",
      { class: "actions end" },
      h("button", { type: "button", onclick: close }, "Cancel"),
      submitButton,
    ),
  );
  dialog.append(form);
  dialog.addEventListener("cancel", (event) => { event.preventDefault(); close(); });
  document.body.append(dialog);
  dialog.showModal();
}

function openDetail(title, content) {
  const dialog = h("dialog", { class: "modal wide" });
  const close = () => { dialog.close(); dialog.remove(); };
  dialog.append(
    h("div", { class: "detail-head" }, h("h2", {}, title), h("button", { onclick: close }, "Close")),
    content,
  );
  dialog.addEventListener("cancel", (event) => { event.preventDefault(); close(); });
  document.body.append(dialog);
  dialog.showModal();
  return close;
}

const dl = (pairs) =>
  h("dl", {}, pairs.filter(Boolean).flatMap(([term, value]) => [h("dt", {}, term), h("dd", {}, value ?? "—")]));

const canAct = () => Boolean(state.probe?.canAct);
const canStaff = () => Boolean(state.probe?.canStaff);

function page(title, intro, actions, ...content) {
  return h(
    "section",
    {},
    h(
      "header",
      { class: "page-head" },
      h("div", {}, h("h1", {}, title), intro ? h("p", { class: "muted" }, intro) : null),
      actions ? h("div", { class: "actions" }, actions) : null,
    ),
    content,
  );
}

function needsCommunity() {
  return h("p", { class: "empty" }, "Select a community at the top of the page first.");
}

// ── Overview ─────────────────────────────────────────────────────────────────

async function overview() {
  const stat = (label, value, route) =>
    h("a", { class: "stat", href: `#/${route}` }, h("strong", {}, value), h("span", {}, label));
  const [open, escalated, feedback] = await Promise.all([
    state.client.reports({ status: "open", limit: 200 }),
    state.client.reports({ status: "escalated", limit: 200 }),
    state.client.feedback(),
  ]);
  const capped = (rows) => (rows.length >= 200 ? "200+" : rows.length);
  const unread = feedback.filter((item) => item.status === "new").length;
  return page(
    "Overview",
    "What needs attention on this deployment.",
    null,
    h(
      "div",
      { class: "stats" },
      stat("Open reports", capped(open), "reports"),
      stat("Escalated reports", capped(escalated), "reports"),
      stat("New feedback (latest 100)", unread, "feedback"),
      stat("Communities", state.communities.length, "members"),
    ),
    h("h2", {}, "Your access"),
    dl([
      ["Role", state.probe.role ?? "Read-only (no identity)"],
      ["Granted by", state.probe.source ?? "—"],
      ["Can moderate", state.probe.canAct ? "Yes" : "No"],
      ["Can manage staff", state.probe.canStaff ? "Yes" : "No"],
    ]),
  );
}

// ── Reports ──────────────────────────────────────────────────────────────────

function resolveForm(report, refresh, closeDetail) {
  const requestId = state.client.newId();
  const enforcing = (inputs) => !["dismiss", "escalate"].includes(inputs.action.value);
  openForm({
    title: "Resolve report",
    warning: "The reason is public. It is posted in the channel and sent to the affected person.",
    fields: [
      {
        name: "action", label: "Action", type: "select", value: "dismiss",
        options: [
          ["dismiss", "Dismiss"], ["escalate", "Escalate"],
          ...(report.targetKind === "event" ? [["delete", "Delete the message"]] : []),
          ["kick", "Remove from channel"], ["timeout", "Time out"], ["ban", "Ban"],
        ],
      },
      {
        name: "hours", label: "Timeout (hours)", type: "number", min: "0.1", step: "0.1",
        value: "24", required: true, showWhen: (inputs) => inputs.action.value === "timeout",
      },
      { name: "reason", label: "Public reason", type: "textarea", showWhen: enforcing },
    ],
    submit: "Apply",
    onSubmit: async ({ action, hours, reason }) => {
      const body = { action };
      if (!["dismiss", "escalate"].includes(action)) {
        body.requestId = requestId;
        if (reason) body.reason = reason;
      }
      if (action === "timeout") body.expirationSecs = parseDuration(hours);
      await state.client.resolveReport(report.id, body);
      toast("Report updated");
      closeDetail?.();
      refresh();
    },
  });
}

async function showReport(id, refresh) {
  const report = await state.client.report(id);
  const message = report.message;
  let close;
  const done = () => close?.();
  const action = report.activeAction;
  const buttons = canAct()
    ? [
        report.status === "open" || report.status === "escalated"
          ? h("button", { class: "primary", onclick: () => resolveForm(report, refresh, done) }, "Resolve")
          : null,
        ["resolved", "dismissed", "escalated"].includes(report.status)
          ? h("button", {
              onclick: () => {
                const requestId = state.client.newId();
                openForm({
                  title: "Reopen report",
                  fields: [{ name: "reason", label: "Private audit note", type: "textarea" }],
                  submit: "Reopen",
                  onSubmit: async ({ reason }) => {
                    await state.client.reopenReport(report.id, { requestId, ...(reason ? { reason } : {}) });
                    toast("Report reopened");
                    done();
                    refresh();
                  },
                });
              },
            }, "Reopen")
          : null,
        action
          ? h("button", {
              class: "danger",
              onclick: () =>
                openForm({
                  title: "Cancel the failed action?",
                  intro: "This returns the report to open. It only works while the action has not taken effect.",
                  submit: "Cancel action",
                  danger: true,
                  onSubmit: async () => {
                    await state.client.cancelReport(report.id, action.id);
                    toast("Action cancelled");
                    done();
                    refresh();
                  },
                }),
            }, "Cancel action")
          : null,
      ]
    : [];
  close = openDetail(
    "Report",
    h(
      "div",
      {},
      dl([
        ["Status", statusBadge(report.status)],
        ["Community", report.communityHost],
        ["Type", report.reportType],
        ["Target", `${report.targetKind}: ${report.target}`],
        ["Reporter", keyCell(report.reporterPubkey)],
        ["Reporter note", report.note],
        ["Filed", when(report.createdAt)],
        action ? ["Action in progress", `${action.action ?? "action"} (${action.state ?? action.status ?? "pending"})`] : null,
      ]),
      message
        ? h(
            "div",
            {},
            h("h3", {}, message.deletedAt ? "Reported message (deleted)" : "Reported message"),
            h("blockquote", {}, message.content),
            h("p", { class: "muted" }, "By ", keyCell(message.authorPubkey), ` on ${when(message.createdAt)}`),
          )
        : null,
      h("div", { class: "actions" }, buttons),
    ),
  );
}

async function reports(params) {
  const status = params.get("status") ?? "open";
  const rows = await state.client.reports(status === "all" ? { scope: "all", limit: 200 } : { status, limit: 200 });
  const filter = h(
    "select",
    {
      "aria-label": "Filter reports by status",
      onchange: (event) => { location.hash = `#/reports?status=${event.target.value}`; },
    },
    ["open", "processing", "escalated", "resolved", "dismissed", "all"].map((value) =>
      h("option", { value, selected: value === status }, value[0].toUpperCase() + value.slice(1)),
    ),
  );
  return page(
    "Reports",
    "Read and resolve reports. Reports are filed by members in their Buzz clients.",
    filter,
    table(
      [
        ["Status", (r) => statusBadge(r.status)],
        ["Type", (r) => r.reportType],
        ["Target", (r) => r.targetKind],
        ["Community", (r) => r.communityHost],
        ["Note", (r) => h("span", { class: "clip" }, r.note ?? "—")],
        ["Filed", (r) => when(r.createdAt)],
      ],
      rows,
      { empty: "No reports with this status.", onRow: (r) => guarded(() => showReport(r.id, render)) },
    ),
  );
}

// ── Feedback ─────────────────────────────────────────────────────────────────

async function showFeedback(id) {
  const item = await state.client.feedbackItem(id);
  const select = h(
    "select",
    { "aria-label": "Feedback status", disabled: !canAct() },
    ["new", "reviewed", "archived"].map((value) => h("option", { value, selected: value === item.status }, value)),
  );
  let close;
  const save = h("button", {
    class: "primary",
    disabled: !canAct(),
    onclick: () =>
      guarded(async () => {
        await state.client.setFeedbackStatus(id, select.value);
        toast("Feedback updated");
        close();
        render();
      }),
  }, "Save status");
  close = openDetail(
    "Feedback",
    h(
      "div",
      {},
      dl([
        ["Community", item.communityHost ?? "Removed"],
        ["From", keyCell(item.submitterPubkey)],
        ["Category", item.category],
        ["Received", when(item.receivedAt)],
      ]),
      h("blockquote", {}, item.body),
      h("div", { class: "actions" }, select, save),
    ),
  );
}

async function feedback() {
  const rows = await state.client.feedback();
  return page(
    "Feedback",
    "The latest 100 items. The relay does not support deleting feedback, so archive it instead.",
    null,
    table(
      [
        ["Status", (f) => statusBadge(f.status)],
        ["Category", (f) => f.category ?? "—"],
        ["Summary", (f) => h("span", { class: "clip" }, f.bodySummary)],
        ["Community", (f) => f.communityHost ?? "Removed"],
        ["Received", (f) => when(f.receivedAt)],
      ],
      rows,
      { empty: "No feedback yet.", onRow: (f) => guarded(() => showFeedback(f.id)) },
    ),
  );
}

// ── Restrictions ─────────────────────────────────────────────────────────────

function restrictForm(kind, pubkey = "") {
  const requestId = state.client.newId();
  const isTimeout = kind === "timeout";
  openForm({
    title: isTimeout ? (pubkey ? "Change timeout" : "Time out a member") : "Ban a member",
    intro: `Applies in ${state.host}.`,
    warning: "The reason may be shown to the affected person. Do not include private details.",
    fields: [
      { name: "pubkey", label: "Public key", value: pubkey, readOnly: Boolean(pubkey), required: true, placeholder: "npub1… or hex" },
      isTimeout ? { name: "hours", label: "Duration (hours)", type: "number", min: "0.1", step: "0.1", value: "24", required: true } : null,
      { name: "reason", label: "Reason", type: "textarea" },
    ].filter(Boolean),
    submit: isTimeout ? "Apply timeout" : "Ban",
    danger: !isTimeout,
    onSubmit: async ({ pubkey: raw, hours, reason }) => {
      const key = normalizePubkey(raw);
      const result = isTimeout
        ? await state.client.timeout(state.host, key, { requestId, reason, expirationSecs: parseDuration(hours) })
        : await state.client.ban(state.host, key, { requestId, reason });
      toast(result?.status === "pending" ? "Accepted. The relay is still applying it." : "Applied");
      render();
    },
  });
}

function liftForm(kind, pubkey) {
  openForm({
    title: kind === "ban" ? "Lift this ban?" : "End this timeout?",
    intro: `${shortKey(pubkey)} in ${state.host}.`,
    submit: kind === "ban" ? "Lift ban" : "End timeout",
    onSubmit: async () => {
      if (kind === "ban") await state.client.unban(state.host, pubkey);
      else await state.client.untimeout(state.host, pubkey);
      toast("Restriction removed");
      render();
    },
  });
}

async function restrictions() {
  const actions = canAct() && state.host
    ? [
        h("button", { onclick: () => restrictForm("timeout") }, "Add timeout"),
        h("button", { class: "danger", onclick: () => restrictForm("ban") }, "Add ban"),
      ]
    : null;
  if (!state.host) return page("Bans & timeouts", null, null, needsCommunity());

  const rows = [];
  const holder = h("div");
  const more = h("button", { hidden: true });
  let cursor = null;
  const paint = () => {
    const isMuted = (r) => r.mutedUntil && new Date(r.mutedUntil) > new Date();
    holder.replaceChildren(
      table(
        [
          ["Member", (r) => keyCell(r.pubkey)],
          ["State", (r) => [r.banned ? badge("Banned", "danger") : null, isMuted(r) ? badge("Timed out", "warn") : null]],
          ["Until", (r) => (r.banned ? (r.banExpiresAt ? when(r.banExpiresAt) : "Permanent") : when(r.mutedUntil))],
          ["Reason", (r) => h("span", { class: "clip" }, r.banReason ?? r.muteReason ?? "—")],
          ["Updated", (r) => when(r.updatedAt)],
          ["", (r) => canAct()
            ? h("div", { class: "actions" },
                isMuted(r) ? h("button", { onclick: () => restrictForm("timeout", r.pubkey) }, "Edit") : null,
                isMuted(r) ? h("button", { onclick: () => liftForm("timeout", r.pubkey) }, "End") : null,
                r.banned ? h("button", { onclick: () => liftForm("ban", r.pubkey) }, "Lift ban") : null)
            : null],
        ],
        rows,
        { empty: "No active bans or timeouts in this community." },
      ),
    );
  };
  const load = async () => {
    const result = await state.client.restrictions(state.host, cursor);
    rows.push(...result.items);
    cursor = result.nextCursor;
    more.hidden = !cursor;
    paint();
  };
  more.textContent = "Load more";
  more.addEventListener("click", () => guarded(load));
  await load();
  return page("Bans & timeouts", `Active restrictions in ${state.host}.`, actions, holder, more);
}

// ── Members ──────────────────────────────────────────────────────────────────

async function showMember(pubkey) {
  const info = await state.client.member(state.host, pubkey);
  let close;
  const act = (fn) => () => { close(); fn(); };
  close = openDetail(
    info.profile?.displayName ?? "Member",
    h(
      "div",
      {},
      dl([
        ["Public key", keyCell(info.pubkey)],
        ["Role", info.role ?? "Not a member"],
        ["About", info.profile?.about],
        ["Banned", info.banned ? "Yes" : "No"],
        ["Timed out until", info.mutedUntil ? when(info.mutedUntil) : "—"],
        ["Staff", info.isStaff ? "Yes" : "No"],
      ]),
      canAct() && !info.isStaff
        ? h(
            "div",
            { class: "actions" },
            h("button", { onclick: act(() => restrictForm("timeout", info.pubkey)) }, "Time out"),
            info.banned
              ? h("button", { onclick: act(() => liftForm("ban", info.pubkey)) }, "Lift ban")
              : h("button", { class: "danger", onclick: act(() => restrictForm("ban", info.pubkey)) }, "Ban"),
          )
        : null,
    ),
  );
}

async function members() {
  if (!state.host) return page("Members", null, null, needsCommunity());
  const results = h("div");
  const input = h("input", { type: "search", placeholder: "Name, npub, or hex key", "aria-label": "Search members", required: true });
  const form = h(
    "form",
    {
      class: "inline",
      onsubmit: (event) => {
        event.preventDefault();
        guarded(async () => {
          const text = input.value.trim();
          let direct = null;
          try { direct = normalizePubkey(text); } catch (error) {
            if (text.toLowerCase().startsWith("nsec1")) throw error;
          }
          if (direct) { await showMember(direct); return; }
          const page = await state.client.searchMembers(state.host, text);
          results.replaceChildren(
            table(
              [
                ["Name", (m) => m.displayName ?? "—"],
                ["Public key", (m) => keyCell(m.pubkey)],
              ],
              page.items,
              { empty: "No members match.", onRow: (m) => guarded(() => showMember(m.pubkey)) },
            ),
          );
        });
      },
    },
    input,
    h("button", { class: "primary", type: "submit" }, "Search"),
  );
  return page(
    "Members",
    `Find people and agents in ${state.host}.`,
    null,
    form,
    results,
    h("h2", {}, "Adding or removing relay members"),
    h(
      "p",
      { class: "muted" },
      "The relay's admin API has no roster endpoint, so membership changes stay in the audited CLI. Bans above take effect immediately.",
    ),
    h("pre", {}, "buzzctl onboard user <env> --npub npub1…\nbuzzctl onboard agent <env> --name deploy-bot\nbuzzctl offboard <env> --npub npub1…"),
  );
}

// ── Events ───────────────────────────────────────────────────────────────────

async function events() {
  if (!state.host) return page("Events", null, null, needsCommunity());
  const result = h("div");
  const input = h("input", { placeholder: "64-character event id", "aria-label": "Event id", required: true, spellcheck: false });
  const show = async (id) => {
    const event = await state.client.event(state.host, id);
    result.replaceChildren(
      h(
        "div",
        { class: "card" },
        dl([
          ["Author", keyCell(event.authorPubkey)],
          ["Kind", event.kind],
          ["Created", when(event.createdAt)],
          ["Deleted", event.deletedAt ? when(event.deletedAt) : "No"],
        ]),
        h("blockquote", {}, event.content),
        canAct() && !event.deletedAt
          ? h("button", {
              class: "danger",
              onclick: () => {
                const requestId = state.client.newId();
                openForm({
                  title: "Delete this message?",
                  warning: "This removes the message for everyone. The reason may be shown publicly.",
                  fields: [{ name: "reason", label: "Reason", type: "textarea" }],
                  submit: "Delete message",
                  danger: true,
                  onSubmit: async ({ reason }) => {
                    const response = await state.client.deleteEvent(state.host, id, { requestId, reason });
                    toast(response?.status === "pending" ? "Accepted. The relay is still deleting it." : "Message deleted");
                    await show(id).catch(() => result.replaceChildren());
                  },
                });
              },
            }, "Delete message")
          : null,
      ),
    );
  };
  return page(
    "Events",
    `Look up and remove a single message in ${state.host}.`,
    null,
    h(
      "form",
      {
        class: "inline",
        onsubmit: (event) => {
          event.preventDefault();
          guarded(() => show(normalizeEventId(input.value)));
        },
      },
      input,
      h("button", { class: "primary", type: "submit" }, "Look up"),
    ),
    result,
  );
}

// ── Staff ────────────────────────────────────────────────────────────────────

function staffForm(entry) {
  openForm({
    title: entry ? "Change role" : "Add staff",
    intro: entry ? null : "Operators can manage staff. Moderators can only moderate.",
    fields: [
      { name: "pubkey", label: "Public key", value: entry?.pubkey ?? "", readOnly: Boolean(entry), required: true, placeholder: "npub1… or hex" },
      { name: "role", label: "Role", type: "select", value: entry?.effectiveRole ?? "moderator", options: [["moderator", "Moderator"], ["operator", "Operator"]] },
    ],
    onSubmit: async ({ pubkey, role }) => {
      await state.client.putOperator(normalizePubkey(pubkey), role);
      toast(entry ? "Role updated" : "Staff added");
      render();
    },
  });
}

async function staff() {
  if (!canStaff()) {
    return page("Staff", null, null, h("p", { class: "empty" }, "Only operators can view and manage staff."));
  }
  const rows = await state.client.operators();
  const editable = (entry) => entry.sources.length === 1 && entry.sources[0] === "db";
  return page(
    "Staff",
    "Keys set in config/<env>.yaml are locked here. Change those in git and redeploy.",
    h("button", { class: "primary", onclick: () => staffForm() }, "Add staff"),
    table(
      [
        ["Public key", (e) => keyCell(e.pubkey)],
        ["Role", (e) => badge(e.effectiveRole, e.effectiveRole === "operator" ? "info" : "")],
        ["Source", (e) => e.sources.join(", ")],
        ["", (e) => editable(e)
          ? h("div", { class: "actions" },
              h("button", { onclick: () => staffForm(e) }, "Edit"),
              h("button", {
                class: "danger",
                onclick: () =>
                  openForm({
                    title: "Remove this staff member?",
                    intro: `${shortKey(e.pubkey)} loses admin console access. Their relay membership is unchanged.`,
                    submit: "Remove",
                    danger: true,
                    onSubmit: async () => {
                      await state.client.deleteOperator(e.pubkey);
                      toast("Staff removed");
                      render();
                    },
                  }),
              }, "Remove"))
          : badge("Locked")],
      ],
      rows,
      { empty: "No staff configured." },
    ),
  );
}

// ── Shell ────────────────────────────────────────────────────────────────────

const ROUTES = { overview, reports, feedback, members, restrictions, events, staff };

async function guarded(fn) {
  try {
    return await fn();
  } catch (error) {
    toast(describe(error), "error");
    return undefined;
  }
}

function parseRoute() {
  const [path, search] = location.hash.replace(/^#\/?/, "").split("?");
  return { name: ROUTES[path] ? path : "overview", params: new URLSearchParams(search ?? "") };
}

let renderToken = 0;

async function render() {
  const token = ++renderToken;
  const { name, params } = parseRoute();
  const main = h("main", { id: "main" }, h("p", { class: "muted" }, "Loading…"));
  const picker = h(
    "select",
    {
      "aria-label": "Community",
      onchange: (event) => { state.host = event.target.value; render(); },
    },
    h("option", { value: "" }, state.communities.length ? "Select a community" : "No communities"),
    state.communities.map((c) => h("option", { value: c.host, selected: c.host === state.host }, c.host)),
  );
  root.replaceChildren(
    h(
      "div",
      { class: "shell" },
      h(
        "aside",
        {},
        h("div", { class: "brand" }, h("img", { src: "/favicon.svg", alt: "" }), "Buzz Admin"),
        h(
          "nav",
          { "aria-label": "Sections" },
          NAV.map(([route, label]) =>
            h("a", { href: `#/${route}`, class: route === name ? "active" : "", "aria-current": route === name ? "page" : null }, label),
          ),
        ),
      ),
      h(
        "div",
        { class: "content" },
        h(
          "div",
          { class: "topbar" },
          picker,
          badge(state.probe.role ?? "read-only", state.probe.canAct ? "info" : "warn"),
        ),
        main,
      ),
    ),
  );
  try {
    const view = await ROUTES[name](params);
    if (token === renderToken) main.replaceChildren(view);
  } catch (error) {
    if (token === renderToken) {
      main.replaceChildren(
        h("div", { class: "callout" }, describe(error), " ", h("button", { onclick: render }, "Try again")),
      );
    }
  }
}

async function loadCommunities() {
  const all = [];
  let cursor;
  // The relay pages at 100. The cap keeps a very large deployment responsive.
  for (let page = 0; page < 10; page += 1) {
    const result = await state.client.communities({ limit: 100, cursor });
    all.push(...result.items);
    cursor = result.nextCursor;
    if (!cursor) break;
  }
  state.communities = all;
  if (all.length === 1) state.host = all[0].host;
}

function waitForSigner(ms = 1500) {
  return new Promise((resolve) => {
    const started = Date.now();
    const poll = () => {
      if (window.nostr) resolve(window.nostr);
      else if (Date.now() - started > ms) resolve(null);
      else setTimeout(poll, 100);
    };
    poll();
  });
}

function gate(title, message) {
  root.replaceChildren(
    h(
      "div",
      { class: "gate" },
      h("img", { src: "/favicon.svg", alt: "", width: 48, height: 48 }),
      h("h1", {}, title),
      h("p", {}, message),
      h("button", { class: "primary", onclick: start }, "Try again"),
    ),
  );
}

async function start() {
  root.replaceChildren(h("p", { class: "boot" }, "Connecting…"));
  const origin = location.origin;
  try {
    const anonymous = createClient({ origin });
    try {
      state.probe = await anonymous.probe();
      state.client = anonymous;
    } catch (error) {
      if (!(error instanceof ApiError) || ![401, 403].includes(error.status)) throw error;
      const signer = await waitForSigner();
      if (!signer) {
        gate("Connect a Nostr signer", "This console signs each request with a NIP-07 browser extension such as nos2x or Alby. Your private key stays in the extension.");
        return;
      }
      state.client = createClient({ origin, signer });
      state.probe = await state.client.probe();
    }
    await loadCommunities();
    await render();
  } catch (error) {
    if (error instanceof ApiError && [401, 403].includes(error.status)) {
      gate("This key is not staff", "Ask an operator to add your public key, then try again.");
    } else {
      gate("Could not reach the relay", describe(error));
    }
  }
}

window.addEventListener("hashchange", render);
start();
