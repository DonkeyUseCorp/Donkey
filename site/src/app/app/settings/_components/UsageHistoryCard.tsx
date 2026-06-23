"use client";

import { Fragment, useRef, useState, type KeyboardEvent } from "react";

import { useUsage, type VisionUsage } from "@/queries/billing";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious,
} from "@/components/ui/pagination";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { cn } from "@/lib/utils";

type RecentCall = VisionUsage["recent"][number];

// Stable identity for a call so expansion state survives a background refetch
// (which can reorder/prepend rows) instead of being pinned to an array index.
function callKey(call: RecentCall): string {
  return `${call.createdAt}-${call.product}-${call.requestKind}-${call.costCredits}`;
}

// Cents by default, but show a third decimal when a value carries sub-cent
// precision (many app calls cost a fraction of a cent) so they aren't all
// "$0.00". Clean values stay at 2 decimals — min 2 / max 3 fraction digits.
function formatCostValue(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "$0.00";
  }
  return value.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 3,
  });
}

function formatCallCost(call: RecentCall): string {
  if (call.billingStatus === "included") {
    return "Included";
  }
  return formatCostValue(Number.parseFloat(call.costCredits));
}

// Calls with no conversation (the always-on UI-understanding parses) are bucketed
// under one sentinel so they stay contiguous, but they render as plain rows with
// no group header. The sentinel can't collide with a real conversation id.
const NO_CONVERSATION = "__none__";

function conversationKey(call: RecentCall): string {
  return call.conversationId ?? NO_CONVERSATION;
}

function conversationLabel(key: string): string {
  // Conversation ids are long opaque strings; a short prefix is enough to tell
  // groups apart without dominating the row.
  return `Conversation ${key.slice(0, 8)}`;
}

// A group's combined cost for its header. All-included groups (the Vision API
// tab) have no credit cost, so label them "Included" rather than "$0.00".
function groupCostSummary(calls: RecentCall[]): string {
  if (calls.every((call) => call.billingStatus === "included")) {
    return "Included";
  }
  const total = calls.reduce((sum, call) => {
    const value = Number.parseFloat(call.costCredits);
    return Number.isFinite(value) ? sum + value : sum;
  }, 0);
  return formatCostValue(total);
}

type GroupedRow = { call: RecentCall; groupKey: string };

// Bucket tab rows by conversation, preserving the server's newest-first order so
// each group sits at the position of its most recent call, then flatten back to a
// row list that is now contiguous per conversation.
function groupRowsByConversation(rows: RecentCall[]): {
  ordered: GroupedRow[];
  counts: Map<string, number>;
  summaries: Map<string, string>;
} {
  const order: string[] = [];
  const byKey = new Map<string, RecentCall[]>();
  for (const call of rows) {
    const key = conversationKey(call);
    const existing = byKey.get(key);
    if (existing) {
      existing.push(call);
    } else {
      byKey.set(key, [call]);
      order.push(key);
    }
  }
  const ordered: GroupedRow[] = [];
  const counts = new Map<string, number>();
  const summaries = new Map<string, string>();
  for (const key of order) {
    const calls = byKey.get(key) ?? [];
    counts.set(key, calls.length);
    summaries.set(key, groupCostSummary(calls));
    for (const call of calls) {
      ordered.push({ call, groupKey: key });
    }
  }
  return { ordered, counts, summaries };
}

function formatTokens(value: number): string {
  return value.toLocaleString();
}

function formatDuration(millis: number): string {
  return millis >= 1000 ? `${(millis / 1000).toFixed(1)}s` : `${millis}ms`;
}

const tabs = [
  { key: "app", label: "App" },
  { key: "vision", label: "Vision API" },
] as const;

type TabKey = (typeof tabs)[number]["key"];

// Page the table client-side, capped so the control never grows past 5 pages.
const ROWS_PER_PAGE = 25;
const MAX_PAGES = 5;

function CallDetail({ call }: { call: RecentCall }) {
  const { usage } = call;
  const imageBilled = usage.generationCount > 0;
  const tokenBilled =
    usage.inputTokens > 0 || usage.outputTokens > 0 || usage.totalTokens > 0;
  // Vision parses report no token/image usage — they're a flat per-call charge,
  // so there's no breakdown to show, just the pricing model.
  const flatRate =
    !imageBilled && !tokenBilled && call.requestKind === "vision_parse";

  const stats: { label: string; value: string }[] = [];
  if (imageBilled) {
    stats.push({
      label: "Images generated",
      value: formatTokens(usage.generationCount),
    });
  }
  if (tokenBilled) {
    stats.push(
      {
        label: "Input tokens",
        value:
          usage.cachedInputTokens > 0
            ? `${formatTokens(usage.inputTokens)} (${formatTokens(usage.cachedInputTokens)} cached)`
            : formatTokens(usage.inputTokens),
      },
      { label: "Output tokens", value: formatTokens(usage.outputTokens) },
      { label: "Total tokens", value: formatTokens(usage.totalTokens) },
    );
  }
  // Only some (audio-priced) calls report a duration; omit it otherwise.
  if (usage.durationMillis > 0) {
    stats.push({ label: "Duration", value: formatDuration(usage.durationMillis) });
  }

  // Explain what drove the cost in terms of how the call is priced.
  const explanation = imageBilled
    ? "Image generation is priced per image, not by tokens."
    : tokenBilled
      ? "Cost is driven by tokens: a large input means a long question or lots of context, a large output means a long answer."
      : flatRate
        ? "Flat rate — vision parses are billed per call."
        : "No billable usage was recorded for this call.";

  return (
    <div className="space-y-3 px-2 py-1 text-sm">
      <p className="text-muted-foreground">{explanation}</p>
      {stats.length > 0 ? (
        <dl className="grid grid-cols-2 gap-x-8 gap-y-1 sm:grid-cols-4">
          {stats.map((stat) => (
            <div key={stat.label}>
              <dt className="text-xs text-muted-foreground">{stat.label}</dt>
              <dd className="font-medium tabular-nums">{stat.value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
      {call.errorCode ? (
        <p className="text-destructive">Error: {call.errorCode}</p>
      ) : null}
    </div>
  );
}

export function UsageHistoryCard() {
  const usage = useUsage();
  const [tab, setTab] = useState<TabKey>("app");
  const [page, setPage] = useState(1);
  // Keyed by call identity (not row index) so a refetch can't leave the open
  // detail pinned to whatever row now sits at that index.
  const [expanded, setExpanded] = useState<string | null>(null);
  // One ref per rendered row so arrow keys can move focus to the sibling row.
  const rowRefs = useRef<(HTMLTableRowElement | null)[]>([]);

  if (usage.isLoading) {
    return (
      <Card>
        <CardHeader>
          <Skeleton className="h-6 w-40" />
        </CardHeader>
        <CardContent>
          <Skeleton className="h-64 w-full" />
        </CardContent>
      </Card>
    );
  }

  const recent = usage.data?.recent ?? [];
  const tabRows = recent.filter((call) => call.product === tab);
  // Group by conversation, then page over the flattened (conversation-contiguous)
  // list so a conversation reads as one block. A group that spans a page boundary
  // re-shows its header on the next page.
  const { ordered, counts, summaries } = groupRowsByConversation(tabRows);

  const totalPages = Math.min(
    MAX_PAGES,
    Math.max(1, Math.ceil(ordered.length / ROWS_PER_PAGE)),
  );
  // Clamp in case rows shrank (refetch / tab switch) below the current page.
  const currentPage = Math.min(page, totalPages);
  const pageStart = (currentPage - 1) * ROWS_PER_PAGE;
  const pageRows = ordered.slice(pageStart, pageStart + ROWS_PER_PAGE);

  const selectTab = (next: TabKey) => {
    setTab(next);
    setPage(1);
    setExpanded(null);
  };

  const goToPage = (next: number) => {
    setPage(next);
    setExpanded(null);
  };

  const focusRow = (index: number) => {
    const row = pageRows[index];
    if (!row) {
      return;
    }
    setExpanded(callKey(row.call));
    rowRefs.current[index]?.focus();
  };

  const onRowKeyDown = (event: KeyboardEvent<HTMLTableRowElement>, index: number) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      focusRow(Math.min(index + 1, pageRows.length - 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      focusRow(Math.max(index - 1, 0));
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      const key = callKey(pageRows[index].call);
      setExpanded(expanded === key ? null : key);
    } else if (event.key === "Escape") {
      setExpanded(null);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Usage history</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="inline-flex rounded-md border p-0.5">
          {tabs.map((item) => (
            <button
              key={item.key}
              onClick={() => selectTab(item.key)}
              type="button"
              className={cn(
                "rounded px-3 py-1 text-sm font-medium transition-colors",
                tab === item.key
                  ? "bg-muted text-foreground"
                  : "text-muted-foreground hover:text-foreground",
              )}
            >
              {item.label}
            </button>
          ))}
        </div>

        {tabRows.length > 0 ? (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Date</TableHead>
                <TableHead>Kind</TableHead>
                <TableHead>Model</TableHead>
                <TableHead className="text-right">Cost</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {pageRows.map((row, index) => {
                const call = row.call;
                const key = callKey(call);
                const isOpen = expanded === key;
                // Header before the first row of each conversation block (and at
                // the page top, since a group can carry over from the prior page).
                // No-conversation calls render as plain rows with no header.
                const startsGroup =
                  row.groupKey !== NO_CONVERSATION &&
                  (index === 0 ||
                    pageRows[index - 1].groupKey !== row.groupKey);
                const groupCount = counts.get(row.groupKey) ?? 1;
                return (
                  <Fragment key={`${key}-${pageStart + index}`}>
                    {startsGroup ? (
                      <TableRow className="hover:bg-transparent">
                        <TableCell
                          className="bg-muted/40 py-2 text-xs font-medium text-muted-foreground"
                          colSpan={5}
                        >
                          <div className="flex items-center justify-between gap-2">
                            <span>{conversationLabel(row.groupKey)}</span>
                            <span className="tabular-nums">
                              {groupCount} {groupCount === 1 ? "call" : "calls"}
                              {" · "}
                              {summaries.get(row.groupKey)}
                            </span>
                          </div>
                        </TableCell>
                      </TableRow>
                    ) : null}
                    <TableRow
                      ref={(el) => {
                        rowRefs.current[index] = el;
                      }}
                      aria-expanded={isOpen}
                      className="cursor-pointer outline-none focus-visible:bg-muted/50"
                      onClick={() => {
                        setExpanded(isOpen ? null : key);
                        rowRefs.current[index]?.focus();
                      }}
                      onKeyDown={(event) => onRowKeyDown(event, index)}
                      tabIndex={0}
                    >
                      <TableCell>
                        {new Date(call.createdAt).toLocaleString()}
                      </TableCell>
                      <TableCell>{call.requestKind}</TableCell>
                      <TableCell>{call.model}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {formatCallCost(call)}
                      </TableCell>
                      <TableCell>
                        <Badge
                          variant={
                            call.status === "succeeded"
                              ? "secondary"
                              : "destructive"
                          }
                        >
                          {call.status}
                        </Badge>
                      </TableCell>
                    </TableRow>
                    {isOpen ? (
                      <TableRow className="hover:bg-transparent">
                        <TableCell className="bg-muted/30" colSpan={5}>
                          <CallDetail call={call} />
                        </TableCell>
                      </TableRow>
                    ) : null}
                  </Fragment>
                );
              })}
            </TableBody>
          </Table>
        ) : (
          <p className="text-sm text-muted-foreground">
            No {tab === "app" ? "app" : "Vision API"} calls yet.
          </p>
        )}

        {totalPages > 1 ? (
          <Pagination>
            <PaginationContent>
              <PaginationItem>
                <PaginationPrevious
                  aria-disabled={currentPage <= 1}
                  className={
                    currentPage <= 1 ? "pointer-events-none opacity-50" : undefined
                  }
                  onClick={() => goToPage(Math.max(1, currentPage - 1))}
                />
              </PaginationItem>
              {Array.from({ length: totalPages }, (_, i) => i + 1).map(
                (pageNumber) => (
                  <PaginationItem key={pageNumber}>
                    <PaginationLink
                      isActive={pageNumber === currentPage}
                      onClick={() => goToPage(pageNumber)}
                    >
                      {pageNumber}
                    </PaginationLink>
                  </PaginationItem>
                ),
              )}
              <PaginationItem>
                <PaginationNext
                  aria-disabled={currentPage >= totalPages}
                  className={
                    currentPage >= totalPages
                      ? "pointer-events-none opacity-50"
                      : undefined
                  }
                  onClick={() => goToPage(Math.min(totalPages, currentPage + 1))}
                />
              </PaginationItem>
            </PaginationContent>
          </Pagination>
        ) : null}
      </CardContent>
    </Card>
  );
}
