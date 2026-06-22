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
import { formatUsd } from "@/lib/credits/format-usd";
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

// Cost rounds to cents for most calls, but per-token app calls are often a small
// fraction of a cent — show enough precision that they aren't all "$0.00".
function formatCallCost(call: RecentCall): string {
  if (call.billingStatus === "included") {
    return "Included";
  }
  const value = Number.parseFloat(call.costCredits);
  if (!Number.isFinite(value) || value <= 0) {
    return "$0.00";
  }
  // ≥1¢ uses the shared formatter so money renders identically across cards.
  if (value >= 0.01) {
    return formatUsd(call.costCredits);
  }
  // Sub-cent: up to 6 decimal places (micro-dollar precision), trailing 0s cut.
  return `$${value.toFixed(6).replace(/0+$/, "").replace(/\.$/, "")}`;
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
  const rows = recent.filter((call) => call.product === tab);

  const totalPages = Math.min(
    MAX_PAGES,
    Math.max(1, Math.ceil(rows.length / ROWS_PER_PAGE)),
  );
  // Clamp in case rows shrank (refetch / tab switch) below the current page.
  const currentPage = Math.min(page, totalPages);
  const pageStart = (currentPage - 1) * ROWS_PER_PAGE;
  const pageRows = rows.slice(pageStart, pageStart + ROWS_PER_PAGE);

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
    const call = pageRows[index];
    if (!call) {
      return;
    }
    setExpanded(callKey(call));
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
      const key = callKey(pageRows[index]);
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

        {rows.length > 0 ? (
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
              {pageRows.map((call, index) => {
                const key = callKey(call);
                const isOpen = expanded === key;
                return (
                  <Fragment key={`${key}-${pageStart + index}`}>
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
